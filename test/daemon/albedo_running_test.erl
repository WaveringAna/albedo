%% E2E cannot hold an old owner's cleanup behind a replacement publication.
%% Control owner publications and suspend the real progress monitor to verify
%% reads remain safe even before queued death cleanup runs.
-module(albedo_running_test).
-include_lib("eunit/include/eunit.hrl").

old_owner_cleanup_preserves_replacement_test() ->
    Session = make_ref(),
    {Previous, PreviousWatcher} = owner(Session),
    {Replacement, ReplacementWatcher} = owner(Session),
    try
        Previous ! {idle, self()},
        receive {idle, Previous} -> ok after 5000 -> error(idle_stalled) end,
        ?assertEqual([{Session, Replacement}], ets:lookup(albedo_running, Session)),
        nil = albedo_bus:forget(Session, Previous),
        ?assert(albedo_bus:running(Session)),
        stop(Previous),
        wait_for_exit(PreviousWatcher),
        ?assertEqual([{Session, Replacement}], ets:lookup(albedo_running, Session)),
        ?assertMatch({ok, {Replacement, _}},
            albedo_registry:lookup(albedo_session_progress, Session))
    after
        stop(Previous),
        stop(Replacement),
        wait_for_exit(PreviousWatcher),
        wait_for_exit(ReplacementWatcher)
    end,
    ?assertEqual([], ets:lookup(albedo_running, Session)).

dead_owner_reads_idle_before_monitor_removes_record_test() ->
    Session = make_ref(),
    {Owner, Watcher} = owner(Session),
    true = erlang:suspend_process(Watcher),
    try
        ?assert(albedo_bus:running(Session)),
        stop(Owner),
        ?assertEqual([{Session, Owner}], ets:lookup(albedo_running, Session)),
        ?assertNot(albedo_bus:running(Session))
    after
        erlang:resume_process(Watcher),
        stop(Owner),
        wait_for_exit(Watcher)
    end,
    ?assertEqual([], ets:lookup(albedo_running, Session)),
    ?assertEqual(undefined, albedo_registry:lookup(albedo_session_progress, Session)).

owner(Session) ->
    %% Initialise detached tables before tracing, leaving only the progress
    %% monitor as a spawned child of the registering owner.
    nil = albedo_registry:register(albedo_running, warmup, self()),
    nil = albedo_registry:forget(albedo_running, warmup),
    nil = albedo_registry:register(albedo_session_progress, warmup, self()),
    nil = albedo_registry:forget(albedo_session_progress, warmup),
    Parent = self(),
    Owner = spawn(fun() ->
        receive start -> ok end,
        nil = albedo_bus:register_progress(Session, self(), fun(_) -> nil end),
        nil = albedo_bus:mark_running(Session, true),
        Parent ! {ready, self()},
        owner_loop(Session)
    end),
    erlang:trace(Owner, true, [procs, {tracer, Parent}]),
    Owner ! start,
    Watcher = receive {trace, Owner, spawn, Child, _} -> Child
        after 5000 -> error(progress_monitor_missing) end,
    receive {ready, Owner} -> ok after 5000 -> error(owner_start_stalled) end,
    erlang:trace(Owner, false, [procs]),
    {Owner, Watcher}.

owner_loop(Session) ->
    receive
        {idle, Parent} ->
            nil = albedo_bus:mark_running(Session, false),
            Parent ! {idle, self()},
            owner_loop(Session);
        stop -> ok
    end.

stop(Pid) ->
    Monitor = monitor(process, Pid),
    Pid ! stop,
    receive {'DOWN', Monitor, process, Pid, _} -> ok
    after 5000 -> error({owner_stop_stalled, Pid}) end.

wait_for_exit(Pid) ->
    Monitor = monitor(process, Pid),
    receive {'DOWN', Monitor, process, Pid, _} -> ok
    after 5000 -> error({monitor_cleanup_stalled, Pid}) end.
