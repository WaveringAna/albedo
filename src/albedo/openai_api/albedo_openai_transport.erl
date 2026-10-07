-module(albedo_openai_transport).

-export([open/4, receive_message/1, close/1, with_connection/2, materialize/1]).

-define(FLOW, 1).
%% Bounds on what a plain HTTP response may make the direct client buffer
%% before its body: the head, a chunk-size line, and the trailers.
-define(MAX_HEAD, 65536).
-define(MAX_CHUNK_LINE, 1024).
%% Socket messages the direct client lets queue before the socket pauses; it
%% re-arms on tcp_passive instead of once per packet.
-define(ACTIVE, 16).
-define(NO_LOCAL_SOCKET, <<"connection failed: this machine could not open "
    "a local socket (EADDRNOTAVAIL or EINVAL); its ephemeral ports may be "
    "exhausted by another program's connections">>).

open(URL, Headers, Body, Timeout)
        when is_binary(URL), is_list(Headers), is_integer(Timeout), Timeout > 0 ->
    case parse_url(URL) of
        {ok, #{transport := tcp} = Request} -> open_direct(Request, Headers, Body, Timeout);
        {ok, Request} -> open_request(Request, Headers, Body, Timeout);
        error -> {error, invalid_url}
    end;
open(_, _, _, _) ->
    {error, invalid_url}.

open_request(#{host := Host, port := Port, target := Target,
        transport := Transport, protocols := Protocols}, Headers, Body, Timeout) ->
    case application:ensure_all_started(gun) of
        {ok, _} ->
            Options = #{
                connect_timeout => Timeout,
                domain_lookup_timeout => Timeout,
                %% Close-delimited responses may stream longer than Gun's
                %% shutdown grace. receive_message owns the idle deadline.
                http_opts => #{closing_timeout => infinity},
                protocols => Protocols,
                retry => 0,
                supervise => true,
                tls_handshake_timeout => Timeout,
                tls_opts => tls_options(Transport),
                transport => Transport
            },
            case gun:open(Host, Port, Options) of
                {ok, Pid} ->
                    close_when_owner_exits(Pid),
                    unlink(Pid),
                    Monitor = erlang:monitor(process, Pid),
                    await_connection(Pid, Monitor, Target, Headers, Body, Timeout);
                {error, Reason} ->
                    transport_error(<<"connection open failed">>, Reason)
            end;
        {error, Reason} ->
            transport_error(<<"could not start HTTP transport">>, Reason)
    end.

%% Plain HTTP/1.1 is spoken over a socket the caller owns, so each streamed
%% chunk wakes one process rather than a connection process and then its
%% caller; the socket closes when its owner exits. TLS endpoints stay on Gun,
%% which negotiates HTTP/2 and verifies certificates. The connection carries
%% the response state: {head, Buffer} until the headers, then
%% {body, Framing, Buffer}, where Buffer holds bytes not yet framed.
open_direct(#{host := Host, port := Port, target := Target}, Headers, Body, Timeout) ->
    Options = [binary, {active, false}, {packet, raw}, {nodelay, true},
               {send_timeout, Timeout}, {send_timeout_close, true}],
    case gen_tcp:connect(Host, Port, Options, Timeout) of
        {ok, Socket} ->
            try send_direct(Socket, Host, Port, Target, Headers, Body) of
                ok ->
                    ok = inet:setopts(Socket, [{active, ?ACTIVE}]),
                    {ok, {direct, self(), Socket, Timeout, {head, <<>>}}};
                {error, Reason} ->
                    gen_tcp:close(Socket),
                    {error, {transport_error, Reason}}
            catch
                error:{attested_body, Why} ->
                    gen_tcp:close(Socket),
                    {error, {transport_error, Why}};
                _Class:_Reason ->
                    gen_tcp:close(Socket),
                    {error, {transport_error, <<"request failed">>}}
            end;
        {error, timeout} ->
            {error, timed_out};
        {error, Reason} when Reason =:= einval; Reason =:= eaddrnotavail ->
            {error, {transport_error, ?NO_LOCAL_SOCKET}};
        {error, Reason} ->
            transport_error(<<"connection failed">>, Reason)
    end.

send_direct(Socket, Host, Port, Target, Headers, Body) ->
    {Segments, Length, Hasher} =
        case segments(Body) of
            plain -> {[{data, Body}], iolist_size(Body), none};
            {Parts, Size, Marker} -> {Parts, Size, hasher(Marker)}
        end,
    Head = [<<"POST ">>, Target, <<" HTTP/1.1\r\nhost: ">>, host_header(Host, Port),
            <<"\r\nconnection: close\r\ncontent-length: ">>, integer_to_binary(Length),
            <<"\r\n">>, [[Name, <<": ">>, Value, <<"\r\n">>] || {Name, Value} <- Headers],
            <<"\r\n">>],
    Send = fun(_IsFin, Data) ->
        case gen_tcp:send(Socket, Data) of
            ok -> ok;
            {error, Reason} -> transport_error(<<"request failed">>, Reason)
        end
    end,
    then(Send(nofin, Head), fun() -> write(Send, fun() -> ok end, Segments, Hasher) end).

host_header(Host, 80) -> bracketed(Host);
host_header(Host, Port) -> [bracketed(Host), $:, integer_to_binary(Port)].

bracketed(Host) ->
    case lists:member($:, Host) of
        true -> [$[, Host, $]];
        false -> Host
    end.

direct_message({direct, Owner, Socket, Timeout, {head, Buffer}} = Connection) ->
    case response_head(Buffer) of
        {ok, Status, _Headers, Rest} when Status >= 100, Status < 200, Status =/= 101 ->
            direct_message(setelement(5, Connection, {head, Rest}));
        {ok, Status, Headers, Rest} ->
            Framing = framing(Status, Headers),
            Next = {direct, Owner, Socket, Timeout, {body, Framing, Rest}},
            {ok, {{headers, Status, Headers, Framing =:= done}, Next}};
        more when byte_size(Buffer) > ?MAX_HEAD ->
            {error, {transport_error, <<"response failed: response head too large">>}};
        more ->
            await(Connection, Buffer, fun(More) -> {head, More} end, closed_early);
        {error, Reason} ->
            transport_error(<<"response failed">>, Reason)
    end;
direct_message({direct, Owner, Socket, Timeout, {body, Framing, Buffer}} = Connection) ->
    case unframe(Framing, Buffer) of
        {Data, Next, Rest} when Data =/= []; Next =:= done ->
            State = {body, Next, Rest},
            {ok, {{data, payload(Data), Next =:= done}, {direct, Owner, Socket, Timeout, State}}};
        {[], Next, Rest} ->
            OnClose = case Next of
                close -> close;
                _ -> closed_early
            end,
            await(Connection, Rest, fun(More) -> {body, Next, More} end, OnClose);
        {error, Reason} ->
            {error, {transport_error, <<"response failed: ", Reason/binary>>}}
    end.

%% Waits for more bytes after Buffer, then reads on from State(Bytes). A close
%% ends a close-delimited body and fails any other response.
await({direct, Owner, Socket, Timeout, _} = Connection, Buffer, State, OnClose) ->
    receive
        {tcp, Socket, Bytes} ->
            More = case Buffer of
                <<>> -> Bytes;
                _ -> <<Buffer/binary, Bytes/binary>>
            end,
            direct_message({direct, Owner, Socket, Timeout, State(More)});
        {tcp_passive, Socket} ->
            case inet:setopts(Socket, [{active, ?ACTIVE}]) of
                ok -> await(Connection, Buffer, State, OnClose);
                {error, _} -> closed(Owner, Socket, Timeout, OnClose)
            end;
        {tcp_closed, Socket} -> closed(Owner, Socket, Timeout, OnClose);
        {tcp_error, Socket, Reason} -> transport_error(<<"response failed">>, Reason)
    after Timeout ->
        {error, timed_out}
    end.

closed(Owner, Socket, Timeout, close) ->
    {ok, {{data, <<>>, true}, {direct, Owner, Socket, Timeout, {body, done, <<>>}}}};
closed(_, _, _, closed_early) ->
    {error, {transport_error, <<"response failed: the connection closed before the response ended">>}}.

flush_socket(Socket) ->
    receive
        {tcp, Socket, _} -> flush_socket(Socket);
        {tcp_passive, Socket} -> flush_socket(Socket);
        {tcp_closed, Socket} -> flush_socket(Socket);
        {tcp_error, Socket, _} -> flush_socket(Socket)
    after 0 -> ok
    end.

response_head(Buffer) ->
    case erlang:decode_packet(http_bin, Buffer, []) of
        {ok, {http_response, _Version, Status, _Reason}, Rest} ->
            response_headers(Rest, Status, []);
        {ok, _, _} -> {error, malformed_status_line};
        {more, _} -> more;
        {error, Reason} -> {error, Reason}
    end.

response_headers(Buffer, Status, Headers) ->
    case erlang:decode_packet(httph_bin, Buffer, []) of
        {ok, {http_header, _, Name, _, Value}, Rest} ->
            response_headers(Rest, Status, [{header_name(Name), Value} | Headers]);
        {ok, http_eoh, Rest} -> {ok, Status, lists:reverse(Headers), Rest};
        {ok, _, _} -> {error, malformed_header};
        {more, _} -> more;
        {error, Reason} -> {error, Reason}
    end.

header_name(Name) when is_atom(Name) -> string:lowercase(atom_to_binary(Name));
header_name(Name) -> string:lowercase(Name).

framing(Status, _) when Status =:= 204; Status =:= 304 -> done;
framing(_, Headers) ->
    Chunked = [Value || {<<"transfer-encoding">>, Value} <- Headers,
                        string:find(string:lowercase(Value), <<"chunked">>) =/= nomatch],
    Length = [Value || {<<"content-length">>, Value} <- Headers],
    case {Chunked, Length} of
        {[_ | _], _} -> {chunked, size};
        {[], [Value | _]} ->
            case string:to_integer(string:trim(Value)) of
                {0, <<>>} -> done;
                {Size, <<>>} when Size > 0 -> {length, Size};
                _ -> close
            end;
        {[], []} -> close
    end.

payload([]) -> <<>>;
payload([Data]) -> Data;
payload(Data) -> iolist_to_binary(Data).

%% The body bytes in Buffer, the framing state after them, and the bytes
%% left over for the next read.
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

%% Gun defers owner death while a close-delimited response is still streaming.
%% A killed caller cannot run with_connection's cleanup, so close it explicitly.
close_when_owner_exits(Pid) ->
    Owner = self(),
    spawn(fun() ->
        OwnerMonitor = erlang:monitor(process, Owner),
        ConnectionMonitor = erlang:monitor(process, Pid),
        receive
            {'DOWN', OwnerMonitor, process, Owner, _} ->
                ignore_failure(fun() -> gun:close(Pid) end);
            {'DOWN', ConnectionMonitor, process, Pid, _} -> ok
        end
    end).

await_connection(Pid, Monitor, Target, Headers, Body, Timeout) ->
    case gun:await_up(Pid, Timeout, Monitor) of
        {ok, _Protocol} ->
            start_request(Pid, Monitor, Target, Headers, Body, Timeout);
        {error, timeout} ->
            cleanup(Pid, Monitor),
            {error, timed_out};
        %% gun exits badarg when connect/4 answers einval or eaddrnotavail.
        {error, {down, badarg}} ->
            cleanup(Pid, Monitor),
            {error, {transport_error, ?NO_LOCAL_SOCKET}};
        {error, Reason} ->
            cleanup(Pid, Monitor),
            transport_error(<<"connection failed">>, Reason)
    end.

start_request(Pid, Monitor, Target, Headers, Body, Timeout) ->
    try send(Pid, Target, Headers, Body, Timeout) of
        {ok, Stream} ->
            {ok, {connection, self(), Pid, Stream, Monitor, Timeout}};
        {error, Reason} ->
            cleanup(Pid, Monitor),
            {error, {transport_error, Reason}}
    catch
        error:{attested_body, Why} ->
            cleanup(Pid, Monitor),
            {error, {transport_error, Why}};
        _Class:_Reason ->
            cleanup(Pid, Monitor),
            {error, {transport_error, <<"request failed">>}}
    end.

%% Segmented body writer for lazy image reads and streaming attestation.
%% Invariants: nothing placeholder-bearing may follow {albedo_attest, ...},
%% and Emit must return exactly byte_size(Placeholder).
send(Pid, Target, Headers, Body, Timeout) ->
    case segments(Body) of
        plain ->
            {ok, gun:post(Pid, Target, Headers, Body, #{flow => ?FLOW})};
        {Segments, Length, Marker} ->
            Sized = [{<<"content-length">>, integer_to_binary(Length)} | Headers],
            Stream = gun:post(Pid, Target, Sized, #{flow => ?FLOW}),
            Deadline = erlang:monotonic_time(millisecond) + Timeout,
            Send = fun(IsFin, Data) -> gun:data(Pid, Stream, IsFin, Data) end,
            Drain = fun() -> drained(Pid, Deadline) end,
            case write(Send, Drain, Segments, hasher(Marker)) of
                ok -> {ok, Stream};
                {error, Reason} ->
                    gun:cancel(Pid, Stream),
                    {error, Reason}
            end
    end.

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

%% Send(IsFin, Data) writes one segment; Drain() waits, after an image, until
%% the writer has taken it, so at most one image payload is held at a time.
write(_, _, [], _) -> ok;
write(Send, Drain, [{data, Data} | Rest], Hasher) ->
    then(Send(fin(Rest), Data), fun() -> write(Send, Drain, Rest, feed(Hasher, Data)) end);
write(Send, Drain, [{image, Size, Read} | Rest], Hasher) ->
    case read_payload(Size, Read) of
        {ok, Payload} ->
            then(Send(fin(Rest), Payload), fun() ->
                then(Drain(), fun() -> write(Send, Drain, Rest, feed(Hasher, Payload)) end)
            end);
        {error, _} = Error -> Error
    end;
write(Send, Drain, [{attest, _, _} = Segment | Rest], Hasher) ->
    Value = marker_value(Segment, Rest, Hasher),
    then(Send(fin(Rest), Value), fun() -> write(Send, Drain, Rest, done) end).

then(ok, Next) -> Next();
then({error, _} = Error, _) -> Error.

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

fin([]) -> fin;
fin(_) -> nofin.

%% Waits until the connection process has consumed what it was sent.
drained(Pid, Deadline) ->
    case erlang:process_info(Pid, message_queue_len) of
        {message_queue_len, 0} -> ok;
        undefined -> {error, <<"the connection closed while writing the request body">>};
        _ ->
            case erlang:monotonic_time(millisecond) >= Deadline of
                true -> {error, <<"timed out writing the request body">>};
                false ->
                    receive after 1 -> ok end,
                    drained(Pid, Deadline)
            end
    end.

%% The next message, and the connection to read the one after it from.
receive_message({connection, Owner, Pid, Stream, Monitor, Timeout} = Connection)
        when Owner =:= self() ->
    case gun:await(Pid, Stream, Timeout, Monitor) of
        {inform, _Status, _Headers} ->
            receive_message(Connection);
        {response, IsFin, Status, Headers} ->
            {ok, {{headers, Status, Headers, IsFin =:= fin}, Connection}};
        {data, IsFin, Bytes} ->
            maybe_replenish(IsFin, Pid, Stream),
            {ok, {{data, Bytes, IsFin =:= fin}, Connection}};
        {trailers, _Headers} ->
            {ok, {{data, <<>>, true}, Connection}};
        {error, timeout} ->
            {error, timed_out};
        {error, Reason} ->
            transport_error(<<"response failed">>, Reason);
        _Other ->
            receive_message(Connection)
    end;
receive_message({direct, Owner, _, _, _} = Connection) when Owner =:= self() ->
    direct_message(Connection);
receive_message(_) ->
    {error, {transport_error, <<"connection used by a process that does not own it">>}}.

maybe_replenish(nofin, Pid, Stream) ->
    gun:update_flow(Pid, Stream, ?FLOW);
maybe_replenish(fin, _, _) ->
    ok.

close({direct, Owner, Socket, _, _}) ->
    gen_tcp:close(Socket),
    case Owner =:= self() of
        true -> flush_socket(Socket);
        false -> ok
    end,
    nil;
close({connection, Owner, Pid, Stream, Monitor, _Timeout}) ->
    case Owner =:= self() of
        true ->
            ignore_failure(fun() -> gun:cancel(Pid, Stream) end),
            cleanup(Pid, Monitor);
        false ->
            ignore_failure(fun() -> gun:close(Pid) end)
    end,
    nil.

with_connection(Connection, Run) ->
    try Run()
    after close(Connection)
    end.

cleanup(Pid, Monitor) ->
    ignore_failure(fun() -> gun:close(Pid) end),
    erlang:demonitor(Monitor, [flush]),
    gun:flush(Pid),
    ok.

ignore_failure(Run) ->
    try Run() of
        _ -> ok
    catch
        _:_ -> ok
    end.

%% Gun augments verify_peer with OTP system CAs, HTTPS hostname matching and SNI.
tls_options(tls) ->
    [{verify, verify_peer}];
tls_options(tcp) ->
    [].

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
        {{ok, Transport, DefaultPort, Protocols}, true, false} ->
            case valid_port(URI, DefaultPort) of
                {ok, Port} ->
                    {ok, #{
                        host => binary_to_list(Host),
                        port => Port,
                        protocols => Protocols,
                        target => request_target(URI),
                        transport => Transport
                    }};
                error -> error
            end;
        _ ->
            error
    end.

transport(<<"https">>) -> {ok, tls, 443, [http2, http]};
transport(<<"http">>) -> {ok, tcp, 80, [http]};
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
    Detail = unicode:characters_to_binary(io_lib:format("~0p", [Reason])),
    Hint = case binary:match(Detail, <<"bad_record_mac">>) of
        nomatch -> <<>>;
        _ -> <<"TLS record authentication failed (network or TLS intermediary; not a Codex API error); ">>
    end,
    {error, {transport_error, <<Context/binary, ": ", Hint/binary, Detail/binary>>}}.
