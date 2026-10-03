-module(albedo_openai_transport_test_server).

-export([start/1, url/1, await_body/1, await_closed/1,
    stop/1, owner_after_headers/1, kill_owner/1]).

start(Mode) ->
    {ok, Listen} = gen_tcp:listen(0, [binary, {active, false},
        {reuseaddr, true}, {packet, raw}]),
    {ok, {_Address, Port}} = inet:sockname(Listen),
    Owner = self(),
    Pid = spawn(fun() -> serve(Listen, Owner, Mode) end),
    URL = iolist_to_binary(io_lib:format("http://127.0.0.1:~B/v1/chat?fixture=yes", [Port])),
    {fixture, Pid, URL}.

url({fixture, _Pid, URL}) -> URL.

await_body({fixture, Pid, _URL}) ->
    receive
        {fixture_body, Pid, Body} -> Body
    after 2000 ->
        timeout
    end.

await_closed({fixture, Pid, _URL}) ->
    receive
        {fixture_closed, Pid} -> true;
        {fixture_error, Pid, _} -> false
    after 2000 ->
        false
    end.

stop({fixture, Pid, _URL}) ->
    exit(Pid, shutdown),
    nil.

owner_after_headers(Fixture) ->
    Parent = self(),
    {Owner, Monitor} = spawn_monitor(fun() ->
        {ok, Connection} = albedo_openai_transport:open(url(Fixture), [], <<>>, 2000),
        {ok, {headers, 200, _, false}} =
            albedo_openai_transport:receive_message(Connection),
        Parent ! {transport_owner_ready, self()},
        receive stop -> albedo_openai_transport:close(Connection) end
    end),
    receive
        {transport_owner_ready, Owner} ->
            demonitor(Monitor, [flush]),
            Owner;
        {'DOWN', Monitor, process, Owner, Reason} ->
            error({transport_owner_failed, Reason})
    after 2000 ->
        exit(Owner, kill),
        error(transport_owner_not_ready)
    end.

kill_owner(Owner) ->
    Monitor = monitor(process, Owner),
    exit(Owner, kill),
    receive
        {'DOWN', Monitor, process, Owner, killed} -> true;
        {'DOWN', Monitor, process, Owner, _} -> false
    after 2000 ->
        demonitor(Monitor, [flush]),
        false
    end.

serve(Listen, Owner, Mode) ->
    case gen_tcp:accept(Listen, 2000) of
        {ok, Socket} ->
            gen_tcp:close(Listen),
            case read_request(Socket, <<>>) of
                {ok, Body} ->
                    Owner ! {fixture_body, self(), Body},
                    respond(Socket, Mode, Owner);
                {error, Reason} ->
                    Owner ! {fixture_error, self(), Reason}
            end;
        _ ->
            gen_tcp:close(Listen)
    end.

read_request(Socket, Acc) ->
    case binary:match(Acc, <<"\r\n\r\n">>) of
        {HeaderEnd, 4} ->
            <<Headers:HeaderEnd/binary, _Separator:4/binary, Rest/binary>> = Acc,
            Length = content_length(Headers),
            read_body(Socket, Rest, Length);
        nomatch ->
            case gen_tcp:recv(Socket, 0, 2000) of
                {ok, Bytes} -> read_request(Socket, <<Acc/binary, Bytes/binary>>);
                Error -> Error
            end
    end.

content_length(Headers) ->
    Lines = binary:split(Headers, <<"\r\n">>, [global]),
    content_length_lines(Lines).

content_length_lines([]) -> 0;
content_length_lines([Line | Rest]) ->
    case binary:split(Line, <<":">>) of
        [Name, Value] ->
            case string:lowercase(string:trim(Name)) of
                <<"content-length">> -> binary_to_integer(string:trim(Value));
                _ -> content_length_lines(Rest)
            end;
        _ -> content_length_lines(Rest)
    end.

read_body(_Socket, Body, Length) when byte_size(Body) >= Length ->
    {ok, binary:part(Body, 0, Length)};
read_body(Socket, Body, Length) ->
    case gen_tcp:recv(Socket, Length - byte_size(Body), 2000) of
        {ok, Bytes} -> read_body(Socket, <<Body/binary, Bytes/binary>>, Length);
        Error -> Error
    end.

respond(Socket, stream, Owner) ->
    ok = gen_tcp:send(Socket, [
        <<"HTTP/1.1 200 OK\r\n">>,
        <<"content-type: application/octet-stream\r\n">>,
        <<"transfer-encoding: chunked\r\n\r\n">>,
        <<"3\r\none\r\n">>
    ]),
    receive after 40 -> ok end,
    ok = gen_tcp:send(Socket, <<"3\r\ntwo\r\n0\r\n\r\n">>),
    wait_for_close(Socket, Owner);
respond(Socket, close_delimited, Owner) ->
    ok = gen_tcp:send(Socket, [
        <<"HTTP/1.0 200 OK\r\n">>,
        <<"content-type: application/octet-stream\r\n\r\n">>
    ]),
    wait_for_close(Socket, Owner).

wait_for_close(Socket, Owner) ->
    case gen_tcp:recv(Socket, 0, infinity) of
        {error, closed} -> Owner ! {fixture_closed, self()};
        {error, Reason} -> Owner ! {fixture_error, self(), Reason};
        {ok, _} -> wait_for_close(Socket, Owner)
    end,
    gen_tcp:close(Socket).
