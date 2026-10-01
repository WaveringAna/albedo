%% OS process ownership and port multiplexing; application logic stays in Gleam.
%%
%% The kernel runs detached, in its own session, listening on a unix socket in
%% its run directory (priv/python/albedo_link.py). This module talks to it
%% through a bridge process (priv/python/albedo_bridge.py) that copies the same
%% 4-byte-framed messages between the port and that socket, so the bridge can
%% die, here or over ssh, without the kernel or its jobs noticing. Every frame
%% after the attach handshake is wrapped as {seq, ack, frame}: what this side
%% sends is persisted through the Gleam link until the kernel acknowledges it,
%% and a reattach resends the rest; a kernel frame already seen is dropped.
%%
%% The kernel owns the process group of every job it starts. This module records
%% the job groups the kernel reports, so it can still end them when the kernel
%% cannot. Termination is a checked ladder run by a separate helper process
%% (priv/python/albedo_signal.py): it keeps working when the kernel is wedged,
%% and it returns a structured verdict instead of kill(1) exit statuses the
%% supervisor would have to guess at.
-module(albedo_python).
-export([start/1, execute/3, interrupt/1, stop/1, detach/1, events/1, alive/1, os_pid/1, job_count/1, local_paths/0, paths/0, grace/0, rebind/2]).

-define(PROTOCOL, 1).
-define(STARTUP_TIMEOUT, 10000). %% bridge, kernel, and plugins, end to end
-define(SHUTDOWN_GRACE, 2000).   %% must exceed the kernel's own cleanup deadline
-define(HELPER_WAIT, 4000).      %% bounded status wait for one helper process
-define(HELPER_OUTPUT, 65536).   %% bounded verdict size
-define(TERM_MS, 250).
-define(KILL_MS, 1000).
-define(ESCALATE_TERM_MS, 200).  %% a kernel that ignored shutdown gets less patience
-define(ESCALATE_KILL_MS, 500).
-define(ACK_DELAY, 100).         %% a kernel frame is acknowledged within this
-define(GONE, 3).                %% the bridge's exit status when no kernel is there
-define(REATTACH_MAX_MS, 2000).
-define(REATTACH_TRIES, 40).     %% consecutive failed attaches before giving up

%% Boot is the Gleam kernel.Boot record; Link is kernel.Link.
start({boot, Owner, Python, Bridge, Cwd, Host, Modules, Link, RunDir, Kernel, Token, Grace, OutSeq, Fresh}) ->
    Parent = self(), Ref = make_ref(),
    {Pid, Mon} = spawn_monitor(fun() ->
        process_flag(trap_exit, true),
        monitor(process, Owner),
        Pool = albedo_job_slots:ensure(),
        monitor(process, Pool),
        S = #{port => none, host => Host, link => Link, owner => Owner, active => none, events => [],
              groups => #{}, external => 0, pool => Pool, slots => #{}, target => none,
              python => Python, bridge => Bridge, cwd => Cwd,
              modules => Modules, run_dir => RunDir, kernel => Kernel, token => Token,
              grace => Grace, in => 0, acked => 0, kack => 0, out => OutSeq,
              calls => #{}, bundle => none, retries => 0, flush => none},
        Mode = case Fresh of true -> start; false -> attach end,
        case open_bridge(S, Mode) of
            {ok, S1} -> startup(S1, Mode, Parent, Ref, erlang:monotonic_time(millisecond) + ?STARTUP_TIMEOUT);
            {error, Reason} -> Parent ! {Ref, {error, {unavailable, detail(Reason)}}}
        end
    end),
    receive
        {Ref, Result} -> demonitor(Mon, [flush]), Result;
        {'DOWN', Mon, process, Pid, _} -> {error, lost}
    end.

%% A bridge that starts the kernel, or one that attaches to the running one.
%% The attach frame goes first either way: the token, what we have seen, and
%% how long the kernel may outlive a dropped connection.
open_bridge(S = #{python := Python, bridge := Bridge, run_dir := RunDir}, Mode) ->
    {Args, Cd} = case Mode of
        start -> {[<<"start">>, RunDir, maps:get(modules, S)], maps:get(cwd, S)};
        attach -> {[<<"attach">>, RunDir], <<"/">>}
    end,
    try open_port({spawn_executable, binary_to_list(Python)},
            [binary, {packet, 4}, use_stdio, exit_status, hide,
             {args, ["-u", binary_to_list(Bridge) | [binary_to_list(A) || A <- Args]]},
             {cd, binary_to_list(Cd)},
             {env, [{"ALBEDO_JOB_ADMISSION", "1"} | lists:keydelete("ALBEDO_JOB_ADMISSION", 1, clean_environment())]}]) of
        Port ->
            Attach = #{attach => #{kernel => maps:get(kernel, S), token => maps:get(token, S),
                                   ack => maps:get(in, S), grace => maps:get(grace, S)}},
            _ = try port_command(Port, json:encode(Attach)) catch _:_ -> ok end,
            {ok, S#{port => Port, acked => maps:get(in, S)}}
    catch _:Reason -> {error, Reason}
    end.

%% Plugin setup can call the host or start a job before the ready handshake.
%% Keep admission and ownership responsive through the same absolute boot deadline.
startup(S = #{port := Port}, Mode, Parent, Ref, Deadline) ->
    After = max(1, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {Port, {data, Data}} when byte_size(Data) =< 8388608 ->
            case wire(Data, S) of
                {frame, #{<<"type">> := <<"ready">>} = Ready, S1} ->
                    started(S1#{target => target_of(Ready)}, Parent, Ref);
                {frame, #{<<"type">> := <<"startup_error">>, <<"message">> := Message}, S1} when is_binary(Message) ->
                    startup_fail(S1, Parent, Ref, {unavailable, Message});
                {frame, Frame, S1} -> startup(handle_frame(Frame, S1), Mode, Parent, Ref, Deadline);
                {hello, Hello, S1} ->
                    S2 = hello(Hello, S1),
                    case maps:get(<<"ready">>, Hello, false) of
                        true when Mode =:= attach -> started(S2, Parent, Ref);
                        _ -> startup(S2, Mode, Parent, Ref, Deadline)
                    end;
                {refused, _, S1} -> startup_fail(S1, Parent, Ref, lost);
                {skip, S1} -> startup(S1, Mode, Parent, Ref, Deadline);
                invalid -> startup_fail(S, Parent, Ref, {unavailable, <<"invalid kernel handshake">>})
            end;
        {host_reply, Id, Reply} -> startup(host_reply(Id, Reply, S), Mode, Parent, Ref, Deadline);
        {job_slot, Id, Result} -> startup(slot_reply(Id, Result, S), Mode, Parent, Ref, Deadline);
        flush_ack -> startup(flush_ack(S), Mode, Parent, Ref, Deadline);
        {Port, {data, _}} -> startup_fail(S, Parent, Ref, {unavailable, <<"invalid kernel handshake">>});
        {Port, {exit_status, ?GONE}} when Mode =:= attach -> startup_fail(S#{port => none}, Parent, Ref, lost);
        {Port, {exit_status, _}} -> startup_fail(S#{port => none}, Parent, Ref, {unavailable, <<"python exited at startup">>});
        {'DOWN', _, process, _, _} -> startup_fail(S, Parent, Ref, lost)
    after After -> startup_fail(S, Parent, Ref, {unavailable, <<"python startup timed out">>})
    end.

started(S, Parent, Ref) ->
    Parent ! {Ref, {ok, self()}},
    loop(S).

startup_fail(S, Parent, Ref, Error) ->
    reap_start(S), Parent ! {Ref, {error, Error}}.

execute(Pid, Data, Timeout) -> call(Pid, {execute, Data, Timeout}).

%% Background jobs whose groups are still owned: local job groups plus the
%% remote jobs the remote plugin reported through "jobs" frames. A released
%% kernel would kill them, so the idle sweep keeps such kernels alive.
job_count(Pid) ->
    case call(Pid, job_count) of
        {ok, Count} when is_integer(Count), Count >= 0 -> Count;
        _ -> 0
    end.
events(Pid) -> case call(Pid, events) of {ok, Events} -> Events; _ -> [] end.
interrupt(Pid) -> Pid ! interrupt, nil.

%% Typed for the caller: ok when every group is verifiably gone, otherwise the
%% groups that survived, so a reset can report what it could not end.
stop(Pid) ->
    case call(Pid, stop) of
        ok -> {ok, nil};
        {error, Report} when is_binary(Report) -> {error, Report};
        {error, lost} -> {error, <<"kernel lost before its processes could be supervised">>};
        Other -> {error, detail(Other)}
    end.

%% Let go of the kernel without ending it: the bridge closes, the kernel keeps
%% its namespace and jobs, and a later start in attach mode picks it up again.
detach(Pid) -> _ = call(Pid, detach), nil.

alive(Pid) -> is_process_alive(Pid).

%% The kernel's own process id, as it declared it at the handshake.
os_pid(Pid) ->
    case call(Pid, os_pid) of
        {ok, OsPid} when is_integer(OsPid), OsPid > 1 -> {ok, OsPid};
        _ -> {error, nil}
    end.

call(Pid, Request) ->
    Mon = monitor(process, Pid),
    Pid ! {call, self(), Mon, Request},
    receive
        {Mon, Result} -> demonitor(Mon, [flush]), Result;
        {'DOWN', Mon, process, Pid, _} -> {error, lost}
    end.

%% Swap the live host RPC closure: a refreshed extension snapshot rebinds the
%% routes Python reaches without restarting the kernel. A host call already in
%% flight finishes on the closure it captured; the swap lands between calls.
rebind(Pid, Host) when is_function(Host, 1) -> call(Pid, {rebind, Host}).

loop(S = #{port := Port, active := Active}) ->
    receive
        {call, From, Ref, {execute, Data, Timeout}} when Active =:= none ->
            Timer = erlang:send_after(Timeout, self(), {deadline, Ref}),
            Caller = monitor(process, From),
            Id = maps:get(<<"id">>, json:decode(Data)),
            loop((send_encoded(Data, S))#{active => {From, Ref, Timer, Caller, Id}});
        {call, From, Ref, {execute, _, _}} ->
            From ! {Ref, {error, busy}}, loop(S);
        {call, From, Ref, os_pid} ->
            Reply = case S of
                #{target := #{pid := KernelPid}} -> {ok, KernelPid};
                _ -> {error, nil}
            end,
            From ! {Ref, Reply}, loop(S);
        {call, From, Ref, job_count} ->
            Count = maps:size(maps:merge(maps:get(groups, S), maps:get(slots, S))) + maps:get(external, S, 0),
            From ! {Ref, {ok, Count}}, loop(S);
        {call, From, Ref, {rebind, Host}} when is_function(Host, 1) ->
            From ! {Ref, {ok, nil}}, loop(S#{host => Host});
        {call, From, Ref, events} ->
            From ! {Ref, {ok, lists:reverse(maps:get(events, S))}}, loop(S#{events => []});
        {call, From, Ref, stop} ->
            From ! {Ref, shutdown(S, ?TERM_MS, ?KILL_MS)},
            nil;
        {call, From, Ref, detach} ->
            close_port(Port),
            From ! {Ref, ok},
            nil;
        interrupt -> loop(interrupt_active(S, <<"cancelled">>));
        {deadline, Ref} ->
            case Active of
                {_, Ref, _, _, _} when Port =:= none ->
                    %% Nobody can hear the cell right now. It keeps running; the
                    %% interrupt waits in the outbox and its result is journaled
                    %% when it arrives.
                    loop(answer_detached(interrupt_active(S, <<"deadline">>)));
                {_, Ref, _, _, _} -> loop(interrupt_active(S, <<"deadline">>));
                _ -> loop(S)
            end;
        {kill, Ref} ->
            case Active of
                {_, Ref, _, _, _} when Port =:= none -> loop(answer_detached(S));
                {From, Ref, _, Caller, _} ->
                    %% A forced stop loses the execution; its groups are supervised
                    %% before the caller is answered, so the kernel is gone by then.
                    demonitor(Caller, [flush]),
                    report(escalated, shutdown(S, ?ESCALATE_TERM_MS, ?ESCALATE_KILL_MS)),
                    From ! {Ref, {error, lost}};
                _ -> loop(S)
            end;
        {Port, {data, Data}} when Port =/= none, byte_size(Data) =< 8388608 ->
            case wire(Data, S) of
                {frame, Frame, S1} -> loop(handle_frame(Frame, S1));
                {hello, Hello, S1} -> loop(hello(Hello, S1));
                {refused, Reason, S1} -> log({kernel_refused_attach, Reason}), abandon(S1);
                {skip, S1} -> loop(S1);
                invalid -> abandon(S)
            end;
        {Port, {data, _}} when Port =/= none -> abandon(S);
        {Port, {exit_status, Status}} when Port =/= none -> bridge_lost(S, Status);
        reattach when Port =:= none -> reattach(S);
        flush_ack -> loop(flush_ack(S));
        {host_reply, Id, Reply} -> loop(host_reply(Id, Reply, S));
        {job_slot, Id, Result} -> loop(slot_reply(Id, Result, S));
        {'DOWN', Caller, process, _, _} ->
            case Active of
                {_, _, _, Caller, _} -> loop(interrupt_active(S, <<"cancelled">>));
                _ -> abandon(S)
            end;
        _ -> loop(S)
    end.

%% The bridge went away. Status 3 says the kernel is gone too; anything else
%% is a dropped connection, and the kernel is attached again.
bridge_lost(S, ?GONE) -> abandon(S#{port => none, exited => true});
bridge_lost(S, _) ->
    erlang:send_after(backoff(S), self(), reattach),
    loop(S#{port => none}).

backoff(#{retries := Tries}) -> min(?REATTACH_MAX_MS, 50 bsl min(Tries, 10)).

reattach(S = #{retries := Tries}) when Tries >= ?REATTACH_TRIES ->
    log({kernel_unreachable, maps:get(kernel, S)}),
    abandon(S);
reattach(S = #{retries := Tries}) ->
    case open_bridge(S, attach) of
        {ok, S1} -> loop(S1#{retries => Tries + 1});
        {error, Reason} ->
            log({bridge_failed, detail(Reason)}),
            S1 = S#{retries => Tries + 1},
            erlang:send_after(backoff(S1), self(), reattach),
            loop(S1)
    end.

%% One message from the bridge, decoded and unwrapped.
wire(Data, S) ->
    case try json:decode(Data) catch _:_ -> invalid end of
        #{<<"seq">> := Seq, <<"frame">> := Frame} = Envelope when is_integer(Seq), is_map(Frame) ->
            S1 = acknowledged(Envelope, S),
            case Seq > maps:get(in, S1) of
                true -> {frame, Frame, schedule_ack(S1#{in => Seq})};
                false -> {skip, schedule_ack(S1)}
            end;
        #{<<"ack">> := _} = Envelope -> {skip, acknowledged(Envelope, S)};
        #{<<"hello">> := Hello} when is_map(Hello) -> {hello, Hello, S};
        #{<<"bridge">> := #{<<"bundle">> := Bundle}} -> {skip, S#{bundle => Bundle}};
        #{<<"refused">> := Reason} -> {refused, Reason, S};
        _ -> invalid
    end.

%% The kernel has everything up to Ack: drop it from the durable outbox.
acknowledged(#{<<"ack">> := Ack}, S = #{kack := Seen}) when is_integer(Ack), Ack > Seen ->
    link_ack(S, Ack),
    S#{kack => Ack};
acknowledged(_, S) -> S.

schedule_ack(S = #{flush := none}) ->
    S#{flush => erlang:send_after(?ACK_DELAY, self(), flush_ack)};
schedule_ack(S) -> S.

flush_ack(S = #{in := In, acked := Acked}) when In > Acked ->
    write(S, json:encode(#{ack => In})),
    S#{acked => In, flush => none};
flush_ack(S) -> S#{flush => none}.

%% A (re)attach answered: drop what the kernel already has, resend the rest,
%% and take its word for its identity and the jobs it still owns.
hello(Hello, S0) ->
    S = acknowledged(Hello, S0#{retries => 0}),
    Ack = maps:get(kack, S),
    [write_envelope(S, Seq, Frame) || {Seq, Frame} <- link_pending(S), Seq > Ack],
    case {maps:get(bundle, S), maps:get(<<"bundle">>, Hello, none)} of
        {Same, Same} -> ok;
        {Ours, Theirs} -> log({kernel_bundle_skew, maps:get(kernel, S), Ours, Theirs})
    end,
    case maps:get(<<"protocol">>, Hello, none) of
        ?PROTOCOL -> ok;
        Other -> log({kernel_protocol_skew, maps:get(kernel, S), Other})
    end,
    Target = target_of(Hello),
    link_record(S, #{pid => maps:get(pid, Target), pgid => maps:get(pgid, Target),
                     leader => maps:get(leader, Target), epoch => maps:get(<<"epoch">>, Hello, 0)}),
    Jobs = [Job || Job <- maps:get(<<"jobs">>, Hello, []), is_map(Job)],
    S1 = lists:foldl(fun track/2, S#{target => Target}, Jobs),
    S2 = case maps:get(<<"external">>, Hello, 0) of
        Live when is_integer(Live), Live >= 0 -> S1#{external => Live};
        _ -> S1
    end,
    Waiting = [Id || Id <- maps:get(<<"slots">>, Hello, []), is_binary(Id),
                     not maps:is_key(Id, maps:get(slots, S2))],
    lists:foldl(fun acquire_slot/2, S2, Waiting).

handle_frame(#{<<"type">> := <<"done">>, <<"id">> := Id} = Done, S = #{active := {From, Ref, Timer, Caller, Id}}) ->
    erlang:cancel_timer(Timer), demonitor(Caller, [flush]),
    From ! {Ref, {ok, iolist_to_binary(json:encode(Done))}},
    S#{active => none};
handle_frame(#{<<"type">> := <<"done">>, <<"id">> := Id} = Done, S = #{host := Host})
        when Id =/= <<"snapshot">>, Id =/= <<"restore">> ->
    %% A result nobody waits for any more: the caller gave up while the kernel
    %% was out of reach. Journal it, so the retained cell shows what happened.
    spawn(fun() ->
        host_call(Host, #{type => <<"call">>, id => Id, method => <<"cells.finish">>,
                          args => #{id => Id, outcome => Done}})
    end),
    S;
handle_frame(#{<<"type">> := <<"call">>, <<"id">> := Id} = Message, S = #{host := Host, calls := Calls}) ->
    case maps:is_key(Id, Calls) orelse link_call(S, Id) of
        %% Already running here: its reply reaches the kernel through the outbox.
        true -> S;
        answered -> S;
        unknown ->
            host_reply(Id, #{ok => false, code => <<"unknown">>,
                             message => <<"albedo restarted while this call ran; its outcome is unknown">>}, S);
        fresh ->
            Parent = self(),
            %% Work requests never block interrupt/timeout handling of the kernel.
            spawn(fun() -> Parent ! {host_reply, Id, host_call(Host, Message)} end),
            S#{calls => Calls#{Id => true}}
    end;
handle_frame(#{<<"type">> := <<"job_acquire">>, <<"id">> := Id}, S) when is_binary(Id) ->
    acquire_slot(Id, S);
handle_frame(#{<<"type">> := <<"job">>} = Message, S) ->
    journal(Message, track(Message, S));
handle_frame(#{<<"type">> := <<"jobs">>, <<"live">> := Live}, S)
        when is_integer(Live), Live >= 0 ->
    S#{external => Live};
handle_frame(#{<<"type">> := <<"trace">>} = Message, S) ->
    journal(Message, S);
handle_frame(Message, S) -> track(Message, S).

host_reply(Id, Reply, S = #{calls := Calls, out := Out}) ->
    Seq = Out + 1,
    Frame = iolist_to_binary(json:encode(#{type => <<"reply">>, id => Id, value => Reply})),
    link_reply(S, Id, Seq, Frame),
    write_envelope(S, Seq, Frame),
    S#{calls => maps:remove(Id, Calls), out => Seq, acked => maps:get(in, S)}.

acquire_slot(Id, S = #{pool := Pool, slots := Slots}) ->
    albedo_job_slots:acquire(Pool, Id),
    S#{slots => Slots#{Id => true}}.

slot_reply(Id, Result, S = #{slots := Slots}) ->
    case maps:is_key(Id, Slots) of
        false -> S;  %% cancelled before the grant reached us
        true ->
            Reply = case Result of
                        ok -> #{ok => true};
                        %% No slot yet: the kernel pauses the job until one frees.
                        queued -> #{ok => false, queued => true};
                        {error, Why} -> #{ok => false, message => Why}
                    end,
            S1 = send(Reply#{type => <<"job_slot">>, id => Id}, S),
            case Result of {error, _} -> release_slot(Id, S1); _ -> S1 end
    end.

release_slot(Id, S = #{pool := Pool, slots := Slots}) ->
    albedo_job_slots:release(Pool, Id),
    S#{slots => maps:remove(Id, Slots)}.

%% One host call's decoded reply, with the fixed fallback when the host itself
%% fails to answer.
host_call(Host, Message) ->
    try json:decode(Host(iolist_to_binary(json:encode(Message))))
    catch _:_ -> #{ok => false, code => <<"unavailable">>, message => <<"runtime unavailable">>} end.

%% Job ownership bookkeeping shared by the main loop and the startup and
%% shutdown drains: a started job's group is recorded; a job proven gone
%% releases its slot and its group.
start_job(Message, Id, S = #{groups := Groups}) ->
    S#{groups => Groups#{Id => group_of(Message)}}.

gone(Id, S = #{groups := Groups}) ->
    (release_slot(Id, S))#{groups => maps:remove(Id, Groups)}.

%% The newest 100 job and trace frames, what events/1 hands out.
journal(Message, S = #{events := Events}) ->
    S#{events => lists:sublist([iolist_to_binary(json:encode(Message)) | Events], 100)}.

%% Sequence, persist, and (when attached) write one frame to the kernel.
send(Message, S) -> send_encoded(iolist_to_binary(json:encode(Message)), S).

send_encoded(Frame, S = #{out := Out}) ->
    Seq = Out + 1,
    link_persist(S, Seq, Frame),
    write_envelope(S, Seq, Frame),
    S#{out => Seq, acked => maps:get(in, S)}.

write_envelope(S = #{in := In}, Seq, Frame) ->
    write(S, [<<"{\"seq\":">>, integer_to_binary(Seq), <<",\"ack\":">>, integer_to_binary(In),
              <<",\"frame\":">>, Frame, <<"}">>]).

write(#{port := none}, _) -> ok;
write(#{port := Port}, Data) -> _ = try port_command(Port, Data) catch _:_ -> ok end, ok.

interrupt_active(S = #{active := none}, _) -> S;
interrupt_active(S = #{active := {_, Ref, _, _, Id}}, Reason) ->
    erlang:send_after(2000, self(), {kill, Ref}),
    send(#{type => <<"interrupt">>, id => Id, reason => Reason}, S).

answer_detached(S = #{active := {From, Ref, Timer, Caller, _}}) ->
    erlang:cancel_timer(Timer), demonitor(Caller, [flush]),
    From ! {Ref, {error, detached}},
    S#{active => none};
answer_detached(S) -> S.

%% The Gleam link: the durable outbox and host-call ledger. A storage failure
%% is logged and never stops the kernel; the frame still goes out. Once the
%% store is gone (its owner died) there is nothing left to record.
link_persist(S = #{link := {link, Persist, _, _, _, _, _, _}}, Seq, Frame) -> guarded(S, fun() -> Persist(Seq, Frame) end).
link_ack(S = #{link := {link, _, Ack, _, _, _, _, _}}, Upto) -> guarded(S, fun() -> Ack(Upto) end).
link_pending(S = #{link := {link, _, _, Pending, _, _, _, _}}) ->
    case guarded(S, Pending) of Frames when is_list(Frames) -> Frames; _ -> [] end.
link_call(S = #{link := {link, _, _, _, Call, _, _, _}}, Id) ->
    case guarded(S, fun() -> Call(Id) end) of
        State when State =:= fresh; State =:= answered; State =:= unknown -> State;
        _ -> fresh
    end.
link_reply(S = #{link := {link, _, _, _, _, Reply, _, _}}, Id, Seq, Frame) -> guarded(S, fun() -> Reply(Id, Seq, Frame) end).
link_record(S = #{link := {link, _, _, _, _, _, Record, _}}, Fields) ->
    guarded(S, fun() -> Record(iolist_to_binary(json:encode(maps:filter(fun(_, V) -> V =/= nil end, Fields)))) end).
link_forget(S = #{link := {link, _, _, _, _, _, _, Forget}}) -> guarded(S, Forget).

guarded(#{owner := Owner}, Fun) ->
    case is_process_alive(Owner) of
        false -> error;
        true -> try Fun() catch Class:Reason -> log({kernel_link, Class, Reason}), error end
    end.

%% Ask the kernel to clean up, wait, then end whatever it left behind. The job
%% groups live in their own sessions, so the kernel's death never reaps them.
shutdown(S = #{target := Target}, TermMs, KillMs) ->
    S1 = case S of
        #{port := none} -> S;
        _ -> send(#{type => <<"shutdown">>}, S)
    end,
    Settled = case maps:get(exited, S1, false) orelse maps:get(port, S1) =:= none of
        true -> S1;
        false -> await_exit(S1, erlang:monotonic_time(millisecond) + ?SHUTDOWN_GRACE)
    end,
    %% The leader exiting does not prove its group empty: plain subprocesses
    %% from a cell inherit the kernel group and can outlive it.
    Kernel = case Target of none -> []; _ -> [target_spec(<<"kernel">>, Target)] end,
    Targets = Kernel ++ job_specs(maps:get(groups, Settled)),
    reap_finish(Settled, verdict(supervise(Targets, TermMs, KillMs))).

abandon(S) -> report(owner_lost, shutdown(S, ?TERM_MS, ?KILL_MS)).

%% Keep accepting ownership transfers while shutdown is in flight. A job may
%% finish spawning after the shutdown request was sent.
await_exit(S = #{port := Port}, Deadline) ->
    Now = erlang:monotonic_time(millisecond),
    case Now >= Deadline of
        true -> S;
        false ->
            receive
                {Port, {exit_status, _}} -> S#{port => none};
                {Port, {data, Data}} ->
                    case wire(Data, S) of
                        {frame, Frame, S1} -> await_exit(track(Frame, S1), Deadline);
                        {_, _, S1} -> await_exit(S1, Deadline);
                        {skip, S1} -> await_exit(S1, Deadline);
                        invalid -> await_exit(S, Deadline)
                    end
            after min(50, Deadline - Now) -> await_exit(S, Deadline)
            end
    end.

track(#{<<"type">> := <<"job_start">>, <<"id">> := Id, <<"pgid">> := Pgid} = Message, S)
        when is_integer(Pgid), Pgid > 1 ->
    start_job(Message, Id, S);
track(#{<<"type">> := <<"job">>, <<"id">> := Id} = Message, S) ->
    %% A job keeps its entry while its group survives, so cleanup failures stay owned.
    case maps:get(<<"cleanup">>, Message, none) of
        #{<<"gone">> := true} -> gone(Id, S);
        none -> S;   %% unverified: keep owning the group
        Cleanup -> log({job_cleanup_failed, Id, Cleanup}), S
    end;
track(#{<<"type">> := <<"job_cancel">>, <<"id">> := Id}, S) -> release_slot(Id, S);
track(#{<<"type">> := <<"cleanup">>, <<"failures">> := Failures}, S) ->
    log({kernel_cleanup_failed, Failures}), S;
track(_, S) -> S.

%% One checked helper process ends every target and returns its verdicts.
supervise(Targets, TermMs, KillMs) ->
    Request = binary_to_list(iolist_to_binary(json:encode(#{targets => Targets, term_ms => TermMs, kill_ms => KillMs}))),
    case local_paths() of
        {ok, {Python, Script}} ->
            Helper = filename:join(filename:dirname(binary_to_list(Script)), "albedo_signal.py"),
            run_helper(binary_to_list(Python), Helper, Request);
        {error, Reason} -> {error, detail(Reason)}
    end.

run_helper(Python, Helper, Request) ->
    try open_port({spawn_executable, Python},
                  [binary, exit_status, use_stdio,
                   {args, ["-u", Helper, Request]}, {env, clean_environment()}]) of
        Port -> collect(Port, <<>>, erlang:monotonic_time(millisecond) + ?HELPER_WAIT)
    catch _:Reason -> {error, detail(Reason)}
    end.

%% The helper has its own OS alarm (< HELPER_WAIT). Drain to exit_status even
%% on output overflow; closing a port alone is not proof its child exited.
collect(Port, Buffer, Deadline) ->
    Now = erlang:monotonic_time(millisecond),
    if
        Now >= Deadline -> close_port(Port), {error, <<"termination helper timed out">>};
        true ->
            receive
                {Port, {data, Data}} when is_binary(Buffer), byte_size(Buffer) + byte_size(Data) =< ?HELPER_OUTPUT ->
                    collect(Port, <<Buffer/binary, Data/binary>>, Deadline);
                {Port, {data, _}} -> collect(Port, overflow, Deadline);
                {Port, {exit_status, 0}} when is_binary(Buffer) -> decode_verdict(Buffer);
                {Port, {exit_status, 0}} -> {error, <<"termination helper output exceeded">>};
                {Port, {exit_status, Status}} -> {error, detail({helper_exit, Status, Buffer})};
                {'EXIT', Port, _} -> {error, <<"termination helper port exited">>}
            after 50 -> collect(Port, Buffer, Deadline)
            end
    end.

decode_verdict(Buffer) ->
    try json:decode(Buffer) of
        #{<<"ok">> := true, <<"targets">> := Targets} when is_list(Targets) -> {ok, Targets};
        #{<<"ok">> := false, <<"error">> := Error} -> {error, Error};
        _ -> {error, <<"termination helper returned no verdict">>}
    catch _:Reason -> {error, detail({bad_verdict, Reason, Buffer})}
    end.

verdict({ok, Verdicts}) -> verdict(Verdicts);
verdict({error, Reason}) when is_binary(Reason) -> {error, Reason};
verdict({error, Reason}) -> {error, detail(Reason)};
verdict(Verdicts) when is_list(Verdicts) ->
    case [V || V <- Verdicts, maps:get(<<"gone">>, V, false) =:= false] of
        [] -> ok;
        Survived -> {error, iolist_to_binary(lists:join("; ", [describe(V) || V <- Survived]))}
    end.

describe(V) ->
    io_lib:format("~ts: process group ~p survived ~ts~ts~ts",
        [maps:get(<<"label">>, V, <<"target">>), maps:get(<<"pgid">>, V, nil),
         lists:join("+", maps:get(<<"signals">>, V, [])),
         detail_text(maps:get(<<"failures">>, V, [])), detail_text(maps:get(<<"note">>, V, <<>>))]).

detail_text([]) -> "";
detail_text(<<>>) -> "";
detail_text(Detail) when is_list(Detail) -> io_lib:format(" (~ts)", [lists:join("; ", Detail)]);
detail_text(Detail) -> io_lib:format(" (~ts)", [Detail]).

%% Identity the kernel declared for itself; a port's os_pid is trustworthy only
%% while that port is alive.
target_of(M) -> proc_spec(maps:get(<<"pid">>, M, nil), M).
group_of(M)  -> proc_spec(maps:get(<<"pgid">>, M, nil), M).
proc_spec(Pid, M) ->
    #{pid => Pid, pgid => maps:get(<<"pgid">>, M, nil), leader => maps:get(<<"leader">>, M, nil)}.

target_spec(Label, #{pid := Pid, pgid := Pgid, leader := Leader}) ->
    Base = #{label => iolist_to_binary(Label), pid => Pid, pgid => Pgid},
    %% json:encode(nil) is the string "nil", which the helper would mistake for
    %% a process identity and reject even while an untagged group is alive.
    case Leader of nil -> Base; _ -> Base#{leader => Leader} end.

job_specs(Groups) ->
    [target_spec(<<"job ", Id/binary>>, Spec) || Id := Spec <- Groups].

%% A boot that failed before the kernel declared itself ends the bridge and
%% removes the run directory, which a kernel that did start notices and
%% leaves; one that did declare itself is supervised like any shutdown.
reap_start(S = #{port := Port}) ->
    Bridge = case Port =/= none andalso erlang:port_info(Port, os_pid) of
                 {os_pid, OsPid} when is_integer(OsPid), OsPid > 1 ->
                     [#{label => <<"bridge">>, pid => OsPid}];
                 _ -> []
             end,
    Kernel = case maps:get(target, S) of none -> []; Target -> [target_spec(<<"kernel">>, Target)] end,
    Result = verdict(supervise(Bridge ++ Kernel ++ job_specs(maps:get(groups, S)), ?TERM_MS, ?KILL_MS)),
    report(startup_reaped, reap_finish(S, Result)).

%% The kernel is gone for good: its durable link and run directory go too.
reap_finish(S = #{pool := Pool, port := Port}, Result) ->
    close_port(Port),
    link_forget(S),
    _ = file:del_dir_r(maps:get(run_dir, S)),
    case Result of ok -> albedo_job_slots:release_owner(Pool); _ -> ok end,
    Result.

close_port(none) -> ok;
close_port(Port) -> _ = try port_close(Port) catch _:_ -> ok end, ok.

%% A failure with no caller to answer goes to the log; a clean outcome is silent.
report(_Event, ok) -> ok;
report(Event, {ok, Verdicts}) -> report(Event, verdict(Verdicts));
report(Event, {error, Reason}) -> log({Event, Reason});
report(Event, Outcome) -> log({Event, Outcome}).

log(Event) -> _ = try logger:error("albedo_python: ~0p", [Event]) catch _:_ -> ok end, ok.

detail(Reason) -> unicode:characters_to_binary(io_lib:format("~p", [Reason])).

local_paths() ->
    case os:find_executable("python3") of
        false -> {error, {unavailable, <<"python3 not found on PATH">>}};
        Python -> {ok, {unicode:characters_to_binary(Python),
            unicode:characters_to_binary(filename:absname(filename:join([code:priv_dir(albedo), "python", "albedo_kernel.py"])))}}
    end.

%% Python and the bridge beside the packaged kernel script.
paths() ->
    case local_paths() of
        {ok, {Python, Script}} ->
            {ok, {Python, filename:join(filename:dirname(Script), <<"albedo_bridge.py">>)}};
        Error -> Error
    end.

-define(GRACE_SECONDS, 3600).

grace() ->
    case string:to_integer(os:getenv("ALBEDO_KERNEL_GRACE_SECONDS", "")) of
        {Seconds, []} when Seconds >= 0 -> Seconds;
        _ -> ?GRACE_SECONDS
    end.

%% Model tools must not inherit provider credentials or the daemon's client token.
clean_environment() ->
    %% Strip daemon internal tokens (e.g. ALBEDO_TOKEN, ALBEDO_API_KEY) and
    %% provider keys, keeping the user's shell/tool environment intact.
    SafeAlbedo = ["ALBEDO_HOME", "ALBEDO_SSH", "ALBEDO_JOB_GRACE_SECONDS", "ALBEDO_JOB_ADMISSION"],
    SecretSuffixes = ["_API_KEY", "_TOKEN"],
    IsBlocked = fun(Name) ->
        case lists:prefix("ALBEDO_", Name) of
            true -> not lists:member(Name, SafeAlbedo);
            false -> lists:any(fun(Suffix) -> lists:suffix(Suffix, Name) end, SecretSuffixes)
        end
    end,
    [{Name, false} || Entry <- os:getenv(), Name <- [hd(string:split(Entry, "="))], IsBlocked(Name)].
