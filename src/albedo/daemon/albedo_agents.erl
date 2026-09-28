%% The agents seam: one handler, registered by the session registry when the
%% daemon starts, that answers what an agent asks of other sessions. Calls come
%% from kernel host routes, outside every actor. The handler answers a Gleam
%% Result(Json, String); a missing or crashed handler is an error, not a crash.
-module(albedo_agents).
-export([register/1, call/1]).

-define(TABLE, albedo_agents).

register(Fun) -> albedo_registry:register(?TABLE, handler, Fun).

call(Op) ->
    albedo_registry:call(?TABLE, handler, 1, [Op],
                         {error, <<"agents are unavailable">>},
                         {error, <<"agents are unavailable; outcome unknown">>}).
