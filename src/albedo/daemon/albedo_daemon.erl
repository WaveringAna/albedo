-module(albedo_daemon).
-include_lib("kernel/include/file.hrl").
-export([defaults/0,refuse_home/1,env/1,free_port/0,ready/3,read_config/1,directory/1,shutdown/0,rss/1,collect_idle/0,watch_parent/1,hold/1,http_request/1,build_digest/0,tree_digest/1]).
env(Name) -> case os:getenv(binary_to_list(Name)) of false -> <<>>; Value -> unicode:characters_to_binary(Value) end.
%% Home and authentication belong to the daemon, including direct starts.
defaults() ->
    try
        Home = case env(<<"ALBEDO_HOME">>) of
            <<>> -> filename:join(unicode:characters_to_binary(os:getenv("HOME")), <<".albedo">>);
            Specified -> Specified
        end,
        Absolute = filename:absname(Home),
        ok = filelib:ensure_dir(filename:join(Absolute, <<"daemon.lock">>)),
        ok = file:change_mode(Absolute, 8#700),
        Token = case env(<<"ALBEDO_TOKEN">>) of
            <<>> -> binary:encode_hex(crypto:strong_rand_bytes(32), lowercase);
            Supplied when byte_size(Supplied) >= 32 -> Supplied;
            _ -> error(token_too_short)
        end,
        {ok, {Absolute, Token}}
    catch Class:Reason ->
        {error, unicode:characters_to_binary(io_lib:format("daemon defaults failed: ~p:~p", [Class, Reason]))}
    end.

refuse_home(Home) ->
    io:format(standard_error, "storage is in use by another albedo daemon or maintenance command for ALBEDO_HOME=~ts~n", [Home]),
    erlang:halt(75).

%% A loopback port nothing listens on, which the OS just picked.
free_port() ->
    {ok, Socket} = gen_tcp:listen(0, [{ip, loopback}, {reuseaddr, true}]),
    {ok, Port} = inet:port(Socket),
    ok = gen_tcp:close(Socket),
    Port.
%% config.json with each profile's saved apiKey filled in from creds.json. A
%% file that is not a JSON object is passed on as it is, to fail decoding.
read_config(Home) ->
    case albedo_credentials:config(Home) of
      {ok,Config} -> {ok,iolist_to_binary(json:encode(Config))};
      {error,invalid} -> file:read_file(filename:join(Home,<<"config.json">>));
      {error,_} -> {error,nil}
    end.
directory(Path) -> filename:pathtype(Path) =:= absolute andalso filelib:is_dir(Path).
%% The content digest of this daemon's own build: sha256 over the sorted
%% relative paths and bytes of every regular file under the albedo app's
%% ebin/ and priv/ trees, symlinks followed. Memoized for the VM's life, so a
%% tree edited under a running daemon keeps the digest it booted with. Empty
%% when the tree cannot be read. The CLI hashes its candidate build with the
%% same recipe (cli/cmd/albedo/build_identity.go); the shared fixture in
%% test/fixtures/build-digest pins the two implementations together.
build_digest() ->
    case persistent_term:get(albedo_build_digest, none) of
        none ->
            case compute_build_digest() of
                <<>> -> <<>>;
                Digest ->
                    persistent_term:put(albedo_build_digest, Digest),
                    Digest
            end;
        Digest -> Digest
    end.

compute_build_digest() ->
    case code:lib_dir(albedo) of
        {error, _} -> <<>>;
        AppDir -> tree_digest(AppDir)
    end.

tree_digest(AppDir) ->
    Subtrees = [filename:join(AppDir, Sub) || Sub <- ["ebin", "priv"]],
    case build_files(Subtrees, []) of
        {ok, Files} -> hash_build_files(lists:sort(Files));
        {error, _} -> <<>>
    end.

%% Every regular file below the given roots, as {RelativePath, AbsolutePath}.
%% A missing root contributes nothing and any other unreadable path fails the
%% whole digest, which is the call the CLI's walker makes too.
build_files([], Acc) -> {ok, Acc};
build_files([Root | Rest], Acc) ->
    case file:read_file_info(Root) of
        {ok, #file_info{type = directory}} ->
            case walk_build_tree(Root, unicode:characters_to_binary(filename:basename(Root)), []) of
                {ok, Files} -> build_files(Rest, Acc ++ Files);
                {error, _} -> {error, nil}
            end;
        {ok, _} -> build_files(Rest, Acc);
        {error, enoent} -> build_files(Rest, Acc);
        {error, _} -> {error, nil}
    end.

walk_build_tree(Dir, Rel, Acc) ->
    case file:list_dir(Dir) of
        {ok, Names} -> walk_build_entries(Dir, Rel, lists:sort(Names), Acc);
        {error, _} -> {error, nil}
    end.

walk_build_entries(_Dir, _Rel, [], Acc) -> {ok, Acc};
walk_build_entries(Dir, Rel, [Name | Rest], Acc) ->
    Path = filename:join(Dir, Name),
    ChildRel = <<Rel/binary, $/, (unicode:characters_to_binary(Name))/binary>>,
    case file:read_file_info(Path) of
        {ok, #file_info{type = directory}} ->
            case walk_build_tree(Path, ChildRel, Acc) of
                {ok, Files} -> walk_build_entries(Dir, Rel, Rest, Files);
                {error, _} -> {error, nil}
            end;
        {ok, #file_info{type = regular}} ->
            walk_build_entries(Dir, Rel, Rest, [{ChildRel, Path} | Acc]);
        {ok, _} -> walk_build_entries(Dir, Rel, Rest, Acc);
        {error, _} -> {error, nil}
    end.

hash_build_files(Files) -> hash_build_files(Files, crypto:hash_init(sha256)).
hash_build_files([], Ctx) -> binary:encode_hex(crypto:hash_final(Ctx), lowercase);
hash_build_files([{Rel, Path} | Rest], Ctx) ->
    case file:read_file(Path) of
        {ok, Bytes} -> hash_build_files(Rest, crypto:hash_update(Ctx, [Rel, Bytes]));
        {error, _} -> <<>>
    end.

ready(Home,Port,Token) ->
    File=filename:join(Home,<<"daemon.json">>), Temp= <<File/binary,".tmp">>,
    Record=#{pid=>list_to_integer(os:getpid()),port=>Port,token=>Token,version=>3},
    Labelled=case os:getenv("ALBEDO_BUILD") of
        false -> Record;
        Build -> Record#{build=>unicode:characters_to_binary(Build)}
    end,
    Data=json:encode(case build_digest() of
        <<>> -> Labelled;
        Digest -> Labelled#{digest=>Digest}
    end),
    case file:write_file(Temp,Data,[write,sync]) of
      ok ->
        case file:change_mode(Temp,8#600) of
          ok -> case file:rename(Temp,File) of
            ok -> {ok,nil};
            {error,Reason} -> {error,atom_to_binary(Reason)}
          end;
          {error,Reason} -> {error,atom_to_binary(Reason)}
        end;
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
    _ = try supervisor:terminate_child(os_mon_sup, cpu_sup) catch exit:_ -> ok end,
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

%% Collect every waiting process whose heap has grown past 1 MB. A long-lived
%% actor keeps the heap a busy moment grew to until it fills again; a full
%% collection shrinks it to what it holds, so the allocator can give the rest
%% back. Run from the maintenance sweep, never from an actor's own loop.
collect_idle() ->
    [erlang:garbage_collect(Pid)
     || Pid <- erlang:processes(),
        [{status, waiting}, {message_queue_len, 0}, {total_heap_size, Words}] <-
            [erlang:process_info(Pid, [status, message_queue_len, total_heap_size])],
        Words * erlang:system_info(wordsize) > 1048576],
    nil.

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

%% An admitted HTTP request can outlive the worker/store it was handed just
%% before shutdown. Only that call transport failure becomes an unavailable
%% response; application errors retain their original class and stacktrace.
http_request(Handle) ->
    try {ok, Handle()}
    catch
        error:#{module := <<"gleam/erlang/process">>,
                function := <<"perform_call">>,
                message := Message}=Reason:Stack ->
            case Message of
                <<"callee exited: ",_/binary>> -> {error,nil};
                <<"Callee subject had no owner">> -> {error,nil};
                <<"callee did not send reply before timeout">> -> {error,nil};
                _ -> erlang:raise(error,Reason,Stack)
            end
    end.
