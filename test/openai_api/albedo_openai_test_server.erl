-module(albedo_openai_test_server).
-export([with_server/4, request/1, closed/1]).

with_server(Body, Status, ContentType, Run) ->
    {ok, Listen} = gen_tcp:listen(0, [binary, {active, false}, {ip, {127,0,0,1}}, {reuseaddr, true}]),
    {ok, {_, Port}} = inet:sockname(Listen),
    Owner = self(),
    Pid = spawn(fun() ->
        {ok, Socket} = gen_tcp:accept(Listen, 3000),
        try
            Request = read_request(Socket, <<>>),
            Owner ! {self(), request, Request},
            ok = gen_tcp:send(Socket, "HTTP/1.1 103 Early Hints\r\n\r\n"),
            ok = gen_tcp:send(Socket, ["HTTP/1.1 ", integer_to_binary(Status), " test\r\n",
                "content-type: ", ContentType, "\r\ncontent-length: ", integer_to_binary(byte_size(Body)),
                "\r\nconnection: keep-alive\r\n\r\n", Body]),
            case gen_tcp:recv(Socket, 0, 3000) of
                {error, closed} -> Owner ! {self(), closed};
                _ -> ok
            end
        after gen_tcp:close(Socket) end
    end),
    Base = <<"http://127.0.0.1:", (integer_to_binary(Port))/binary>>,
    try Run(Base, Pid)
    after
        gen_tcp:close(Listen),
        exit(Pid, kill),
        flush(Pid)
    end.

read_request(Socket, Acc) ->
    case binary:split(Acc, <<"\r\n\r\n">>) of
        [Head, Body] ->
            Lines = binary:split(Head, <<"\r\n">>, [global]),
            Length = lists:foldl(fun(Line, N) ->
                case binary:split(string:lowercase(Line), <<":">>) of
                    [<<"content-length">>, Value] -> binary_to_integer(string:trim(Value));
                    _ -> N
                end
            end, 0, Lines),
            Rest = read_body(Socket, Body, Length),
            <<Head/binary, "\r\n\r\n", Rest/binary>>;
        _ ->
            {ok, Data} = gen_tcp:recv(Socket, 0, 3000),
            read_request(Socket, <<Acc/binary, Data/binary>>)
    end.

read_body(_, Body, Length) when byte_size(Body) >= Length -> Body;
read_body(Socket, Body, Length) ->
    {ok, Data} = gen_tcp:recv(Socket, 0, 3000),
    read_body(Socket, <<Body/binary, Data/binary>>, Length).

request(Pid) -> receive {Pid, request, Data} -> Data after 3000 -> error(request_timeout) end.
closed(Pid) -> receive {Pid, closed} -> true after 3000 -> false end.
flush(Pid) -> receive {Pid, _, _} -> flush(Pid); {Pid, _} -> flush(Pid) after 0 -> ok end.
