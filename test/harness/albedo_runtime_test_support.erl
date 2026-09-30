-module(albedo_runtime_test_support).
-export([temporary_database/0, cleanup/1, own_rss/0, missing_rss/0, kernel_memory/1]).
temporary_database() ->
    unicode:characters_to_binary(filename:join(os:getenv("TMPDIR", "/tmp"), "albedo-" ++ binary_to_list(albedo_native:new_id()) ++ ".sqlite" )).
cleanup(Path) ->
    lists:foreach(fun(Suffix) -> file:delete(<<Path/binary, Suffix/binary>>) end,
                  [<<>>, <<"-wal">>, <<"-shm">>]),
    _ = file:del_dir_r(<<Path/binary, ".backup">>),
    nil.

%% Memory accounting against processes whose existence is not in question.
own_rss() -> albedo_daemon:rss([list_to_integer(os:getpid())]).
missing_rss() -> albedo_daemon:rss([2147483646]).

%% A barrier followed by GC measures retained ownership, not transient boot garbage.
kernel_memory({session, _, _, Kernel, _, _, _, _}) ->
    _ = albedo_python:events(Kernel),
    true = erlang:garbage_collect(Kernel),
    {memory, Bytes} = erlang:process_info(Kernel, memory),
    Bytes.
