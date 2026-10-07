-module(albedo_storage_test_support).
-export([signal/2]).

signal(Operation, <<>>) ->
    io:format("{\"working\":\"~ts\"}~n", [Operation]), nil;
signal(_, Path) ->
    ok = file:write_file(Path, [os:getpid(), "\n"]), nil.
