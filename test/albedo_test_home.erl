%% Native tests discover settings under ALBEDO_HOME and instructions and skills
%% under HOME. Both roots belong to this run so developer files cannot change
%% the tests' compositions or discovery work.
%%
%% The directory is the run's scratch space: <root>/gleam-<pid> under the root
%% the Python suites share (test/scratch.py). It is also TMPDIR, so every file a
%% test writes is removed with it when the run ends, and a run that died first
%% is swept by the next Python suite, which removes the <name>-<pid> directories
%% of processes that no longer exist. Kernels keep their run directories under
%% it too, and leave when it disappears.
-module(albedo_test_home).
-export([isolate/0, cleanup/0]).

isolate() ->
    Root = os:getenv("ALBEDO_TEST_TMP", "/tmp/albedo-tests"),
    Dir = filename:join(Root, "gleam-" ++ os:getpid()),
    ok = filelib:ensure_path(Dir),
    UserHome = filename:join(Dir, "user-home"),
    ok = filelib:ensure_path(UserHome),
    persistent_term:put(?MODULE, Dir),
    true = os:putenv("ALBEDO_HOME", Dir),
    true = os:putenv("TMPDIR", Dir),
    true = os:putenv("HOME", UserHome),
    %% A detached kernel a test never stopped ends soon after, not in an hour.
    true = os:putenv("ALBEDO_KERNEL_GRACE_SECONDS", "20"),
    nil.

cleanup() ->
    _ = file:del_dir_r(persistent_term:get(?MODULE)),
    nil.
