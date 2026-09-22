%% Session wake registry: session id -> the submit closure its actor registered.
%%
%% The kernel reports finished background jobs through a host route, which runs
%% outside any session actor, so the notice needs a lookup from session id to
%% the actor that can submit a turn. Registered closures answer "" when the
%% wake was submitted and a refusal message otherwise; "session is busy" is the
%% one the kernel retries.
-module(albedo_wakes).
-export([register/2, forget/1, deliver/3]).

-define(TABLE, albedo_wakes).

register(Id, Fun) -> albedo_registry:register(?TABLE, Id, Fun).

forget(Id) -> albedo_registry:forget(?TABLE, Id).

%% The refusal the caller should relay, or "" when the wake was submitted.
deliver(Id, Display, Text) ->
    case albedo_registry:fetch(?TABLE, Id, 2) of
        {ok, Fun} ->
            try Fun(Display, Text)
            catch _:_ -> <<"session unavailable">>
            end;
        undefined -> <<"session unavailable">>
    end.
