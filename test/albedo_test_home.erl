%% Unit tests read extension settings from ALBEDO_HOME; pointing it at a fresh
%% directory keeps a developer's own ~/.albedo (a disabled compaction strategy,
%% an MCP server) from changing what the tests see.
-module(albedo_test_home).
-export([isolate/0]).

isolate() ->
    Dir = filename:join(os:getenv("TMPDIR", "/tmp"), "albedo-gleam-test-" ++ os:getpid()),
    ok = filelib:ensure_path(Dir),
    true = os:putenv("ALBEDO_HOME", Dir),
    nil.
