-module(albedo_openai_transport).

-export([open/4, receive_message/1, close/1, with_connection/2, materialize/1]).

-define(FLOW, 1).

open(URL, Headers, Body, Timeout)
        when is_binary(URL), is_list(Headers), is_integer(Timeout), Timeout > 0 ->
    case parse_url(URL) of
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
            {error, {transport_error, <<"connection failed: this machine could not open "
                "a local socket (EADDRNOTAVAIL or EINVAL); its ephemeral ports may be "
                "exhausted by another program's connections">>}};
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
            case write(Pid, Stream, Segments, Deadline, hasher(Marker)) of
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

write(_, _, [], _, _) -> ok;
write(Pid, Stream, [{data, Data} | Rest], Deadline, Hasher) ->
    gun:data(Pid, Stream, fin(Rest), Data),
    write(Pid, Stream, Rest, Deadline, feed(Hasher, Data));
write(Pid, Stream, [{image, Size, Read} | Rest], Deadline, Hasher) ->
    case read_payload(Size, Read) of
        {ok, Payload} ->
            gun:data(Pid, Stream, fin(Rest), Payload),
            case drained(Pid, Deadline) of
                ok -> write(Pid, Stream, Rest, Deadline, feed(Hasher, Payload));
                Error -> Error
            end;
        {error, _} = Error -> Error
    end;
write(Pid, Stream, [{attest, _, _} = Segment | Rest], Deadline, Hasher) ->
    Value = marker_value(Segment, Rest, Hasher),
    gun:data(Pid, Stream, fin(Rest), Value),
    write(Pid, Stream, Rest, Deadline, done).

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

receive_message({connection, Owner, Pid, Stream, Monitor, Timeout})
        when Owner =:= self() ->
    case gun:await(Pid, Stream, Timeout, Monitor) of
        {inform, _Status, _Headers} ->
            receive_message({connection, Owner, Pid, Stream, Monitor, Timeout});
        {response, IsFin, Status, Headers} ->
            {ok, {headers, Status, Headers, IsFin =:= fin}};
        {data, IsFin, Bytes} ->
            maybe_replenish(IsFin, Pid, Stream),
            {ok, {data, Bytes, IsFin =:= fin}};
        {trailers, _Headers} ->
            {ok, {data, <<>>, true}};
        {error, timeout} ->
            {error, timed_out};
        {error, Reason} ->
            transport_error(<<"response failed">>, Reason);
        _Other ->
            receive_message({connection, Owner, Pid, Stream, Monitor, Timeout})
    end;
receive_message({connection, _, _, _, _, _}) ->
    {error, {transport_error, <<"connection used by a process that does not own it">>}}.

maybe_replenish(nofin, Pid, Stream) ->
    gun:update_flow(Pid, Stream, ?FLOW);
maybe_replenish(fin, _, _) ->
    ok.

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
