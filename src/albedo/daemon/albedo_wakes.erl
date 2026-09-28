%% Session wake registry: session id -> the submit closure its actor registered.
%%
%% The kernel reports finished background jobs through a host route, which runs
%% outside any session actor, so the notice needs a lookup from session id to
%% the actor that can submit a turn. Registered closures answer the Gleam
%% `run.Wake` type: delivered, busy (the kernel retries), or
%% {unavailable, Reason}.
-module(albedo_wakes).
-export([register/2, forget/1, deliver/3]).

-define(TABLE, albedo_wakes).

register(Id, Fun) -> albedo_registry:register(?TABLE, Id, Fun).

forget(Id) -> albedo_registry:forget(?TABLE, Id).

%% The session's answer to one wake; a missing or crashed session is unavailable.
deliver(Id, Display, Text) ->
    albedo_registry:call(?TABLE, Id, 2, [Display, Text],
                         {unavailable, <<"session unavailable">>},
                         {unavailable, <<"session unavailable">>}).
