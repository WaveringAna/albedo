-module(albedo_runtime_test_support).
-export([temporary_database/0, cleanup/1, run_python/2, own_rss/0, missing_rss/0, kernel_memory/1]).
temporary_database() ->
    unicode:characters_to_binary(filename:join("/tmp", "albedo-" ++ binary_to_list(albedo_native:new_id()) ++ ".sqlite" )).
cleanup(Path) ->
    lists:foreach(fun(Suffix) -> file:delete(<<Path/binary, Suffix/binary>>) end,
                  [<<>>, <<"-wal">>, <<"-shm">>]), nil.

%% Run a Python harness from the project root and return its combined output.
run_python(Script, TimeoutMs) ->
    case os:find_executable("python3") of
        false -> {error, <<"python3 is not on PATH">>};
        Python ->
            Port = open_port({spawn_executable, Python},
                             [{args, [binary_to_list(Script)]}, binary, exit_status,
                              stderr_to_stdout, hide]),
            collect(Port, TimeoutMs, [])
    end.

collect(Port, TimeoutMs, Chunks) ->
    receive
        {Port, {data, Chunk}} -> collect(Port, TimeoutMs, [Chunk | Chunks]);
        {Port, {exit_status, 0}} -> {ok, output(Chunks)};
        {Port, {exit_status, Status}} ->
            {error, <<(integer_to_binary(Status))/binary, ": ", (output(Chunks))/binary>>}
    after TimeoutMs ->
        try port_close(Port) catch _:_ -> ok end,
        {error, <<"harness timed out: ", (output(Chunks))/binary>>}
    end.

output(Chunks) -> iolist_to_binary(lists:reverse(Chunks)).

%% Memory accounting against processes whose existence is not in question.
own_rss() -> albedo_daemon:rss([list_to_integer(os:getpid())]).
missing_rss() -> albedo_daemon:rss([2147483646]).

%% A barrier followed by GC measures retained ownership, not transient boot garbage.
kernel_memory({session, _, _, Kernel, _, _, _}) ->
    _ = albedo_python:events(Kernel),
    true = erlang:garbage_collect(Kernel),
    {memory, Bytes} = erlang:process_info(Kernel, memory),
    Bytes.
