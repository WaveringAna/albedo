%% Observe running cache lifetime without loading or waking session actors.
-module(albedo_running_probe).
-export([state/1, close/1]).

state(Id) ->
    Records = case ets:whereis(albedo_running) of
        undefined -> [];
        _ -> ets:lookup(albedo_running, Id)
    end,
    json:encode(#{running => albedo_bus:running(Id), records => length(Records)}).

close(Id) ->
    {some, Session} = 'albedo@daemon@session':live(Id),
    nil = 'albedo@daemon@session':close(Session),
    <<"closed">>.
