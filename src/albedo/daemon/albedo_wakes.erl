%% Session wake registry: session id -> the submit closure its actor registered.
%%
%% The kernel reports finished background jobs through a host route, which runs
%% outside any session actor, so the notice needs a lookup from session id to
%% the actor that can submit a turn. Registered closures answer the Gleam
%% `run.Wake` type: delivered, busy (the kernel retries), or
%% {unavailable, Reason}.
-module(albedo_wakes).
-export([register/2, forget/1, deliver/3, deliver/4, on_missing/1]).

-define(TABLE, albedo_wakes).

register(Id, Fun) -> albedo_registry:register(?TABLE, Id, Fun).

forget(Id) -> albedo_registry:forget(?TABLE, Id).

%% The daemon's loader, for a wake whose session no actor is loaded for: an
%% idle session after a restart, whose kernel reattached on its own. It starts
%% the session, which registers its closure as it starts, and answers whether
%% it did.
on_missing(Load) -> persistent_term:put({?MODULE, loader}, Load), nil.

%% The session's answer to one wake. A session that is not loaded is loaded
%% once and asked again; one that cannot be, or crashes, is unavailable.
deliver(Id, Display, Text) -> deliver(Id, <<"job">>, Display, Text).

deliver(Id, Origin, Display, Text) ->
    case submit(Id, [Origin, Display, Text], missing) of
        missing ->
            case load(Id) of
                true -> submit(Id, [Origin, Display, Text], unavailable());
                false -> unavailable()
            end;
        Wake -> Wake
    end.

submit(Id, Args, Missing) ->
    albedo_registry:call(?TABLE, Id, 3, Args, Missing, unavailable()).

load(Id) ->
    case persistent_term:get({?MODULE, loader}, undefined) of
        undefined -> false;
        Load -> try Load(Id) catch _:_ -> false end
    end.

unavailable() -> {unavailable, <<"session unavailable">>}.
