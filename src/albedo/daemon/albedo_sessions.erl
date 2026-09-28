%% Live session actors by id. A session registers itself when it starts and is
%% forgotten when it closes, so a registry that restarts after a crash adopts
%% the sessions still running instead of starting a second actor for one.
-module(albedo_sessions).
-export([register/2, forget/1, find/1]).

-define(TABLE, albedo_sessions).

register(Id, Subject) -> albedo_registry:register(?TABLE, Id, Subject).

forget(Id) -> albedo_registry:forget(?TABLE, Id).

find(Id) ->
    case albedo_registry:lookup(?TABLE, Id) of
        {ok, _} = Ok -> Ok;
        undefined -> {error, nil}
    end.
