%% OS process ownership and port multiplexing; application logic stays in Gleam.
%%
%% The kernel owns the process group of every job it starts. This module owns
%% the kernel process and records the job groups the kernel reports, so it can
%% still end them when the kernel cannot. Termination is a checked ladder run by
%% a separate helper process (priv/python/albedo_signal.py): it keeps working when
%% the kernel is wedged, and it returns a structured verdict instead of
%% kill(1) exit statuses the supervisor would have to guess at.
-module(albedo_python).
-export([start/6, execute/3, interrupt/1, stop/1, events/1, alive/1, os_pid/1, job_count/1, local_paths/0]).

-define(STARTUP_TIMEOUT, 5000).
-define(SHUTDOWN_GRACE, 2000).   %% must exceed the kernel's own cleanup deadline
-define(HELPER_WAIT, 4000).      %% bounded status wait for one helper process
-define(HELPER_OUTPUT, 65536).   %% bounded verdict size
-define(TERM_MS, 250).
-define(KILL_MS, 1000).
-define(ESCALATE_TERM_MS, 200).  %% a kernel that ignored shutdown gets less patience
-define(ESCALATE_KILL_MS, 500).

start(Owner, Python, Script, Cwd, Host, Modules) ->
    Parent = self(), Ref = make_ref(),
    {Pid, Mon} = spawn_monitor(fun() ->
        process_flag(trap_exit, true),
        monitor(process, Owner),
        try open_port({spawn_executable, binary_to_list(Python)},
                [binary, {packet, 4}, use_stdio, exit_status, hide,
                 {args, ["-u", binary_to_list(Script), binary_to_list(iolist_to_binary(json:encode(Modules)))]}, {cd, binary_to_list(Cwd)}, {env, clean_environment()}]) of
            Port -> startup(Port, Host, Parent, Ref)
        catch _:Reason -> Parent ! {Ref, {error, {unavailable, detail(Reason)}}}
        end
    end),
    receive
        {Ref, Result} -> demonitor(Mon, [flush]), Result;
        {'DOWN', Mon, process, Pid, _} -> {error, lost}
    end.

%% Boot-time host RPC: plugin setup runs before the handshake and may call the
%% host, so "call" frames can precede "ready". Replies are written straight to
%% the port — unlike the loop, which relays them through its own mailbox —
%% because the kernel waits for the reply before it can become ready. Other
%% frame kinds are left for the loop, and the whole boot keeps one absolute
%% deadline.
startup(Port, Host, Parent, Ref) ->
    startup(Port, Host, Parent, Ref, erlang:monotonic_time(millisecond) + ?STARTUP_TIMEOUT).

startup(Port, Host, Parent, Ref, Deadline) ->
    After = max(1, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {Port, {data, Data}} when byte_size(Data) =< 8388608 ->
            case try json:decode(Data) catch _:_ -> invalid end of
                #{<<"type">> := <<"ready">>, <<"pid">> := KernelPid, <<"pgid">> := KernelPid} = Ready
                        when is_integer(KernelPid), KernelPid > 1 ->
                    Parent ! {Ref, {ok, self()}},
                    loop(#{port => Port, host => Host, active => none,
                           events => [], groups => #{}, external => 0,
                           target => target_of(Ready)});
                #{<<"type">> := <<"startup_error">>, <<"message">> := Message} when is_binary(Message) ->
                    reap_start(Port), Parent ! {Ref, {error, {unavailable, Message}}};
                #{<<"type">> := <<"call">>, <<"id">> := Id} = Message ->
                    spawn(fun() ->
                        Reply = try json:decode(Host(iolist_to_binary(json:encode(Message))))
                                catch _:_ -> #{ok => false, code => <<"unavailable">>, message => <<"runtime unavailable">>} end,
                        _ = try port_command(Port, json:encode(#{type => <<"reply">>, id => Id, value => Reply})) catch _:_ -> ok end
                    end),
                    startup(Port, Host, Parent, Ref, Deadline);
                _ -> startup(Port, Host, Parent, Ref, Deadline)
            end;
        {Port, {data, _}} -> reap_start(Port), Parent ! {Ref, {error, {unavailable, <<"invalid kernel handshake">>}}};
        {Port, {exit_status, _}} -> Parent ! {Ref, {error, {unavailable, <<"python exited at startup">>}}}
    after After -> reap_start(Port), Parent ! {Ref, {error, {unavailable, <<"python startup timed out">>}}}
    end.

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

loop(S = #{port := Port, active := Active}) ->
    receive
        {call, From, Ref, {execute, Data, Timeout}} when Active =:= none ->
            Timer = erlang:send_after(Timeout, self(), {deadline, Ref}),
            Caller = monitor(process, From),
            port_command(Port, Data),
            Id = maps:get(<<"id">>, json:decode(Data)),
            loop(S#{active => {From, Ref, Timer, Caller, Id}});
        {call, From, Ref, {execute, _, _}} ->
            From ! {Ref, {error, busy}}, loop(S);
        {call, From, Ref, os_pid} ->
            #{target := #{pid := KernelPid}} = S,
            From ! {Ref, {ok, KernelPid}}, loop(S);
        {call, From, Ref, job_count} ->
            Count = maps:size(maps:get(groups, S)) + maps:get(external, S, 0),
            From ! {Ref, {ok, Count}}, loop(S);
        {call, From, Ref, events} ->
            From ! {Ref, {ok, lists:reverse(maps:get(events, S))}}, loop(S#{events => []});
        {call, From, Ref, stop} ->
            From ! {Ref, shutdown(S, ?TERM_MS, ?KILL_MS)},
            nil;
        interrupt -> interrupt_active(S, <<"cancelled">>), loop(S);
        {deadline, Ref} ->
            case Active of {_, Ref, _, _, _} -> interrupt_active(S, <<"deadline">>); _ -> ok end,
            loop(S);
        {kill, Ref} ->
            case Active of
                {From, Ref, _, Caller, _} ->
                    %% A forced stop loses the execution; its groups are supervised
                    %% before the caller is answered, so the kernel is gone by then.
                    demonitor(Caller, [flush]),
                    report(escalated, shutdown(S, ?ESCALATE_TERM_MS, ?ESCALATE_KILL_MS)),
                    From ! {Ref, {error, lost}};
                _ -> loop(S)
            end;
        {Port, {data, Data}} when byte_size(Data) =< 8388608 ->
            Decoded = try {ok, json:decode(Data)} catch _:_ -> error end,
            case Decoded of
                {ok, Message} -> handle(Message, Data, S);
                error -> abandon(S)
            end;
        {Port, {data, _}} -> abandon(S);
        {host_reply, Id, Reply} ->
            port_command(Port, json:encode(#{type => <<"reply">>, id => Id, value => Reply})), loop(S);
        {Port, {exit_status, _}} -> abandon(S#{exited => true});
        {'EXIT', Port, _} -> abandon(S#{exited => true});
        {'DOWN', Caller, process, _, _} ->
            case Active of
                {_, _, _, Caller, _} -> interrupt_active(S, <<"cancelled">>), loop(S);
                _ -> abandon(S)
            end;
        _ -> loop(S)
    end.

handle(#{<<"type">> := <<"done">>}, Data, S = #{active := {From, Ref, Timer, Caller, _}}) ->
    erlang:cancel_timer(Timer), demonitor(Caller, [flush]),
    From ! {Ref, {ok, Data}}, loop(S#{active => none});
handle(#{<<"type">> := <<"call">>, <<"id">> := Id} = Message, _, S) ->
    Host = maps:get(host, S), Parent = self(),
    %% Work requests never block interrupt/timeout handling of the kernel.
    spawn(fun() ->
        Reply = try json:decode(Host(iolist_to_binary(json:encode(Message))))
                catch _:_ -> #{ok => false, code => <<"unavailable">>, message => <<"runtime unavailable">>} end,
        Parent ! {host_reply, Id, Reply}
    end), loop(S);
handle(#{<<"type">> := <<"job_start">>, <<"id">> := Id, <<"pgid">> := Pgid} = Message, _, S)
        when is_integer(Pgid), Pgid > 1 ->
    loop(S#{groups => maps:put(Id, group_of(Message), maps:get(groups, S))});
handle(#{<<"type">> := <<"job">>, <<"id">> := Id} = Message, Data, S) ->
    %% A job keeps its entry while its group survives, so cleanup failures stay owned.
    Groups = case maps:get(<<"cleanup">>, Message, none) of
                 #{<<"gone">> := true} -> maps:remove(Id, maps:get(groups, S));
                 none -> maps:get(groups, S);   %% unverified: keep owning the group
                 Cleanup -> log({job_cleanup_failed, Id, Cleanup}), maps:get(groups, S)
             end,
    loop(S#{events => lists:sublist([Data | maps:get(events, S)], 100), groups => Groups});
handle(#{<<"type">> := <<"jobs">>, <<"live">> := Live}, _, S)
        when is_integer(Live), Live >= 0 ->
    loop(S#{external => Live});
handle(#{<<"type">> := <<"trace">>}, Data, S) ->
    loop(S#{events => lists:sublist([Data | maps:get(events, S)],100)});
handle(#{<<"type">> := <<"cleanup">>, <<"failures">> := Failures}, _, S) ->
    log({kernel_cleanup_failed, Failures}), loop(S);
handle(_, _, S) -> loop(S).

interrupt_active(#{active := none}, _) -> ok;
interrupt_active(#{port := Port, active := {_, Ref, _, _, Id}}, Reason) ->
    port_command(Port, json:encode(#{type => <<"interrupt">>, id => Id, reason => Reason})),
    erlang:send_after(2000, self(), {kill, Ref}).

%% Ask the kernel to clean up, wait, then end whatever it left behind. The job
%% groups live in their own sessions, so the kernel's death never reaps them.
shutdown(S = #{port := Port, target := Target}, TermMs, KillMs) ->
    _ = try port_command(Port, json:encode(#{type => <<"shutdown">>})) catch _:_ -> ok end,
    Settled = case maps:get(exited, S, false) of
        true -> S;
        false -> await_exit(S, erlang:monotonic_time(millisecond) + ?SHUTDOWN_GRACE)
    end,
    %% The leader exiting does not prove its group empty: plain subprocesses
    %% from a cell inherit the kernel group and can outlive it.
    Targets = [target_spec(<<"kernel">>, Target) | job_specs(maps:get(groups, Settled))],
    Result = verdict(supervise(Targets, TermMs, KillMs)),
    close_port(Port),
    Result.

abandon(S) -> report(owner_lost, shutdown(S, ?TERM_MS, ?KILL_MS)).

%% Keep accepting ownership transfers while shutdown is in flight. A job may
%% finish spawning after the shutdown request was sent.
await_exit(S = #{port := Port}, Deadline) ->
    Now = erlang:monotonic_time(millisecond),
    case Now >= Deadline of
        true -> S;
        false ->
            receive
                {Port, {exit_status, _}} -> S;
                {'EXIT', Port, _} -> S;
                {Port, {data, Data}} ->
                    await_exit(track_cleanup(Data, S), Deadline)
            after min(50, Deadline - Now) -> await_exit(S, Deadline)
            end
    end.

track_cleanup(Data, S = #{groups := Groups}) ->
    case try json:decode(Data) catch _:_ -> none end of
        #{<<"type">> := <<"job_start">>, <<"id">> := Id, <<"pgid">> := Pgid} = Message
            when is_integer(Pgid), Pgid > 1 ->
                S#{groups => maps:put(Id, group_of(Message), Groups)};
        #{<<"type">> := <<"job">>, <<"id">> := Id, <<"cleanup">> := #{<<"gone">> := true}} ->
            S#{groups => maps:remove(Id, Groups)};
        #{<<"type">> := <<"cleanup">>, <<"failures">> := Failures} ->
            log({kernel_cleanup_failed, Failures}), S;
        _ -> S
    end.

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
target_of(Ready) ->
    #{pid => maps:get(<<"pid">>, Ready, nil),
      pgid => maps:get(<<"pgid">>, Ready, nil),
      leader => maps:get(<<"leader">>, Ready, nil)}.

group_of(Message) ->
    #{pid => maps:get(<<"pgid">>, Message, nil),
      pgid => maps:get(<<"pgid">>, Message, nil),
      leader => maps:get(<<"leader">>, Message, nil)}.

target_spec(Label, #{pid := Pid, pgid := Pgid, leader := Leader}) ->
    Base = #{label => iolist_to_binary(Label), pid => Pid, pgid => Pgid},
    %% json:encode(nil) is the string "nil", which the helper would mistake for
    %% a process identity and reject even while an untagged group is alive.
    case Leader of nil -> Base; _ -> Base#{leader => Leader} end.

job_specs(Groups) ->
    [target_spec(<<"job ", Id/binary>>, Spec) || {Id, Spec} <- maps:to_list(Groups)].

%% Before the handshake the helper checks whether this still-owned process
%% already leads a group. Never assume startup has not reached setsid yet.
reap_start(Port) ->
    Target = case erlang:port_info(Port, os_pid) of
                 {os_pid, OsPid} when is_integer(OsPid), OsPid > 1 ->
                     [#{label => <<"kernel startup">>, pid => OsPid}];
                 _ -> []
             end,
    report(startup_reaped, supervise(Target, ?TERM_MS, ?KILL_MS)),
    close_port(Port).

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
            unicode:characters_to_binary(filename:join([code:priv_dir(albedo), "python", "albedo_kernel.py"]))}}
    end.

%% Model tools must not inherit provider credentials or the daemon's client token.
clean_environment() ->
    Keep = ["PATH","HOME","USER","LOGNAME","TMPDIR","TMP","TEMP","LANG","LC_ALL","LC_CTYPE","SYSTEMROOT",
            "ALBEDO_HOME","ALBEDO_SSH"],
    [{Name,false} || Entry <- os:getenv(), Name <- [hd(string:split(Entry,"="))], not lists:member(Name,Keep)].
