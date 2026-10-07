%% A mutex per key within this node. A waiter is granted the lock the moment
%% its holder releases it or exits. global:trans instead retries after random
%% sleeps of up to 125 ms, then 250 ms, and so on, so a settings read that met
%% another read waited tens of milliseconds for a lock held well under one.
-module(albedo_lock).
-export([trans/3]).

%% {ok, Run()} under Key, or busy when it is not granted within Timeout ms.
trans(Key, Run, Timeout) ->
    Server = server(),
    Ref = monitor(process, Server),
    Server ! {acquire, Key, self(), Ref},
    receive
        {Ref, granted} ->
            try {ok, Run()}
            after
                Server ! {release, Key, Ref},
                demonitor(Ref, [flush])
            end;
        {'DOWN', Ref, process, _, _} -> busy
    after Timeout ->
        Server ! {cancel, Key, Ref},
        demonitor(Ref, [flush]),
        receive {Ref, granted} -> ok after 0 -> ok end,
        busy
    end.

%% The registered lock owner, started by whichever caller needs it first.
server() ->
    case whereis(?MODULE) of
        undefined ->
            Parent = self(),
            Ready = make_ref(),
            {Owner, Monitor} = spawn_monitor(fun() -> owner(Parent, Ready) end),
            receive
                {Ready, ready} -> demonitor(Monitor, [flush]), server();
                {'DOWN', Monitor, process, Owner, Reason} -> error({lock_start_failed, Reason})
            end;
        Server -> Server
    end.

%% A losing creator acknowledges the registered owner and exits.
owner(Parent, Ready) ->
    Won = try register(?MODULE, self()) catch error:badarg -> false end,
    Parent ! {Ready, ready},
    case Won of
        true -> loop(#{});
        false -> ok
    end.

%% Locks maps each held key to {{HolderRef, HolderMonitor}, Waiting}, where
%% Waiting queues {Pid, Ref} in arrival order.
loop(Locks) ->
    receive
        {acquire, Key, Pid, Ref} ->
            loop(case Locks of
                #{Key := {Holder, Waiting}} -> Locks#{Key := {Holder, queue:in({Pid, Ref}, Waiting)}};
                _ -> grant(Key, {Pid, Ref}, queue:new(), Locks)
            end);
        {release, Key, Ref} -> loop(release(Key, Ref, Locks));
        {cancel, Key, Ref} -> loop(cancel(Key, Ref, Locks));
        {'DOWN', Monitor, process, _, _} -> loop(holder_down(Monitor, Locks))
    end.

grant(Key, {Pid, Ref}, Waiting, Locks) ->
    Pid ! {Ref, granted},
    Locks#{Key => {{Ref, monitor(process, Pid)}, Waiting}}.

release(Key, Ref, Locks) ->
    case Locks of
        #{Key := {{Ref, Monitor}, Waiting}} ->
            demonitor(Monitor, [flush]),
            next(Key, Waiting, Locks);
        _ -> Locks
    end.

next(Key, Waiting, Locks) ->
    case queue:out(Waiting) of
        {{value, Waiter}, Rest} -> grant(Key, Waiter, Rest, Locks);
        {empty, _} -> maps:remove(Key, Locks)
    end.

%% A waiter that gave up leaves the queue; one granted meanwhile releases.
cancel(Key, Ref, Locks) ->
    case Locks of
        #{Key := {{Ref, _}, _}} -> release(Key, Ref, Locks);
        #{Key := {Holder, Waiting}} ->
            Locks#{Key := {Holder, queue:filter(fun({_, Queued}) -> Queued =/= Ref end, Waiting)}};
        _ -> Locks
    end.

%% A holder that exits releases its lock.
holder_down(Monitor, Locks) ->
    case [{Key, Ref} || Key := {{Ref, M}, _} <- Locks, M =:= Monitor] of
        [{Key, Ref}] -> release(Key, Ref, Locks);
        [] -> Locks
    end.
