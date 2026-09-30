-module(albedo_daemon).
-export([env/1,ready/3,read_config/1,directory/1,shutdown/0,rss/1,watch_parent/1,hold/1]).
env(Name) -> case os:getenv(binary_to_list(Name)) of false -> <<>>; Value -> unicode:characters_to_binary(Value) end.
%% config.json with each profile's saved apiKey filled in from creds.json. A
%% file that is not a JSON object is passed on as it is, to fail decoding.
read_config(Home) ->
    case albedo_credentials:config(Home) of
      {ok,Config} -> {ok,iolist_to_binary(json:encode(Config))};
      {error,invalid} -> file:read_file(filename:join(Home,<<"config.json">>));
      {error,_} -> {error,nil}
    end.
directory(Path) -> filename:pathtype(Path) =:= absolute andalso filelib:is_dir(Path).
ready(Home,Port,Token) ->
    File=filename:join(Home,<<"daemon.json">>), Temp= <<File/binary,".tmp">>,
    Record=#{pid=>list_to_integer(os:getpid()),port=>Port,token=>Token,version=>2},
    Data=json:encode(case os:getenv("ALBEDO_BUILD") of
        false -> Record;
        Build -> Record#{build=>unicode:characters_to_binary(Build)}
    end),
    case file:write_file(Temp,Data,[write,sync]) of
      ok -> ok=file:change_mode(Temp,8#600), file:rename(Temp,File), {ok,nil};
      {error,Reason} -> {error,atom_to_binary(Reason)}
    end.
%% Called once the drain has closed every session, kernel and store. What
%% init:stop() would still do is take the VM down application by application,
%% and kernel's user_sup sleeps a flat second in terminate/2 so buffered
%% output can drain. Only the logger buffers here (io requests answer once
%% written), so flush its handlers and halt, which also flushes the ports.
%% cpu_sup is stopped first, which tells its port program to quit: otherwise
%% the program reports the VM's disappearance into the log.
shutdown() ->
    _ = catch supervisor:terminate_child(os_mon_sup, cpu_sup),
    _ = [logger_std_h:filesync(Id)
         || #{id := Id, module := logger_std_h} <- logger:get_handler_config()],
    erlang:halt(0).

%% Keeps the home lock connection reachable; a collected connection closes and
%% releases the lock.
hold(Connection) -> put(albedo_home_lock, Connection), nil.

%% Stop when the process named by Parent exits, so a killed test runner cannot leave
%% its detached daemon behind. The sh loop also ends if this VM dies first.
watch_parent(Parent) ->
    case string:to_integer(Parent) of
        {Pid, <<>>} when Pid > 0 ->
            Script = "while kill -0 " ++ integer_to_list(Pid) ++ " 2>/dev/null && kill -0 $PPID 2>/dev/null; do sleep 1; done",
            spawn(fun() ->
                Port = open_port({spawn_executable, "/bin/sh"}, [{args, ["-c", Script]}, exit_status, hide]),
                receive {Port, {exit_status, _}} -> init:stop() end
            end),
            nil;
        _ -> nil
    end.

%% Resident memory of live kernels, in kibibytes. One ps per sweep, never per session;
%% a pid ps does not report is simply absent from the result.
rss([]) -> [];
rss(Pids) ->
    Args = ["-o", "pid=,rss=", "-p", lists:join(",", [integer_to_list(P) || P <- Pids])],
    case os:find_executable("ps") of
        false -> [];
        Ps ->
            Port = open_port({spawn_executable, Ps}, [{args, Args}, binary, exit_status, stderr_to_stdout, hide]),
            collect_rss(Port, [])
    end.

collect_rss(Port, Chunks) ->
    receive
        {Port, {data, Chunk}} -> collect_rss(Port, [Chunk | Chunks]);
        {Port, {exit_status, _}} -> parse_rss(iolist_to_binary(lists:reverse(Chunks)))
    after 5000 ->
        try port_close(Port) catch _:_ -> ok end,
        []
    end.

parse_rss(Output) ->
    [{P, K} || Line <- binary:split(Output, <<"\n">>, [global, trim_all]),
               {P, K} <- [pair(binary:split(string:trim(Line), <<" ">>, [global, trim_all]))],
               is_integer(P), is_integer(K)].

pair([Pid, Kb]) ->
    try {binary_to_integer(Pid), binary_to_integer(Kb)} catch _:_ -> {nil, nil} end;
pair(_) -> {nil, nil}.
