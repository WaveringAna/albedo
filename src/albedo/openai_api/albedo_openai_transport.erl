-module(albedo_openai_transport).

%% A streaming HTTP/1.1 client over a socket the calling process owns, plain
%% for http and verified TLS for https. Each streamed packet wakes only the
%% caller, and a finished exchange leaves its connection with
%% albedo_openai_pool for the next request to the same host.
%%
%% A connection is a handle {albedo_http, Owner, Ref}; its state lives in the
%% owner's process dictionary under {?MODULE, Ref}, so close sees how far the
%% last receive read and can tell a reusable connection from a broken one.
%% The socket closes when its owner exits.

-export([open/4, receive_message/1, close/1, with_connection/2, materialize/1]).
-export([unframe/2, setopts/3, close_socket/2]).

%% Bounds on what a response may make the client buffer before its body: the
%% head, a chunk-size line, and the trailers.
-define(MAX_HEAD, 65536).
-define(MAX_CHUNK_LINE, 1024).
%% Socket messages that may queue before the socket pauses; the client
%% re-arms on the passive message instead of once per packet.
-define(ACTIVE, 16).
-define(NO_LOCAL_SOCKET, <<"connection failed: this machine could not open "
    "a local socket (EADDRNOTAVAIL or EINVAL); its ephemeral ports may be "
    "exhausted by another program's connections">>).

open(URL, Headers, Body, Timeout)
        when is_binary(URL), is_list(Headers), is_integer(Timeout), Timeout > 0 ->
    case parse_url(URL) of
        {ok, Request} ->
            case connection(Request, Headers, Body, Timeout) of
                {ok, State} ->
                    Ref = make_ref(),
                    put({?MODULE, Ref}, State),
                    {ok, {albedo_http, self(), Ref}};
                {error, _} = Error -> Error
            end;
        error -> {error, invalid_url}
    end;
open(_, _, _, _) ->
    {error, invalid_url}.

%% A pooled connection first. One the server closed while it sat idle fails
%% its send or closes before answering; either way the request goes out again
%% on a new connection (see closed/2).
connection(#{transport := Transport, host := Host, port := Port} = Request,
           Headers, Body, Timeout) ->
    case albedo_openai_pool:checkout({Transport, Host, Port}) of
        {ok, Socket} ->
            case start(Request, Socket, Headers, Body, Timeout, true) of
                {ok, _} = Ok -> Ok;
                {error, _} -> fresh(Request, Headers, Body, Timeout)
            end;
        none -> fresh(Request, Headers, Body, Timeout)
    end.

fresh(#{transport := Transport, host := Host, port := Port} = Request,
      Headers, Body, Timeout) ->
    case connect(Transport, Host, Port, Timeout) of
        {ok, Socket} -> start(Request, Socket, Headers, Body, Timeout, false);
        {error, timeout} -> {error, timed_out};
        {error, Reason} when Reason =:= einval; Reason =:= eaddrnotavail ->
            {error, {transport_error, ?NO_LOCAL_SOCKET}};
        {error, Reason} -> transport_error(<<"connection failed">>, Reason)
    end.

connect(Transport, Host, Port, Timeout) ->
    Options = [binary, {active, false}, {packet, raw}, {nodelay, true},
               {send_timeout, Timeout}, {send_timeout_close, true}],
    Address = case inet:parse_address(Host) of
        {ok, IP} -> IP;
        {error, _} -> Host
    end,
    case Transport of
        tcp -> gen_tcp:connect(Address, Port, Options, Timeout);
        tls ->
            case application:ensure_all_started(ssl) of
                {ok, _} ->
                    ssl:connect(Address, Port, Options ++ tls_options(Address), Timeout);
                {error, Reason} -> {error, {ssl_not_started, Reason}}
            end
    end.

%% Verified against the OTP system CAs with HTTPS hostname matching; SNI
%% names the host unless it is an IP address.
tls_options(Address) ->
    SNI = case is_tuple(Address) of
        true -> [];
        false -> [{server_name_indication, Address}]
    end,
    Match = public_key:pkix_verify_hostname_match_fun(https),
    [{verify, verify_peer}, {cacerts, public_key:cacerts_get()},
     {customize_hostname_check, [{match_fun, Match}]},
     {alpn_advertised_protocols, [<<"http/1.1">>]} | SNI].

%% Sends the request and starts reading its response. Retry holds what a
%% pooled connection needs to send the request again.
start(#{transport := Transport, host := Host, port := Port} = Request,
      Socket, Headers, Body, Timeout, Pooled) ->
    try send_request(Transport, Socket, Request, Headers, Body) of
        ok ->
            case setopts(Transport, Socket, [{active, ?ACTIVE}]) of
                ok ->
                    Retry = case Pooled of
                        true -> {Request, Headers, Body};
                        false -> none
                    end,
                    {ok, #{socket => Socket, transport => Transport,
                           key => {Transport, Host, Port}, timeout => Timeout,
                           phase => {head, <<>>}, reusable => false, retry => Retry}};
                {error, Reason} ->
                    close_socket(Transport, Socket),
                    transport_error(<<"request failed">>, Reason)
            end;
        {error, Reason} ->
            close_socket(Transport, Socket),
            {error, {transport_error, Reason}}
    catch
        error:{attested_body, Why} ->
            close_socket(Transport, Socket),
            {error, {transport_error, Why}};
        _Class:_Reason ->
            close_socket(Transport, Socket),
            {error, {transport_error, <<"request failed">>}}
    end.

send_request(Transport, Socket, #{host := Host, port := Port, target := Target},
             Headers, Body) ->
    {Segments, Length, Hasher} =
        case segments(Body) of
            plain -> {[{data, Body}], iolist_size(Body), none};
            {Parts, Size, Marker} -> {Parts, Size, hasher(Marker)}
        end,
    %% A caller that signs its host header (Bedrock's SigV4) sends its own.
    Signed = lists:any(fun({Name, _}) -> string:lowercase(Name) =:= <<"host">> end, Headers),
    HostHeader = case Signed of
        true -> [];
        false -> [<<"host: ">>, host_header(Host, Port, Transport), <<"\r\n">>]
    end,
    Head = [<<"POST ">>, Target, <<" HTTP/1.1\r\n">>, HostHeader,
            <<"content-length: ">>, integer_to_binary(Length), <<"\r\n">>,
            [[Name, <<": ">>, Value, <<"\r\n">>] || {Name, Value} <- Headers],
            <<"\r\n">>],
    Send = fun(Data) ->
        case send(Transport, Socket, Data) of
            ok -> ok;
            {error, Reason} ->
                {transport_error, Message} = failure(<<"request failed">>, Reason),
                {error, Message}
        end
    end,
    then(Send(Head), fun() -> write(Send, Segments, Hasher) end).

host_header(Host, Port, Transport) ->
    Name = case lists:member($:, Host) of
        true -> [$[, Host, $]];
        false -> Host
    end,
    case {Transport, Port} of
        {tcp, 80} -> Name;
        {tls, 443} -> Name;
        _ -> [Name, $:, integer_to_binary(Port)]
    end.

%% Segmented body writer for lazy image reads and streaming attestation.
%% Invariants: nothing placeholder-bearing may follow {albedo_attest, ...},
%% and Emit must return exactly byte_size(Placeholder). Send writes one
%% segment and returns once the socket has taken it, so at most one image
%% payload is held at a time.
write(_, [], _) -> ok;
write(Send, [{data, Data} | Rest], Hasher) ->
    then(Send(Data), fun() -> write(Send, Rest, feed(Hasher, Data)) end);
write(Send, [{image, Size, Read} | Rest], Hasher) ->
    case read_payload(Size, Read) of
        {ok, Payload} -> then(Send(Payload), fun() -> write(Send, Rest, feed(Hasher, Payload)) end);
        {error, _} = Error -> Error
    end;
write(Send, [{attest, _, _} = Segment | Rest], Hasher) ->
    Value = marker_value(Segment, Rest, Hasher),
    then(Send(Value), fun() -> write(Send, Rest, done) end).

then(ok, Next) -> Next();
then({error, _} = Error, _) -> Error.

segments(Body) ->
    case walk(Body, {[], [], 0, none}) of
        {_, _, _, none} -> plain;
        {Current, Segments, Length, Marker} ->
            {lists:reverse(flush(Current, Segments)), Length, Marker}
    end.

walk({albedo_image, Size, Read}, {Current, Segments, Length, Marker}) ->
    case Marker of
        {_, _, _, _} ->
            bad_body(<<"a stored image cannot follow an attestation marker">>);
        _ ->
            {[], [{image, Size, Read} | flush(Current, Segments)], Length + Size, images}
    end;
walk({albedo_attest, Init, Update, Emit, Placeholder}, {Current, Segments, Length, Marker}) ->
    case Marker of
        {_, _, _, _} ->
            bad_body(<<"a body may carry at most one attestation marker">>);
        _ ->
            {[], [{attest, Emit, Placeholder} | flush(Current, Segments)],
             Length + byte_size(Placeholder), {Init, Update, Emit, Placeholder}}
    end;
walk([H | T], Acc) -> walk(T, walk(H, Acc));
walk([], Acc) -> Acc;
walk(Piece, {Current, Segments, Length, Marker}) when is_binary(Piece) ->
    {[Piece | Current], Segments, Length + byte_size(Piece), Marker};
walk(Byte, {Current, Segments, Length, Marker}) when is_integer(Byte) ->
    {[Byte | Current], Segments, Length + 1, Marker}.

bad_body(Why) -> erlang:error({attested_body, Why}).

flush([], Segments) -> Segments;
flush(Current, Segments) -> [{data, lists:reverse(Current)} | Segments].

hasher(none) -> none;
hasher(images) -> none;
hasher({Init, Update, _Emit, _Placeholder}) -> {hashing, Update, Init()}.

feed(none, _) -> none;
feed(done, _) -> done;
feed({hashing, Update, State}, Data) -> {hashing, Update, Update(State, Data)}.

%% Emits marker digits; walk guarantees only in-memory data segments follow.
marker_value({attest, Emit, Placeholder}, Rest, {hashing, Update, State}) ->
    Tail = [Data || {data, Data} <- Rest],
    Emit(Update(Update(State, Placeholder), Tail)).

read_payload(Size, Read) ->
    case Read() of
        {ok, Payload} when byte_size(Payload) =:= Size -> {ok, Payload};
        _ -> {error, <<"a stored image payload is missing or damaged">>}
    end.

%% The exact binary sent over the wire, with payloads read and markers spliced.
materialize(Body) ->
    try
        case segments(Body) of
            plain -> {ok, iolist_to_binary(Body)};
            {Segments, _Length, Marker} -> fold(Segments, hasher(Marker), [])
        end
    catch
        error:{attested_body, Why} -> {error, Why};
        _:_ -> {error, <<"a body could not be materialized">>}
    end.

fold([], _, Out) -> {ok, iolist_to_binary(lists:reverse(Out))};
fold([{data, Data} | Rest], Hasher, Out) ->
    fold(Rest, feed(Hasher, Data), [Data | Out]);
fold([{image, Size, Read} | Rest], Hasher, Out) ->
    case read_payload(Size, Read) of
        {ok, Payload} -> fold(Rest, feed(Hasher, Payload), [Payload | Out]);
        {error, _} = Error -> Error
    end;
fold([{attest, _, _} = Segment | Rest], Hasher, Out) ->
    Value = marker_value(Segment, Rest, Hasher),
    fold(Rest, done, [Value | Out]).

%% The next response headers or body chunk.
receive_message({albedo_http, Owner, Ref}) when Owner =:= self() ->
    case get({?MODULE, Ref}) of
        undefined ->
            {error, {transport_error, <<"connection already closed">>}};
        State ->
            case next(State) of
                {ok, Message, Next} ->
                    put({?MODULE, Ref}, Next),
                    {ok, Message};
                {error, Reason, Next} ->
                    put({?MODULE, Ref}, Next#{phase := failed}),
                    {error, Reason}
            end
    end;
receive_message(_) ->
    {error, {transport_error, <<"connection used by a process that does not own it">>}}.

next(#{phase := failed} = State) ->
    {error, {transport_error, <<"response failed earlier">>}, State};
next(#{phase := {head, Buffer}} = State) ->
    case response_head(Buffer) of
        {ok, _, Status, _, Rest} when Status >= 100, Status < 200, Status =/= 101 ->
            %% An interim response; the final one follows.
            next(State#{phase := {head, Rest}});
        {ok, Version, Status, Headers, Rest} ->
            Framing = framing(Status, Headers),
            Reusable = Version =:= {1, 1} andalso Framing =/= close
                andalso not closing(Headers),
            Next = State#{phase := {body, Framing, Rest}, reusable := Reusable},
            {ok, {headers, Status, Headers, Framing =:= done}, Next};
        more when byte_size(Buffer) > ?MAX_HEAD ->
            {error, {transport_error, <<"response failed: head too large">>}, State};
        more ->
            await(State, Buffer, fun(More) -> {head, More} end, closed_early);
        {error, Reason} ->
            {error, failure(<<"response failed">>, Reason), State}
    end;
next(#{phase := {body, Framing, Buffer}} = State) ->
    case unframe(Framing, Buffer) of
        {Data, Next, Rest} when Data =/= []; Next =:= done ->
            Message = {data, payload(Data), Next =:= done},
            {ok, Message, State#{phase := {body, Next, Rest}}};
        {[], Next, Rest} ->
            OnClose = case Next of
                close -> close;
                _ -> closed_early
            end,
            await(State, Rest, fun(More) -> {body, Next, More} end, OnClose);
        {error, Reason} ->
            {error, {transport_error, <<"response failed: ", Reason/binary>>}, State}
    end.

%% Waits for more bytes after Buffer, then reads on from Phase(Bytes). A close
%% ends a close-delimited body and fails any other response.
await(#{socket := Socket, transport := Transport, timeout := Timeout} = State,
      Buffer, Phase, OnClose) ->
    {Data, Passive, Closed, Error} = tags(Transport),
    receive
        {Data, Socket, Bytes} ->
            More = case Buffer of
                <<>> -> Bytes;
                _ -> <<Buffer/binary, Bytes/binary>>
            end,
            next(State#{phase := Phase(More), retry := none});
        {Passive, Socket} ->
            case setopts(Transport, Socket, [{active, ?ACTIVE}]) of
                ok -> await(State, Buffer, Phase, OnClose);
                {error, _} -> closed(State, OnClose)
            end;
        {Closed, Socket} -> closed(State, OnClose);
        {Error, Socket, Reason} ->
            case State of
                #{retry := {_, _, _}} -> closed(State, OnClose);
                #{} -> {error, failure(<<"response failed">>, Reason), State}
            end
    after Timeout ->
        {error, timed_out, State}
    end.

closed(State, close) ->
    {ok, {data, <<>>, true}, State#{phase := {body, done, <<>>}}};
closed(#{retry := {Request, Headers, Body}, transport := Transport,
         socket := Socket, timeout := Timeout} = State, closed_early) ->
    %% A pooled connection the server had already closed: nothing came back,
    %% so the request never reached it.
    discard(Transport, Socket),
    case fresh(Request, Headers, Body, Timeout) of
        {ok, Fresh} -> next(Fresh);
        {error, Reason} -> {error, Reason, State}
    end;
closed(State, closed_early) ->
    Why = <<"response failed: the connection closed before the response ended">>,
    {error, {transport_error, Why}, State}.

%% Closes the connection, or leaves it with the pool when its response ended
%% cleanly on a connection the server keeps open.
close(Connection) ->
    close(Connection, false),
    nil.

%% Runs Run and closes the connection, even when Run raises. When Run returns
%% {ok, _}, the response it stopped reading may still be ending (the
%% terminator after a stream's last event); the pool reads that rest.
%% Anything else, such as a cancelled stream, closes the socket so the
%% server stops sending.
with_connection(Connection, Run) ->
    Result = try Run()
    catch Class:Reason:Stack ->
        close(Connection, false),
        erlang:raise(Class, Reason, Stack)
    end,
    close(Connection, is_tuple(Result) andalso element(1, Result) =:= ok),
    Result.

close({albedo_http, Owner, Ref}, Finished) when Owner =:= self() ->
    case erase({?MODULE, Ref}) of
        #{reusable := true, phase := {body, Framing, Buffer}, key := Key,
          transport := Transport, socket := Socket} when Finished; Framing =:= done ->
            release(Key, Transport, Socket, Framing, Buffer);
        #{transport := Transport, socket := Socket} ->
            discard(Transport, Socket);
        undefined -> ok
    end;
close(_, _) ->
    ok.

%% Hands a kept-alive socket to the pool with any bytes already delivered.
release(Key, Transport, Socket, Framing, Buffer) ->
    case setopts(Transport, Socket, [{active, false}]) of
        ok ->
            case collect(Transport, Socket, Buffer) of
                {ok, Rest} ->
                    albedo_openai_pool:checkin(Key, Transport, Socket, Framing, Rest);
                closed -> discard(Transport, Socket)
            end;
        {error, _} -> discard(Transport, Socket)
    end.

collect(Transport, Socket, Buffer) ->
    {Data, Passive, Closed, Error} = tags(Transport),
    receive
        {Data, Socket, Bytes} -> collect(Transport, Socket, <<Buffer/binary, Bytes/binary>>);
        {Passive, Socket} -> collect(Transport, Socket, Buffer);
        {Closed, Socket} -> closed;
        {Error, Socket, _} -> closed
    after 0 -> {ok, Buffer}
    end.

discard(Transport, Socket) ->
    close_socket(Transport, Socket),
    drop_messages(Transport, Socket).

drop_messages(Transport, Socket) ->
    {Data, Passive, Closed, Error} = tags(Transport),
    receive
        {Data, Socket, _} -> drop_messages(Transport, Socket);
        {Passive, Socket} -> drop_messages(Transport, Socket);
        {Closed, Socket} -> drop_messages(Transport, Socket);
        {Error, Socket, _} -> drop_messages(Transport, Socket)
    after 0 -> ok
    end.

tags(tcp) -> {tcp, tcp_passive, tcp_closed, tcp_error};
tags(tls) -> {ssl, ssl_passive, ssl_closed, ssl_error}.

setopts(tcp, Socket, Options) -> inet:setopts(Socket, Options);
setopts(tls, Socket, Options) -> ssl:setopts(Socket, Options).

send(tcp, Socket, Data) -> gen_tcp:send(Socket, Data);
send(tls, Socket, Data) -> ssl:send(Socket, Data).

close_socket(tcp, Socket) -> gen_tcp:close(Socket), ok;
close_socket(tls, Socket) -> _ = ssl:close(Socket), ok.

response_head(Buffer) ->
    case erlang:decode_packet(http_bin, Buffer, []) of
        {ok, {http_response, Version, Status, _Reason}, Rest} ->
            response_headers(Rest, Version, Status, []);
        {ok, _, _} -> {error, malformed_status_line};
        {more, _} -> more;
        {error, Reason} -> {error, Reason}
    end.

response_headers(Buffer, Version, Status, Headers) ->
    case erlang:decode_packet(httph_bin, Buffer, []) of
        {ok, {http_header, _, Name, _, Value}, Rest} ->
            response_headers(Rest, Version, Status, [{header_name(Name), Value} | Headers]);
        {ok, http_eoh, Rest} -> {ok, Version, Status, lists:reverse(Headers), Rest};
        {ok, _, _} -> {error, malformed_header};
        {more, _} -> more;
        {error, Reason} -> {error, Reason}
    end.

header_name(Name) when is_atom(Name) -> string:lowercase(atom_to_binary(Name));
header_name(Name) -> string:lowercase(Name).

header_has(Headers, Name, Token) ->
    lists:any(fun({Key, Value}) ->
        Key =:= Name andalso string:find(string:lowercase(Value), Token) =/= nomatch
    end, Headers).

closing(Headers) -> header_has(Headers, <<"connection">>, <<"close">>).

framing(Status, _) when Status =:= 204; Status =:= 304 -> done;
framing(_, Headers) ->
    case header_has(Headers, <<"transfer-encoding">>, <<"chunked">>) of
        true -> {chunked, size};
        false ->
            case [Value || {<<"content-length">>, Value} <- Headers] of
                [Value | _] ->
                    case string:to_integer(string:trim(Value)) of
                        {0, <<>>} -> done;
                        {Size, <<>>} when Size > 0 -> {length, Size};
                        _ -> close
                    end;
                [] -> close
            end
    end.

payload([]) -> <<>>;
payload([Data]) -> Data;
payload(Data) -> iolist_to_binary(Data).

%% The body bytes in Buffer, the framing state after them, and the bytes
%% left over for the next read. Exported for the pool, which reads a
%% released response to its end.
unframe(done, _) -> {[], done, <<>>};
unframe(close, Buffer) -> {[Buffer || Buffer =/= <<>>], close, <<>>};
unframe({length, Size}, Buffer) when byte_size(Buffer) >= Size ->
    {[binary:part(Buffer, 0, Size)], done, <<>>};
unframe({length, Size}, Buffer) ->
    {[Buffer || Buffer =/= <<>>], {length, Size - byte_size(Buffer)}, <<>>};
unframe({chunked, State}, Buffer) ->
    case chunks(State, Buffer, []) of
        {Data, done, Rest} -> {Data, done, Rest};
        {Data, Next, Rest} -> {Data, {chunked, Next}, Rest};
        {error, _} = Error -> Error
    end.

%% Chunked transfer coding: size reads a chunk-size line, {data, N} has N
%% bytes of chunk data left, crlf ends a chunk, trailers skips trailer lines.
chunks({data, Size}, Buffer, Data) ->
    case Buffer of
        <<Chunk:Size/binary, Rest/binary>> -> chunks(crlf, Rest, [Chunk | Data]);
        <<>> -> {lists:reverse(Data), {data, Size}, <<>>};
        _ -> {lists:reverse([Buffer | Data]), {data, Size - byte_size(Buffer)}, <<>>}
    end;
chunks(crlf, <<"\r\n", Rest/binary>>, Data) -> chunks(size, Rest, Data);
chunks(crlf, Buffer, Data) when Buffer =:= <<>>; Buffer =:= <<"\r">> ->
    {lists:reverse(Data), crlf, Buffer};
chunks(crlf, _, _) -> {error, <<"malformed chunk">>};
chunks(Line, Buffer, Data) when Line =:= size; Line =:= trailers ->
    %% A one-byte pattern is a memchr; a two-byte one is compiled per call.
    case binary:match(Buffer, <<"\n">>) of
        nomatch when byte_size(Buffer) > ?MAX_CHUNK_LINE, Line =:= size ->
            {error, <<"chunk size line too long">>};
        nomatch when byte_size(Buffer) > ?MAX_HEAD ->
            {error, <<"trailers too large">>};
        nomatch -> {lists:reverse(Data), Line, Buffer};
        {0, 1} -> {error, <<"malformed chunk line">>};
        {At, 1} ->
            case Buffer of
                <<Text:(At - 1)/binary, "\r\n", Rest/binary>> ->
                    case {Line, chunk_size(Text, 0, 0)} of
                        {trailers, _} when At =:= 1 -> {lists:reverse(Data), done, Rest};
                        {trailers, _} -> chunks(trailers, Rest, Data);
                        {size, {ok, 0}} -> chunks(trailers, Rest, Data);
                        {size, {ok, Size}} -> chunks({data, Size}, Rest, Data);
                        {size, error} -> {error, <<"malformed chunk size">>}
                    end;
                _ -> {error, <<"malformed chunk line">>}
            end
    end.

%% The hex size before any chunk extension; Digits counts the digits read.
chunk_size(<<C, Rest/binary>>, Size, Digits) when C >= $0, C =< $9 ->
    chunk_size(Rest, Size * 16 + C - $0, Digits + 1);
chunk_size(<<C, Rest/binary>>, Size, Digits) when C >= $a, C =< $f ->
    chunk_size(Rest, Size * 16 + C - $a + 10, Digits + 1);
chunk_size(<<C, Rest/binary>>, Size, Digits) when C >= $A, C =< $F ->
    chunk_size(Rest, Size * 16 + C - $A + 10, Digits + 1);
chunk_size(<<C, _/binary>>, Size, Digits) when Digits > 0, (C =:= $; orelse C =:= $\s orelse C =:= $\t) ->
    {ok, Size};
chunk_size(<<>>, Size, Digits) when Digits > 0 -> {ok, Size};
chunk_size(_, _, _) -> error.

parse_url(URL) ->
    try uri_string:parse(URL) of
        URI when is_map(URI) -> validate_url(URI);
        _ -> error
    catch
        _:_ -> error
    end.

validate_url(URI) ->
    Scheme = lowercase(maps:get(scheme, URI, <<>>)),
    Host = maps:get(host, URI, <<>>),
    case {transport(Scheme), valid_host(Host), forbidden_parts(URI)} of
        {{ok, Transport, DefaultPort}, true, false} ->
            case valid_port(URI, DefaultPort) of
                {ok, Port} ->
                    {ok, #{
                        host => binary_to_list(Host),
                        port => Port,
                        target => request_target(URI),
                        transport => Transport
                    }};
                error -> error
            end;
        _ ->
            error
    end.

transport(<<"https">>) -> {ok, tls, 443};
transport(<<"http">>) -> {ok, tcp, 80};
transport(_) -> error.

valid_host(Host) -> is_binary(Host) andalso byte_size(Host) > 0.

forbidden_parts(URI) ->
    maps:is_key(userinfo, URI) orelse maps:is_key(fragment, URI).

valid_port(URI, Default) ->
    case maps:get(port, URI, Default) of
        Port when is_integer(Port), Port > 0, Port =< 65535 -> {ok, Port};
        _ -> error
    end.

request_target(URI) ->
    Path = case maps:get(path, URI, <<>>) of
        <<>> -> <<"/">>;
        Value -> Value
    end,
    case maps:get(query, URI, undefined) of
        undefined -> Path;
        Query -> [Path, <<"?">>, Query]
    end.

lowercase(Binary) when is_binary(Binary) ->
    string:lowercase(Binary);
lowercase(_) ->
    <<>>.

transport_error(Context, Reason) ->
    {error, failure(Context, Reason)}.

failure(Context, Reason) ->
    Detail = unicode:characters_to_binary(io_lib:format("~0p", [Reason])),
    Hint = case binary:match(Detail, <<"bad_record_mac">>) of
        nomatch -> <<>>;
        _ -> <<"TLS record authentication failed (network or TLS intermediary; not a Codex API error); ">>
    end,
    {transport_error, <<Context/binary, ": ", Hint/binary, Detail/binary>>}.
