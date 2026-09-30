%% Unit tests read extension settings from ALBEDO_HOME; pointing it at a fresh
%% directory keeps a developer's own ~/.albedo (a disabled compaction strategy,
%% an MCP server) from changing what the tests see.
%%
%% The directory is the run's scratch space: <root>/gleam-<pid> under the root
%% the Python suites share (test/scratch.py). It is also TMPDIR, so every file a
%% test writes is removed with it when the run ends, and a run that died first
%% is swept by the next Python suite, which removes the <name>-<pid> directories
%% of processes that no longer exist.
-module(albedo_test_home).
-export([isolate/0, cleanup/0]).

isolate() ->
    Root = os:getenv("ALBEDO_TEST_TMP", "/tmp/albedo-tests"),
    Dir = filename:join(Root, "gleam-" ++ os:getpid()),
    ok = filelib:ensure_path(Dir),
    persistent_term:put(?MODULE, Dir),
    true = os:putenv("ALBEDO_HOME", Dir),
    true = os:putenv("TMPDIR", Dir),
    nil.

cleanup() ->
    _ = file:del_dir_r(persistent_term:get(?MODULE)),
    nil.
