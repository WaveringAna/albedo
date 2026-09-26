%% The agents bus: every session's activity, fanned out to whoever watches the
%% orchestrator view. Subscribers are closures owned by a process; a closure
%% only sends a message, and a dead owner's entry is dropped on the next
%% publish, so a closed stream needs no cleanup call.
-module(albedo_bus).
-export([subscribe/2, publish/1]).

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
