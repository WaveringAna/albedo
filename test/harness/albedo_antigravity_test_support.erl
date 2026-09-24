-module(albedo_antigravity_test_support).
%% A scripted HTTP server: each path answers with its responses in order, the
%% last one repeating, and records the requests it saw.
-export([with_routes/2, seen/1]).

with_routes(Routes, Run) ->
    {ok, Listen} = gen_tcp:listen(0, [binary, {active, false}, {ip, {127,0,0,1}}, {reuseaddr, true}, {packet, http_bin}]),
    {ok, {_, Port}} = inet:sockname(Listen),
    Log = ets:new(seen, [public, bag]),
    Script = ets:new(script, [public, set]),
    [ets:insert(Script, {Path, Responses}) || {Path, Responses} <- Routes],
    Pid = spawn(fun() -> accept(Listen, Script, Log) end),
    Base = <<"http://127.0.0.1:", (integer_to_binary(Port))/binary>>,
    try Run(Base, Log)
    after exit(Pid, kill), gen_tcp:close(Listen)
    end.

seen(Log) -> lists:sort([Path || {Path} <- ets:tab2list(Log)]).

accept(Listen, Script, Log) ->
    {ok, Socket} = gen_tcp:accept(Listen),
    {ok, {http_request, _, {abs_path, Target}, _}} = gen_tcp:recv(Socket, 0, 5000),
    Length = headers(Socket, 0),
    inet:setopts(Socket, [{packet, raw}]),
    _ = Length > 0 andalso gen_tcp:recv(Socket, Length, 5000),
    [Path | _] = binary:split(Target, <<"?">>),
    ets:insert(Log, {Path}),
    {Status, Body} = case ets:lookup(Script, Path) of
        [{_, [Only]}] -> Only;
        [{_, [Next | Rest]}] -> ets:insert(Script, {Path, Rest}), Next;
        [] -> {404, <<"{}">>}
    end,
    gen_tcp:send(Socket, [<<"HTTP/1.1 ">>, integer_to_binary(Status), <<" x\r\ncontent-type: application/json\r\ncontent-length: ">>,
                          integer_to_binary(byte_size(Body)), <<"\r\nconnection: close\r\n\r\n">>, Body]),
    gen_tcp:close(Socket),
    accept(Listen, Script, Log).

headers(Socket, Length) ->
    case gen_tcp:recv(Socket, 0, 5000) of
        {ok, {http_header, _, 'Content-Length', _, Value}} -> headers(Socket, binary_to_integer(Value));
        {ok, http_eoh} -> Length;
        {ok, _} -> headers(Socket, Length)
    end.
