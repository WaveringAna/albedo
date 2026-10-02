%% Bounded subscriber queues. Publishers admit directly into ETS; subscriber
%% mailboxes carry only a coalesced wake, never event payloads.
-module(albedo_bus).
-export([subscribe/2, drain/1, rearm/2, publish/1, has_subscribers/0,
         mark_running/2, running/1, forget/1]).

-define(TABLE, albedo_bus).
-define(QUEUES, albedo_bus_queues).
-define(EVENT_LIMIT, 256).
-define(BYTE_LIMIT, 1048576).
-define(CAS_ATTEMPTS, 32).

subscribe(Owner, Notify) ->
    Ref = make_ref(),
    Control = atomics:new(2, [{signed, false}]),
    albedo_registry:register(?QUEUES, Ref, {queue:new(), 0, 0}),
    albedo_registry:register(?TABLE, Ref, {Owner, Notify, Control}),
    spawn(fun() ->
        Monitor = erlang:monitor(process, Owner),
        receive {'DOWN', Monitor, process, Owner, _} ->
            ets:delete(?TABLE, Ref),
            ets:delete(?QUEUES, Ref)
        end
    end),
    Ref.

has_subscribers() ->
    case ets:info(?TABLE, size) of
        Size when is_integer(Size), Size > 0 -> true;
        _ -> false
    end.

publish(Event) ->
    case ets:whereis(?TABLE) of
        undefined -> nil;
        _ ->
            lists:foreach(
                fun({Ref, {_Owner, Notify, Control}}) ->
                    admit(Ref, Event, byte_size(Event), Notify, Control, ?CAS_ATTEMPTS)
                end,
                ets:tab2list(?TABLE)),
            nil
    end.

admit(Ref, Event, Size, Notify, Control, Attempts) ->
    case atomics:get(Control, 1) of
        1 -> ok;
        0 when Attempts == 0 -> overflow(Ref, Notify, Control);
        0 ->
            case ets:lookup(?QUEUES, Ref) of
                [] -> ok;
                [{Ref, {Queue, Count, Bytes} = Previous}] ->
                    case Count + 1 > ?EVENT_LIMIT orelse Bytes + Size > ?BYTE_LIMIT of
                        true ->
                            case replace_queue(Ref, Previous, Previous) of
                                true -> overflow(Ref, Notify, Control);
                                false -> admit(Ref, Event, Size, Notify, Control, Attempts - 1)
                            end;
                        false ->
                            Next = {queue:in(Event, Queue), Count + 1, Bytes + Size},
                            case replace_queue(Ref, Previous, Next) of
                                true -> wake(Notify, Control);
                                false -> admit(Ref, Event, Size, Notify, Control, Attempts - 1)
                            end
                    end
            end
    end.

%% The separate atomic latch makes overload finite even under competing
%% publishers. A stale CAS can only replace an existing row, so deletion
%% prevents an in-progress admission from recreating an overflowed queue.
overflow(Ref, Notify, Control) ->
    case atomics:compare_exchange(Control, 1, 0, 1) of
        ok -> ets:delete(?QUEUES, Ref), wake(Notify, Control);
        _ -> ok
    end.

wake(Notify, Control) ->
    case atomics:compare_exchange(Control, 2, 0, 1) of
        ok -> try Notify() catch _:_ -> ok end;
        _ -> ok
    end.

replace_queue(Ref, Previous, Next) ->
    ets:select_replace(?QUEUES, [
        {{Ref, '$1'}, [{'=:=', '$1', {const, Previous}}], [{const, {Ref, Next}}]}
    ]) == 1.

drain(Ref) ->
    case ets:lookup(?TABLE, Ref) of
        [{Ref, {_Owner, Notify, Control}}] -> drain(Ref, Notify, Control, ?CAS_ATTEMPTS);
        [] -> {batch, []}
    end.

drain(Ref, Notify, Control, Attempts) ->
    case atomics:get(Control, 1) of
        1 -> ets:delete(?QUEUES, Ref), overflow;
        0 when Attempts == 0 -> overflow(Ref, Notify, Control), overflow;
        0 ->
            case ets:lookup(?QUEUES, Ref) of
                [] -> {batch, []};
                [{Ref, {Queue, _Count, _Bytes} = Previous}] ->
                    case replace_queue(Ref, Previous, {queue:new(), 0, 0}) of
                        false -> drain(Ref, Notify, Control, Attempts - 1);
                        true ->
                            case atomics:get(Control, 1) of
                                1 -> ets:delete(?QUEUES, Ref), overflow;
                                0 -> {batch, queue:to_list(Queue)}
                            end
                    end
            end
    end.

%% A periodic flush can overtake the wake already in the stream mailbox.
%% Only consuming that wake permits rearming; otherwise its gate stays set.
rearm(Ref, WakeConsumed) ->
    case ets:lookup(?TABLE, Ref) of
        [{Ref, {_Owner, Notify, Control}}] ->
            case WakeConsumed of
                true -> atomics:put(Control, 2, 0);
                false -> ok
            end,
            case {atomics:get(Control, 1), ets:lookup(?QUEUES, Ref)} of
                {1, _} -> wake(Notify, Control);
                {0, [{Ref, {_Queue, Count, _Bytes}}]} when Count > 0 -> wake(Notify, Control);
                _ -> ok
            end;
        [] -> ok
    end,
    nil.

%% Whether each session is running a turn, as its actor last announced. The
%% registry reads this instead of asking a session, which may be busy.
mark_running(Session, Running) ->
    albedo_registry:register(albedo_running, Session, Running).

running(Session) ->
    case albedo_registry:lookup(albedo_running, Session) of
        {ok, true} -> true;
        _ -> false
    end.

forget(Session) -> albedo_registry:forget(albedo_running, Session).
