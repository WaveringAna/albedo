%% Opt-in memory inspection. With ALBEDO_INSPECT set (to anything but "" or
%% "0") the daemon joins Erlang distribution as `albedo_<ospid>`, with a cookie
%% kept in $ALBEDO_HOME/inspect.cookie, so an operator can attach and call
%% report/0:
%%
%%   erl -sname probe -setcookie "$(cat ~/.albedo/inspect.cookie)" -noshell \
%%     -eval "io:put_chars(rpc:call('albedo_<ospid>@$(hostname -s)', albedo_inspect, report, [])), halt()."
%%
%% The daemon prints its node name at startup ("inspect: node ...").
%%
%% ALBEDO_INSPECT_EVERY=N also appends a report to $ALBEDO_HOME/inspect.log
%% every N seconds. Unset, start/1 does nothing and nothing here runs.
-module(albedo_inspect).
-export([start/1, label/2, report/0, report/1, anatomy/1, peak/1, sharing/0]).

-define(MB(B), io_lib:format("~.1f MB", [(B) / 1048576])).
-define(WORD, erlang:system_info(wordsize)).

start(Home) ->
    case os:getenv("ALBEDO_INSPECT") of
        false -> nil;
        "" -> nil;
        "0" -> nil;
        _ ->
            Cookie = cookie(filename:join(Home, <<"inspect.cookie">>)),
            _ = os:cmd("epmd -daemon"),
            Name = list_to_atom("albedo_" ++ os:getpid()),
            case net_kernel:start(Name, #{name_domain => shortnames}) of
                {ok, _} ->
                    erlang:set_cookie(Cookie),
                    io:format("inspect: node ~s~n", [node()]);
                {error, Reason} ->
                    io:format("inspect: distribution unavailable: ~p~n", [Reason])
            end,
            case string:to_integer(os:getenv("ALBEDO_INSPECT_EVERY", "")) of
                {Seconds, []} when Seconds > 0 ->
                    Log = filename:join(Home, <<"inspect.log">>),
                    spawn(fun() -> periodic(Log, Seconds * 1000) end);
                _ -> ok
            end,
            nil
    end.

cookie(Path) ->
    case file:read_file(Path) of
        {ok, <<Existing:32/binary, _/binary>>} -> binary_to_atom(Existing);
        _ ->
            Fresh = binary:encode_hex(crypto:strong_rand_bytes(16), lowercase),
            ok = file:write_file(Path, Fresh),
            ok = file:change_mode(Path, 8#600),
            binary_to_atom(Fresh)
    end.

periodic(Log, Every) ->
    receive after Every -> ok end,
    Stamp = calendar:system_time_to_rfc3339(erlang:system_time(second)),
    _ = file:write_file(Log, ["=== ", Stamp, "\n", report(), "\n"], [append]),
    periodic(Log, Every).

%% Names a process in reports. Cheap enough to call unconditionally.
label(Kind, Id) -> proc_lib:set_label({binary_to_atom(Kind), Id}), nil.

report() -> report(15).

report(Top) ->
    Memory = erlang:memory(),
    Rss = case albedo_daemon:rss([list_to_integer(os:getpid())]) of
              [{_, Kb}] -> Kb * 1024;
              _ -> 0
          end,
    Procs = [P || P <- [info(Pid) || Pid <- erlang:processes()], P =/= undefined],
    Sorted = lists:reverse(lists:keysort(2, Procs)),
    AllBins = lists:usort(lists:append([B || {_, _, _, _, _, B} <- Procs])),
    Labelled = [{L, Pid} || {Pid, _, L, _, _, _} <- Procs, is_tuple(L)],
    iolist_to_binary([
        "memory\n",
        [io_lib:format("  ~-16s ~s~n", [K, ?MB(proplists:get_value(K, Memory))])
         || K <- [total, processes, system, binary, code, ets, atom]],
        io_lib:format("  ~-16s ~s  (resident, as ps sees it)~n", [os_rss, ?MB(Rss)]),
        io_lib:format("  ~-16s ~s in ~b binaries referenced by processes~n",
                      [refc_binaries, ?MB(lists:sum([S || {_, S} <- AllBins])), length(AllBins)]),
        io_lib:format("  ~-16s ~b (~s summed)~n",
                      [process_count, length(Procs), ?MB(lists:sum([M || {_, M, _, _, _, _} <- Procs]))]),
        "\nallocators (carriers = memory taken from the OS; blocks = memory in use)\n",
        [io_lib:format("  ~-16s carriers ~10s  blocks ~10s~n", [A, ?MB(C), ?MB(B)])
         || {A, C, B} <- allocators(), C > 0],
        "\nprocesses by memory (heap+stack+mailbox; refc = off-heap binaries it references)\n",
        [io_lib:format("  ~10s  refc ~10s  mq ~-4b ~s~n",
                       [?MB(M), ?MB(lists:sum([S || {_, S} <- B])), Q, name(Pid, L)])
         || {Pid, M, L, Q, _, B} <- lists:sublist(Sorted, Top)],
        "\nets tables by memory\n",
        [io_lib:format("  ~10s  ~p~n", [?MB(W * ?WORD), N])
         || {W, N} <- lists:sublist(lists:reverse(lists:sort(ets_tables())), 8)],
        [["\n", anatomy(Pid, L)] || {L, Pid} <- lists:sort(Labelled), element(1, L) =:= albedo_session]
    ]).

allocators() ->
    Rows = [{A, sizes(A)} || A <- erlang:system_info(alloc_util_allocators)],
    lists:reverse(lists:keysort(2, [{A, C, B} || {A, {C, B}} <- Rows])).

sizes(A) ->
    case erlang:system_info({allocator_sizes, A}) of
        Instances when is_list(Instances) ->
            lists:foldl(fun({instance, _, Info}, {C0, B0}) ->
                                lists:foldl(fun({K, L}, {C, B}) when K =:= mbcs; K =:= sbcs; K =:= mbcs_pool ->
                                                    {C + total(carriers_size, L), B + total(blocks_size, L)};
                                               (_, Acc) -> Acc
                                            end, {C0, B0}, Info);
                           (_, Acc) -> Acc
                        end, {0, 0}, Instances);
        _ -> {0, 0}
    end.

total(Key, L) ->
    case lists:keyfind(Key, 1, L) of
        {_, Now, _, _} -> Now;
        {_, Now} -> Now;
        false ->
            %% OTP 23+ reports blocks per allocator type under `blocks`.
            case lists:keyfind(blocks, 1, L) of
                {blocks, Types} when Key =:= blocks_size ->
                    lists:sum([element(2, lists:keyfind(size, 1, T)) || {_, T} <- Types, is_list(T), lists:keymember(size, 1, T)]);
                _ -> 0
            end
    end.

info(Pid) ->
    case erlang:process_info(Pid, [memory, message_queue_len, binary, registered_name]) of
        undefined -> undefined;
        [{memory, M}, {message_queue_len, Q}, {binary, Bins}, {registered_name, R}] ->
            Label = case proc_lib:get_label(Pid) of undefined -> R; L -> L end,
            {Pid, M, Label, Q, R, lists:usort([{Ptr, Size} || {Ptr, Size, _} <- Bins])}
    end.

name(Pid, []) -> io_lib:format("~p ~p", [Pid, initial(Pid)]);
name(Pid, Label) -> io_lib:format("~p ~0p", [Pid, Label]).

initial(Pid) ->
    case erlang:process_info(Pid, [current_function, dictionary]) of
        [{current_function, Fun}, {dictionary, Dict}] ->
            case proplists:get_value('$initial_call', Dict) of
                undefined -> Fun;
                Initial -> Initial
            end;
        _ -> dead
    end.

ets_tables() ->
    [{W, ets:info(T, name)} || T <- ets:all(), W <- [ets:info(T, memory)], is_integer(W)].

%% Field-by-field weight of a session actor's state. `flat` is the size the
%% term takes once copied to another process (messages, spawn closures) and
%% `heap` the size with in-heap sharing kept; flat >> heap means a send would
%% blow the term up. Off-heap binaries are counted separately.
anatomy(Pid) -> anatomy(Pid, proc_lib:get_label(Pid)).

anatomy(Pid, Label) ->
    case try sys:get_state(Pid, 2000) catch Class:Reason -> {Class, Reason} end of
        State when is_tuple(State), tuple_size(State) > 1 ->
            Names = fields(element(1, State), tuple_size(State) - 1),
            Rows = [{N, element(I + 1, State)} || {I, N} <- lists:enumerate(Names)],
            [io_lib:format("~0p state (~s flat, ~s heap)~n",
                           [Label, ?MB(flat(State)), ?MB(heap(State))]),
             [io_lib:format("  ~-14s flat ~10s  heap ~10s  binaries ~10s~s~n",
                            [N, ?MB(flat(V)), ?MB(heap(V)), ?MB(binaries(V)), detail(N, V)])
              || {N, V} <- Rows]];
        Other ->
            io_lib:format("~0p state unavailable: ~0p~n", [Label, Other])
    end.

%% session.State, in declaration order; an unknown shape falls back to indices.
fields(state, 16) ->
    [info, host, kernel, home, self, history, latest_usage, activity, steering,
     sequence, events, watchers, notice, context, pin, last_touch];
fields(_, N) -> [list_to_atom("field_" ++ integer_to_list(I)) || I <- lists:seq(1, N)].

detail(history, {some, Entries}) -> io_lib:format("  (~b entries)", [length(Entries)]);
detail(events, Events) when is_list(Events) -> io_lib:format("  (~b events)", [length(Events)]);
detail(_, _) -> "".

flat(Term) -> erts_debug:flat_size(Term) * ?WORD.
heap(Term) -> erts_debug:size(Term) * ?WORD.

%% Bytes of distinct binaries reachable from Term, excluding funs' environments
%% (which are walked too, since a captured closure keeps its terms alive).
binaries(Term) -> lists:sum(maps:values(walk(Term, #{}))).

walk(B, Acc) when is_binary(B) ->
    case byte_size(B) > 64 of
        true -> Acc#{binary:referenced_byte_size(B) + erlang:phash2(B) => byte_size(B)};
        false -> Acc
    end;
walk(T, Acc) when is_tuple(T) -> walk(tuple_to_list(T), Acc);
walk([H | T], Acc) -> walk(T, walk(H, Acc));
walk(M, Acc) when is_map(M) -> walk(maps:to_list(M), Acc);
walk(F, Acc) when is_function(F) ->
    case erlang:fun_info(F, env) of
        {env, Env} -> walk(Env, Acc);
        _ -> Acc
    end;
walk(_, Acc) -> Acc.

%% Samples for Ms milliseconds and reports the high-water mark: VM totals and,
%% for every process that crossed 1 MB, its largest size and the frames it was
%% running at that moment. Transient spikes are invisible to report/0.
peak(Ms) ->
    Until = erlang:monotonic_time(millisecond) + Ms,
    {Totals, Procs} = sample(Until, #{}, #{}),
    iolist_to_binary([
        "peak memory\n",
        [io_lib:format("  ~-12s ~s~n", [K, ?MB(maps:get(K, Totals, 0))])
         || K <- [total, processes, binary, system]],
        "peak processes (largest size seen, frames at that moment)\n",
        [io_lib:format("  ~10s  ~s~n~s", [?MB(M), name(Pid, L), [io_lib:format("      ~s~n", [frame(F)]) || F <- Stack]])
         || {M, Pid, L, Stack} <- lists:reverse(lists:sort(maps:values(Procs)))]
    ]).

sample(Until, Totals, Procs) ->
    case erlang:monotonic_time(millisecond) > Until of
        true -> {Totals, Procs};
        false ->
            Now = maps:from_list(erlang:memory([total, processes, binary, system])),
            Totals1 = maps:merge_with(fun(_, A, B) -> max(A, B) end, Totals, Now),
            Procs1 = lists:foldl(fun(Pid, Acc) ->
                case erlang:process_info(Pid, memory) of
                    {memory, M} when M > 1048576 ->
                        case maps:get(Pid, Acc, {0, Pid, [], []}) of
                            {Old, _, _, _} when Old >= M -> Acc;
                            _ ->
                                Stack = case erlang:process_info(Pid, current_stacktrace) of
                                            {current_stacktrace, S} -> lists:sublist(S, 8);
                                            _ -> []
                                        end,
                                Label = case proc_lib:get_label(Pid) of undefined -> []; L -> L end,
                                Acc#{Pid => {M, Pid, Label, Stack}}
                        end;
                    _ -> Acc
                end
            end, Procs, erlang:processes()),
            receive after 10 -> ok end,
            sample(Until, Totals1, Procs1)
    end.

frame({M, F, A, Info}) ->
    Arity = if is_list(A) -> length(A); true -> A end,
    io_lib:format("~s:~s/~b ~s", [M, F, Arity, case proplists:get_value(line, Info) of undefined -> ""; N -> integer_to_list(N) end]).

%% Isolation versus sharing across labelled albedo processes.
%% shared: one off-heap binary (same storage) referenced by several processes.
%% repeated: equal content reachable from several actor states; storage identity
%% is invisible from Erlang, so this is an upper bound on duplicated bytes and is
%% only meaningful next to the shared figure.
sharing() ->
    Labelled = [{Pid, L} || Pid <- erlang:processes(), L <- [proc_lib:get_label(Pid)], is_tuple(L)],
    Owners = lists:foldl(fun({Pid, _}, Acc) ->
        case erlang:process_info(Pid, binary) of
            {binary, Bins} ->
                lists:foldl(fun({Ptr, Size, _}, A) ->
                    maps:update_with(Ptr, fun({S, Ps}) -> {S, [Pid | Ps]} end, {Size, [Pid]}, A)
                end, Acc, lists:usort(Bins));
            _ -> Acc
        end
    end, #{}, Labelled),
    Shared = [{S, length(lists:usort(Ps))} || {S, Ps} <- maps:values(Owners), length(lists:usort(Ps)) > 1],
    Contents = lists:foldl(fun({Pid, L}, Acc) ->
        case element(1, L) of
            K when K =:= albedo_session; K =:= albedo_runtime ->
                State = try sys:get_state(Pid, 2000) catch _:_ -> none end,
                maps:fold(fun(Key, Size, A) ->
                    maps:update_with(Key, fun({Sz, N}) -> {Sz, N + 1} end, {Size, 1}, A)
                end, Acc, contents(State, #{}));
            _ -> Acc
        end
    end, #{}, Labelled),
    Repeated = [{Sz, N} || {Sz, N} <- maps:values(Contents), N > 1],
    iolist_to_binary([
        io_lib:format("labelled processes ~b~n", [length(Labelled)]),
        io_lib:format("shared   ~s in ~b binaries referenced by 2+ albedo processes~n",
                      [?MB(lists:sum([S || {S, _} <- Shared])), length(Shared)]),
        io_lib:format("repeated ~s of extra copies: ~b distinct contents held by 2+ actor states~n",
                      [?MB(lists:sum([Sz * (N - 1) || {Sz, N} <- Repeated])), length(Repeated)]),
        [io_lib:format("  ~10s x~b~n", [?MB(Sz), N]) || {Sz, N} <- lists:sublist(lists:reverse(lists:sort(Repeated)), 10)]
    ]).

%% Content key -> size for distinct binaries over 64 bytes reachable from Term,
%% counted once per actor state.
contents(B, Acc) when is_binary(B), byte_size(B) > 64 -> Acc#{{byte_size(B), erlang:phash2(B)} => byte_size(B)};
contents(T, Acc) when is_tuple(T) -> contents(tuple_to_list(T), Acc);
contents([H | T], Acc) -> contents(T, contents(H, Acc));
contents(M, Acc) when is_map(M) -> contents(maps:to_list(M), Acc);
contents(F, Acc) when is_function(F) ->
    case erlang:fun_info(F, env) of {env, E} -> contents(E, Acc); _ -> Acc end;
contents(_, Acc) -> Acc.
