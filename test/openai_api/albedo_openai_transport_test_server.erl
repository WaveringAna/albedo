-module(albedo_openai_transport_test_server).

-include_lib("public_key/include/public_key.hrl").

-export([start/1, start_tls/1, url/1, trust/1, distrust/0, await_body/1, await_closed/1,
    stop/1, owner_after_headers/1, kill_owner/1]).

start(Mode) ->
    {ok, Listen} = gen_tcp:listen(0, [binary, {active, false},
        {reuseaddr, true}, {packet, raw}]),
    {ok, {_Address, Port}} = inet:sockname(Listen),
    Owner = self(),
    Pid = spawn(fun() -> serve({gen_tcp, Listen}, Owner, Mode) end),
    URL = iolist_to_binary(io_lib:format("http://127.0.0.1:~B/v1/chat?fixture=yes", [Port])),
    {fixture, Pid, URL, none}.

%% A TLS server for localhost under a fresh test CA, which no system trusts
%% until trust/1 loads it.
start_tls(Mode) ->
    {ok, _} = application:ensure_all_started(ssl),
    Name = #'Extension'{extnID = ?'id-ce-subjectAltName', critical = false,
                        extnValue = [{dNSName, "localhost"}]},
    #{server_config := Server, client_config := Client} = public_key:pkix_test_data(#{
        server_chain => #{root => key(), intermediates => [], peer => [{extensions, [Name]} | key()]},
        client_chain => #{root => key(), intermediates => [], peer => key()}}),
    CaFile = filename:join(os:getenv("TMPDIR", "/tmp"),
        "albedo-test-ca-" ++ integer_to_list(erlang:unique_integer([positive])) ++ ".pem"),
    Roots = [{'Certificate', Der, not_encrypted} || Der <- proplists:get_value(cacerts, Client)],
    ok = file:write_file(CaFile, public_key:pem_encode(Roots)),
    {ok, Listen} = ssl:listen(0, [binary, {active, false}, {reuseaddr, true} | Server]),
    {ok, {_Address, Port}} = ssl:sockname(Listen),
    Owner = self(),
    Pid = spawn(fun() -> serve({ssl, Listen}, Owner, Mode) end),
    URL = iolist_to_binary(io_lib:format("https://localhost:~B/v1/chat", [Port])),
    {fixture, Pid, URL, CaFile}.

key() -> [{key, {namedCurve, ?secp256r1}}, {digest, sha256}].

url({fixture, _Pid, URL, _}) -> URL.

trust({fixture, _Pid, _URL, CaFile}) ->
    ok = public_key:cacerts_load(CaFile),
    nil.

distrust() ->
    public_key:cacerts_clear(),
    nil.

await_body({fixture, Pid, _URL, _}) ->
    receive
        {fixture_body, Pid, Body} -> Body
    after 2000 ->
        timeout
    end.

await_closed({fixture, Pid, _URL, _}) ->
    receive
        {fixture_closed, Pid} -> true;
        {fixture_error, Pid, _} -> false
    after 2000 ->
        false
    end.

stop({fixture, Pid, _URL, CaFile}) ->
    exit(Pid, shutdown),
    _ = is_list(CaFile) andalso file:delete(CaFile),
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

%% Every mode but drop_second takes one connection and closes the listener,
%% so a second request can only arrive on a kept-alive connection.
serve(Listen, Owner, drop_second) ->
    case accept(Listen) of
        {ok, First} ->
            {ok, Body} = read_request(First, <<>>),
            Owner ! {fixture_body, self(), Body},
            ok = send(First, length_response()),
            {ok, _} = read_request(First, <<>>),
            close(First),
            serve(Listen, Owner, keep_alive);
        _ -> close(Listen)
    end;
serve(Listen, Owner, Mode) ->
    case accept(Listen) of
        {ok, Socket} ->
            close(Listen),
            case read_request(Socket, <<>>) of
                {ok, Body} ->
                    Owner ! {fixture_body, self(), Body},
                    respond(Socket, Mode, Owner);
                {error, Reason} ->
                    Owner ! {fixture_error, self(), Reason}
            end;
        _ ->
            close(Listen)
    end.

accept({gen_tcp, Listen}) ->
    case gen_tcp:accept(Listen, 2000) of
        {ok, Socket} -> {ok, {gen_tcp, Socket}};
        Error -> Error
    end;
accept({ssl, Listen}) ->
    case ssl:transport_accept(Listen, 2000) of
        {ok, Socket} ->
            case ssl:handshake(Socket, 2000) of
                {ok, Tls} -> {ok, {ssl, Tls}};
                Error -> Error
            end;
        Error -> Error
    end.

send({Module, Socket}, Data) -> Module:send(Socket, Data).
recv({Module, Socket}, Length) -> Module:recv(Socket, Length, 2000).
close({Module, Socket}) -> Module:close(Socket).

read_request(Socket, Acc) ->
    case binary:match(Acc, <<"\r\n\r\n">>) of
        {HeaderEnd, 4} ->
            <<Headers:HeaderEnd/binary, _Separator:4/binary, Rest/binary>> = Acc,
            Length = content_length(Headers),
            read_body(Socket, Rest, Length);
        nomatch ->
            case recv(Socket, 0) of
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
    case recv(Socket, Length - byte_size(Body)) of
        {ok, Bytes} -> read_body(Socket, <<Body/binary, Bytes/binary>>, Length);
        Error -> Error
    end.

length_response() ->
    <<"HTTP/1.1 200 OK\r\ncontent-length: 16\r\n\r\nhello world, all">>.

respond(Socket, stream, Owner) ->
    ok = send(Socket, [
        <<"HTTP/1.1 200 OK\r\n">>,
        <<"content-type: application/octet-stream\r\n">>,
        <<"transfer-encoding: chunked\r\n\r\n">>,
        <<"3\r\none\r\n">>
    ]),
    receive after 40 -> ok end,
    ok = send(Socket, <<"3\r\ntwo\r\n0\r\n\r\n">>),
    wait_for_close(Socket, Owner);
respond({gen_tcp, Port} = Socket, chunked_trickle, Owner) ->
    ok = inet:setopts(Port, [{nodelay, true}]),
    Response = <<"HTTP/1.1 100 Continue\r\n\r\n",
        "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n",
        "Transfer-Encoding: chunked\r\n\r\n",
        "5;name=value\r\nhello\r\n1\r\n \r\nA\r\nworld, all\r\n",
        "0\r\nx-trailer: yes\r\n\r\n">>,
    [begin ok = send(Socket, <<Byte>>), receive after 1 -> ok end end
     || <<Byte>> <= Response],
    wait_for_close(Socket, Owner);
respond(Socket, content_length, Owner) ->
    ok = send(Socket, length_response()),
    wait_for_close(Socket, Owner);
respond(Socket, keep_alive, Owner) ->
    ok = send(Socket, length_response()),
    next_request(Socket, keep_alive, Owner);
respond(Socket, slow_end, Owner) ->
    ok = send(Socket, <<"HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n10\r\nhello world, all\r\n">>),
    receive after 10 -> ok end,
    case send(Socket, <<"0\r\n\r\n">>) of
        ok -> next_request(Socket, slow_end, Owner);
        {error, closed} -> Owner ! {fixture_closed, self()}
    end;
respond(Socket, close_delimited, Owner) ->
    ok = send(Socket, [
        <<"HTTP/1.0 200 OK\r\n">>,
        <<"content-type: application/octet-stream\r\n\r\n">>
    ]),
    wait_for_close(Socket, Owner).

next_request(Socket, Mode, Owner) ->
    case read_request(Socket, <<>>) of
        {ok, Body} ->
            Owner ! {fixture_body, self(), Body},
            respond(Socket, Mode, Owner);
        {error, closed} -> Owner ! {fixture_closed, self()};
        {error, Reason} -> Owner ! {fixture_error, self(), Reason}
    end.

wait_for_close(Socket, Owner) ->
    case recv(Socket, 0) of
        {error, closed} -> Owner ! {fixture_closed, self()};
        {error, timeout} -> wait_for_close(Socket, Owner);
        {error, Reason} -> Owner ! {fixture_error, self(), Reason};
        {ok, _} -> wait_for_close(Socket, Owner)
    end,
    close(Socket).
