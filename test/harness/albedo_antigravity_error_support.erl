%% One raw Cloud Code Assist error through the production discovery HTTP path.
-module(albedo_antigravity_error_support).
-export([discover/1]).

discover(Body) ->
    {ok, Listen} = gen_tcp:listen(0, [binary, {active, false}, {packet, http_bin},
                                    {ip, {127, 0, 0, 1}}]),
    {ok, {_, Port}} = inet:sockname(Listen),
    {Server, Monitor} = spawn_monitor(fun() ->
        {ok, Socket} = gen_tcp:accept(Listen, 5000),
        {ok, {http_request, _, _, _}} = gen_tcp:recv(Socket, 0, 5000),
        Length = headers(Socket, 0),
        ok = inet:setopts(Socket, [{packet, raw}]),
        case Length of 0 -> ok; _ -> {ok, _} = gen_tcp:recv(Socket, Length, 5000) end,
        ok = gen_tcp:send(Socket, ["HTTP/1.1 403 Forbidden\r\nContent-Type: application/json\r\n",
            "Connection: close\r\nContent-Length: ", integer_to_list(byte_size(Body)), "\r\n\r\n", Body]),
        gen_tcp:close(Socket)
    end),
    Base = iolist_to_binary(["http://127.0.0.1:", integer_to_list(Port)]),
    try albedo_antigravity:discover(<<"test-token">>, {endpoints, <<>>, <<>>, Base}, fun(_) -> nil end)
    after
        gen_tcp:close(Listen),
        receive
            {'DOWN', Monitor, process, Server, normal} -> ok;
            {'DOWN', Monitor, process, Server, Reason} -> error({error_server_failed, Reason})
        after 6000 -> exit(Server, kill), error(error_server_stalled)
        end
    end.

headers(Socket, Length) ->
    case gen_tcp:recv(Socket, 0, 5000) of
        {ok, http_eoh} -> Length;
        {ok, {http_header, _, 'Content-Length', _, Value}} -> headers(Socket, binary_to_integer(Value));
        {ok, {http_header, _, _, _, _}} -> headers(Socket, Length)
    end.
