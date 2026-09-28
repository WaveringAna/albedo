%% Session command state-op registry: session id -> the state closure its actor
%% registered.
%%
%% A command run executes outside the session actor (the kernel's host-call
%% process or an HTTP request process), so its state access needs a lookup from
%% session id to the actor that owns the state. The closure returns a Gleam
%% Result ({ok, Json} | {error, Message}); exceptions answer an error rather
%% than propagating into the caller. A caught failure may follow a timeout
%% whose message still runs later, so it names the outcome as unknown rather
%% than failed.
-module(albedo_commands).
-export([register/2, forget/1, call/2]).

-define(TABLE, albedo_commands).

register(Id, Fun) -> albedo_registry:register(?TABLE, Id, Fun).

forget(Id) -> albedo_registry:forget(?TABLE, Id).

%% The registered closure's Result, or an error when the session is not here.
call(Id, Op) ->
    albedo_registry:call(?TABLE, Id, 1, [Op],
                         {error, <<"session unavailable">>},
                         {error, <<"session state call failed; outcome unknown">>}).
