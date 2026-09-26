%% Runs a function in the calling process and turns a crash into a value, so
%% work done off an actor still reports back when it fails.
-module(albedo_protect).
-export([run/1]).

run(Fun) ->
    try {ok, Fun()}
    catch Class:Reason -> {error, iolist_to_binary(io_lib:format("~p: ~P", [Class, Reason, 12]))}
    end.
