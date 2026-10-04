%% Concurrent startup and detached ETS lifetime cannot be controlled through
%% the model-turn E2E API. Trace creators to catch idle losing owner processes.
-module(albedo_registry_test).
-include_lib("eunit/include/eunit.hrl").

concurrent_registration_test() ->
    Table = albedo_registry_concurrency_test,
    Parent = self(),
    Workers = [spawn_monitor(fun() ->
        receive start -> ok end,
        nil = albedo_registry:register(Table, Id, Id),
        Parent ! {registered, Id}
    end) || Id <- lists:seq(1, 64)],
    try
        [erlang:trace(Pid, true, [procs, set_on_spawn, {tracer, Parent}]) || {Pid, _} <- Workers],
        [Pid ! start || {Pid, _} <- Workers],
        [receive {registered, Id} -> ok after 5000 -> error({registration_stalled, Id}) end
         || Id <- lists:seq(1, 64)],
        [receive {'DOWN', Ref, process, Pid, normal} -> ok
         after 5000 -> error({worker_stalled, Pid}) end || {Pid, Ref} <- Workers],
        Owner = ets:info(Table, owner),
        ?assert(is_process_alive(Owner)),
        [ ?assertEqual({ok, Id}, albedo_registry:lookup(Table, Id)) || Id <- lists:seq(1, 64)],
        Delivered = erlang:trace_delivered(all),
        Creators = creators(Delivered, []),
        ?assert(lists:member(Owner, Creators)),
        [wait_for_exit(Pid) || Pid <- Creators, Pid =/= Owner],
        %% Reuse is independent of the original registering processes.
        nil = albedo_registry:register(Table, reused, value),
        ?assertEqual(Owner, ets:info(Table, owner)),
        ?assertEqual({ok, value}, albedo_registry:lookup(Table, reused))
    after
        [exit(Pid, kill) || {Pid, _} <- Workers, is_process_alive(Pid)],
        case ets:info(Table, owner) of
            undefined -> ok;
            OwnerToStop ->
                RefToStop = monitor(process, OwnerToStop),
                OwnerToStop ! stop,
                receive {'DOWN', RefToStop, process, OwnerToStop, _} -> ok
                after 5000 -> error(owner_stop_stalled) end
        end
    end.

creators(Delivered, Acc) ->
    receive
        {trace, _, spawn, Child, _} -> creators(Delivered, [Child | Acc]);
        {trace, _, _, _} -> creators(Delivered, Acc);
        {trace_delivered, all, Delivered} -> Acc
    after 5000 -> error(trace_delivery_stalled)
    end.

wait_for_exit(Pid) ->
    Ref = monitor(process, Pid),
    receive {'DOWN', Ref, process, Pid, _} -> ok
    after 5000 -> error({losing_creator_alive, Pid}) end.
