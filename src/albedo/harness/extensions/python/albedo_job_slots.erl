%% Heavy-job slots for the whole daemon. Every shell job starts at once; only a
%% job still running after the grace window asks for a slot, so quick commands
%% never wait. A job that cannot get one is paused by its kernel (SIGSTOP) and
%% resumed when a slot frees, so waiting costs no CPU and loses no work.
%%
%% Slots default to the machine's cores and shrink while the load average runs
%% well past them: a heavy job that fans out its own workers leaves less room.
%% A freed slot goes to the kernel holding the fewest, oldest request first, so
%% one busy agent cannot starve the rest.
%%
%% Only confirmed cleanup releases a running lease. If its bridge dies without
%% that proof, keep the slot reserved rather than oversubscribing leaked work.
%%
%% Kernels on another host share that host's own pool instead: sized to the
%% cores its probe reported (ALBEDO_MAX_REMOTE_JOBS overrides), with no load
%% adjustment, since this machine's load average says nothing about it. The
%% local pool starts and watches the host pools; the admission protocol is the
%% same.
-module(albedo_job_slots).
-behaviour(gen_server).
-export([ensure/0, ensure/2, acquire/2, claim/2, release/2, release_owner/1, limit/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-record(state, {base, running = 0, entries = #{}, waiting = [], load = false, ticking = false, hosts = #{}}).
-define(MAX_WAITING, 1024).
-define(TICK_MS, 2000).
%% Load above this multiple of the cores counts as overload.
-define(OVERLOAD, 1.25).

ensure() ->
    case gen_server:start({local, ?MODULE}, ?MODULE, [], []) of
        {ok, Pid} -> Pid;
        {error, {already_started, Pid}} -> Pid
    end.

%% The pool for kernels on Host, which has Cpus cores.
ensure(Host, Cpus) -> gen_server:call(ensure(), {host, Host, Cpus}).

acquire(Pool, Id) -> gen_server:cast(Pool, {acquire, self(), Id}).
%% A slot a running job already holds, granted by an earlier daemon: it counts
%% at once, even past the limit, and nothing is sent back.
claim(Pool, Id) -> gen_server:cast(Pool, {claim, self(), Id}).
release(Pool, Id) -> gen_server:cast(Pool, {release, {self(), Id}}).
release_owner(Pool) -> gen_server:cast(Pool, {release_owner, self()}).

%% The slot count right now, for tests and status.
limit() -> gen_server:call(ensure(), limit).

init([{host, Cpus}]) -> {ok, #state{base = remote_base(Cpus)}};
init([]) ->
    Cores = case erlang:system_info(logical_processors_available) of
                N when is_integer(N), N > 0 -> N;
                _ -> erlang:system_info(schedulers_online)
            end,
    Base = try list_to_integer(os:getenv("ALBEDO_MAX_LOCAL_JOBS", "")) of
               N2 when N2 > 0 -> min(256, N2);
               _ -> Cores
           catch _:_ -> Cores end,
    %% The load average comes from os_mon; without it the base stands alone.
    %% ALBEDO_JOB_LOAD=0 turns the adjustment off, for a fixed count.
    %% Only the load average is wanted: no disk or memory monitors and their alarms.
    Load = os:getenv("ALBEDO_JOB_LOAD") =/= "0" andalso
           try
               _ = application:load(os_mon),
               [application:set_env(os_mon, K, false)
                || K <- [start_disksup, start_memsup, start_os_sup]],
               {ok, _} = application:ensure_all_started(os_mon, temporary),
               true
           catch _:_ -> false
           end,
    {ok, #state{base = Base, load = Load}}.

handle_call(limit, _, S) -> {reply, effective(S), S};
handle_call({host, Host, Cpus}, _, S = #state{hosts = Hosts}) ->
    case maps:find(Host, Hosts) of
        {ok, Pool} ->
            %% A pool opened while the host was out of reach learns its cores
            %% from the first kernel that probed it.
            Cpus > 0 andalso gen_server:cast(Pool, {base, Cpus}),
            {reply, Pool, S};
        error ->
            {ok, Pool} = gen_server:start(?MODULE, [{host, Cpus}], []),
            monitor(process, Pool),
            {reply, Pool, S#state{hosts = Hosts#{Host => Pool}}}
    end;
handle_call(_, _, S) -> {reply, {error, unsupported}, S}.

handle_cast({acquire, Owner, Id}, S = #state{entries = Entries}) ->
    Key = {Owner, Id},
    case {maps:is_key(Key, Entries), length(S#state.waiting) >= ?MAX_WAITING} of
        {true, _} -> {noreply, S};
        {false, true} ->
            Owner ! {job_slot, Id, {error, <<"heavy job queue is full">>}},
            {noreply, S};
        {false, false} ->
            Mon = monitor(process, Owner),
            S1 = drain(S#state{entries = Entries#{Key => {waiting, Mon}},
                               waiting = S#state.waiting ++ [Key]}),
            %% Not granted on the spot: say so, so the kernel pauses the job.
            case maps:get(Key, S1#state.entries) of
                {waiting, _} -> Owner ! {job_slot, Id, queued};
                _ -> ok
            end,
            {noreply, tick(S1)}
    end;
handle_cast({claim, Owner, Id}, S = #state{entries = Entries, running = Running}) ->
    Key = {Owner, Id},
    case maps:is_key(Key, Entries) of
        true -> {noreply, S};
        false ->
            Mon = monitor(process, Owner),
            {noreply, S#state{entries = Entries#{Key => {active, Mon}}, running = Running + 1}}
    end;
handle_cast({release, Key}, S) -> {noreply, drain(drop(Key, S))};
handle_cast({base, Cpus}, S) -> {noreply, drain(S#state{base = remote_base(Cpus)})};
handle_cast({release_owner, Owner}, S) ->
    {noreply, drop_keys([K || {P, _} = K := _ <- S#state.entries, P =:= Owner], S)}.

handle_info(tick, S) ->
    {noreply, tick(drain(S#state{ticking = false}))};
handle_info({'DOWN', Mon, process, Pid, _}, S = #state{hosts = Hosts}) ->
    case [Host || Host := Pool <- Hosts, Pool =:= Pid] of
        [Host | _] -> {noreply, S#state{hosts = maps:remove(Host, Hosts)}};
        %% A waiting request owns no running work; active ones need cleanup proof.
        [] -> {noreply, drop_keys([K || {P, _} = K := {waiting, Ref} <- S#state.entries,
                                        P =:= Pid, Ref =:= Mon], S)}
    end;
handle_info(_, S) -> {noreply, S}.

%% A host pool's size: ALBEDO_MAX_REMOTE_JOBS, else the host's cores, else
%% (cores still unknown) two.
remote_base(Cpus) ->
    Default = case Cpus > 0 of true -> Cpus; false -> 2 end,
    try list_to_integer(os:getenv("ALBEDO_MAX_REMOTE_JOBS", "")) of
        N when N > 0 -> min(256, N);
        _ -> Default
    catch _:_ -> Default
    end.

drop_keys(Keys, S) -> drain(lists:foldl(fun drop/2, S, Keys)).

%% While anything waits, look again now and then: the load may have fallen.
tick(S = #state{waiting = [_ | _], ticking = false}) ->
    erlang:send_after(?TICK_MS, self(), tick),
    S#state{ticking = true};
tick(S) -> S.

effective(#state{base = Base, load = false}) -> Base;
effective(#state{base = Base}) ->
    Load = try cpu_sup:avg1() / 256 catch _:_ -> 0.0 end,
    Excess = Load - Base * ?OVERLOAD,
    if Excess > 0 -> max(1, Base - ceil(Excess)); true -> Base end.

drop(Key, S = #state{entries = Entries, running = Running, waiting = Waiting}) ->
    case maps:take(Key, Entries) of
        error -> S;
        {{State, Mon}, Rest} ->
            demonitor(Mon, [flush]),
            case State of
                active -> S#state{entries = Rest, running = Running - 1};
                waiting -> S#state{entries = Rest, waiting = lists:delete(Key, Waiting)}
            end
    end.

drain(S = #state{waiting = []}) -> S;
drain(S = #state{running = N}) ->
    case N >= effective(S) of
        true -> S;
        false ->
            Key = {Owner, Id} = fairest(S),
            {waiting, Mon} = maps:get(Key, S#state.entries),
            Waiting = lists:delete(Key, S#state.waiting),
            case is_process_alive(Owner) of
                false -> drain(drop(Key, S));
                true ->
                    Owner ! {job_slot, Id, ok},
                    drain(S#state{waiting = Waiting, running = N + 1,
                                  entries = (S#state.entries)#{Key => {active, Mon}}})
            end
    end.

%% The oldest request from the kernel that holds the fewest slots.
fairest(#state{waiting = Waiting, entries = Entries}) ->
    Held = maps:fold(fun({Owner, _}, {active, _}, Acc) -> maps:update_with(Owner, fun(C) -> C + 1 end, 1, Acc);
                        (_, _, Acc) -> Acc
                     end, #{}, Entries),
    {_, Key} = lists:min([{{maps:get(Owner, Held, 0), Index}, Key}
                          || {Index, Key = {Owner, _}} <- lists:enumerate(Waiting)]),
    Key.
