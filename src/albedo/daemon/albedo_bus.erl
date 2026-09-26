%% The agents bus: every session's activity, fanned out to whoever watches the
%% orchestrator view. Subscribers are closures owned by a process; a closure
%% only sends a message, and a dead owner's entry is dropped on the next
%% publish, so a closed stream needs no cleanup call.
-module(albedo_bus).
-export([subscribe/2, publish/1, mark_running/2, running/1, forget/1]).

-define(TABLE, albedo_bus).

subscribe(Owner, Fun) ->
    albedo_registry:register(?TABLE, make_ref(), {Owner, Fun}).

publish(Event) ->
    case ets:whereis(?TABLE) of
        undefined -> nil;
        _ ->
            lists:foreach(
                fun({Ref, {Owner, Fun}}) ->
                    case is_process_alive(Owner) of
                        true -> try Fun(Event) catch _:_ -> ok end;
                        false -> ets:delete(?TABLE, Ref)
                    end
                end,
                ets:tab2list(?TABLE)),
            nil
    end.

%% Whether each session is running a turn, as its actor last announced. The
%% registry reads this instead of asking a session, which may be busy.
mark_running(Session, Running) ->
    albedo_registry:register(albedo_running, Session, Running).

running(Session) ->
    case ets:whereis(albedo_running) of
        undefined -> false;
        _ ->
            case ets:lookup(albedo_running, Session) of
                [{_, true}] -> true;
                _ -> false
            end
    end.

forget(Session) -> albedo_registry:forget(albedo_running, Session).
