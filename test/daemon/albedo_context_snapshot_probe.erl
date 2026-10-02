%% Test-only structural inspection. Never returns inspected actor state.
-module(albedo_context_snapshot_probe).
-export([benchmark/0, retention/0, actor/1, actor_json/1]).

capture(Inputs) -> 'manual@context_snapshot_benchmark':capture(Inputs).
summary(Snapshot) -> 'manual@context_snapshot_benchmark':summary(Snapshot).
page(Snapshot, Index) -> 'manual@context_snapshot_benchmark':page(Snapshot, Index).

payload(Prefix, Index, Bytes) ->
    Head = iolist_to_binary([Prefix, integer_to_binary(Index), <<":">>]),
    <<Head/binary, (binary:copy(<<"x">>, Bytes - byte_size(Head)))/binary>>.
replay(Index, Bytes) ->
    'manual@context_snapshot_benchmark':replay(payload(<<"REPLAY_SENTINEL:">>, Index, Bytes)).

inline() ->
    {ok, Image} = 'albedo@openai_api@types':image(<<"image/png">>,
        payload(<<"INLINE_SENTINEL:">>, 1, 1048576), 10, 10, 786432),
    Image.
stored() ->
    Sentinel = payload(<<"READER_SENTINEL:">>, 1, 1048576),
    {ok, Image} = 'albedo@openai_api@types':stored_image(<<"image/png">>,
        <<"stored-hash">>, 1048576, fun() -> {ok, Sentinel} end, 10, 10, 786432),
    Image.

stored_reference() ->
    {ok, Image} = 'albedo@openai_api@types':stored_image(<<"image/png">>,
        <<"stored-hash">>, 4096, fun() -> {error, nil} end, 10, 10, 3072),
    Image.

walk(Term, Test) when is_binary(Term) -> Test(Term);
walk(Term, Test) when is_tuple(Term) -> walk(tuple_to_list(Term), Test);
walk([Head | Tail], Test) -> walk(Head, Test) orelse walk(Tail, Test);
walk(Term, Test) when is_map(Term) -> walk(maps:to_list(Term), Test);
walk(Term, Test) when is_function(Term) ->
    {env, Environment} = erlang:fun_info(Term, env), walk(Environment, Test);
walk(_, _) -> false.
contains(Term, Prefix) -> walk(Term, fun(Binary) ->
    binary:match(Binary, Prefix) =/= nomatch end).

retention() ->
    Parent = self(),
    {Producer, Monitor} = spawn_monitor(fun() ->
        Parent ! {snapshot, capture([{user, <<"VISIBLE_SENTINEL:", (binary:copy(<<"v">>, 256))/binary>>},
            replay(1, 1048576), {user_image, <<"image">>, inline()},
            {tool_output, <<"call">>, <<"tool">>, [stored()]}])}
    end),
    Snapshot = receive {snapshot, Value} -> Value end,
    receive {'DOWN', Monitor, process, Producer, normal} -> ok end,
    erlang:garbage_collect(),
    {contains(Snapshot, <<"VISIBLE_SENTINEL:">>),
     contains(Snapshot, <<"REPLAY_SENTINEL:">>),
     contains(Snapshot, <<"INLINE_SENTINEL:">>),
     contains(Snapshot, <<"READER_SENTINEL:">>)}.

fixture(text, Count, Bytes) -> [{user, payload(<<"visible:">>, I, Bytes)} || I <- lists:seq(1, Count)];
fixture(replay, Count, Bytes) -> [replay(I, Bytes) || I <- lists:seq(1, Count)];
fixture(mixed, Count, Bytes) -> lists:append([
    [{user, payload(<<"visible:">>, I, Bytes)}, replay(I, Bytes),
     {tool_output, integer_to_binary(I), <<"output">>, [stored_reference()]}]
    || I <- lists:seq(1, Count)]).

binary_bytes(Pid) ->
    {binary, Entries} = process_info(Pid, binary),
    lists:sum(maps:values(maps:from_list([{Pointer, Bytes} || {Pointer, Bytes, _} <- Entries]))).
measure(Name, Action) ->
    Owner = self(),
    Sampler = spawn(fun() -> sample(Owner, Owner, #{}) end),
    {reductions, Before} = process_info(self(), reductions),
    Start = erlang:monotonic_time(microsecond),
    Value = Action(),
    Elapsed = erlang:monotonic_time(microsecond) - Start,
    {reductions, After} = process_info(self(), reductions),
    Sampler ! stop,
    Peak = receive {peak, Sample} -> Sample end,
    {Value, #{phase => Name, wall_us => Elapsed, reductions => After - Before,
        sampled_peak => Peak}}.

sample(Owner, Parent, Peak) ->
    receive stop -> Parent ! {peak, Peak}
    after 1 ->
        Current = case process_info(Owner, [memory, message_queue_len]) of
            undefined -> #{heap_mailbox_bytes => 0, mailbox_messages => 0};
            Info -> #{heap_mailbox_bytes => proplists:get_value(memory, Info),
                      mailbox_messages => proplists:get_value(message_queue_len, Info)}
        end,
        Next = maps:merge_with(fun(_, A, B) -> max(A, B) end, Peak,
            Current#{vm_binary_bytes => erlang:memory(binary)}),
        sample(Owner, Parent, Next)
    end.

run(Kind, Count, Bytes, Iteration) ->
    Parent = self(),
    {Owner, Monitor} = spawn_monitor(fun() ->
        Inputs = fixture(Kind, Count, Bytes),
        benchmark_owner(Inputs, Parent, Kind, Count, Bytes, Iteration)
    end),
    receive {record, Owner, Record} ->
        receive {'DOWN', Monitor, process, Owner, normal} -> ok end,
        Record
    end.

benchmark_owner(Inputs, Parent, Kind, Count, Bytes, Iteration) ->
    {Snapshot, Capture} = measure(capture, fun() -> capture(Inputs) end),
    benchmark_snapshot(Snapshot, Parent, Kind, Count, Bytes, Iteration, Capture).
benchmark_snapshot(Snapshot, Parent, Kind, Count, Bytes, Iteration, Capture) ->
    erlang:garbage_collect(),
    CaptureRetained = binary_bytes(self()),
    {Summary, SummaryMetric} = measure(summary, fun() -> summary(Snapshot) end),
    {_, First} = measure(first_page, fun() -> page(Snapshot, 0) end),
    {Pages, All} = measure(all_pages, fun() -> all_pages(Snapshot, 0, []) end),
    ReplacementInputs = fixture(Kind, Count, Bytes),
    put(benchmark_snapshot, Snapshot),
    {_, Replace} = measure(replacement, fun() -> replace(ReplacementInputs, 5) end),
    erase(benchmark_snapshot),
    Hash = binary:encode_hex(crypto:hash(sha256, [Summary | Pages]), lowercase),
    benchmark_retained(Snapshot, Parent, Kind, Count, Bytes, Iteration,
        [Capture, SummaryMetric, First, All, Replace], Hash, CaptureRetained).
replace(_, 0) -> nil;
replace(Inputs, Count) ->
    %% The previous snapshot stays in the owner's dictionary during capture.
    put(benchmark_snapshot, capture(Inputs)), replace(Inputs, Count - 1).
benchmark_retained(Snapshot, Parent, Kind, Count, Bytes, Iteration, Metrics, Hash, CaptureRetained) ->
    %% Tail call releases prepared inputs and rendered inspector buffers.
    {_, Eviction} = measure(history_eviction_collection, fun() -> erlang:garbage_collect() end),
    Retained = binary_bytes(self()),
    TermBytes = erts_debug:flat_size(Snapshot) * erlang:system_info(wordsize),
    Reachable = contains(Snapshot, <<"REPLAY_SENTINEL:">>),
    {_, Idle} = measure(idle_retention, fun() -> erlang:garbage_collect() end),
    benchmark_clear(Parent, Kind, Count, Bytes, Iteration,
        Metrics ++ [Eviction, Idle], Retained, TermBytes, Reachable, Hash, CaptureRetained).

benchmark_clear(Parent, Kind, Count, Bytes, Iteration, Metrics, Retained, TermBytes, Reachable, Hash, CaptureRetained) ->
    {_, Clear} = measure(context_clear, fun() -> erlang:garbage_collect() end),
    Parent ! {record, self(), #{fixture => Kind, count => Count, payload_bytes => Bytes,
        iteration => Iteration, phases => Metrics ++ [Clear], capture_retained_binary_bytes => CaptureRetained,
        retained_binary_bytes => Retained, cleared_binary_bytes => binary_bytes(self()),
        snapshot_term_bytes => TermBytes, discarded_payload_reachable => Reachable,
        output_sha256 => Hash}}.
all_pages(Snapshot, Index, Acc) ->
    case page(Snapshot, Index) of
        <<"context page not found">> -> lists:reverse(Acc);
        <<"context section not found">> -> lists:reverse(Acc);
        Value -> all_pages(Snapshot, Index + 1, [Value | Acc])
    end.
benchmark() ->
    io:put_chars(json:encode(#{otp => list_to_binary(erlang:system_info(otp_release)),
        schedulers => erlang:system_info(schedulers_online)})), io:nl(),
    Fixtures = [{text, N, 256} || N <- [10, 1000, 10000]] ++
        [{replay, N, 4096} || N <- [10, 1000, 10000]] ++
        [{replay, 1000, 65536}, {mixed, 1000, 4096}],
    lists:foreach(fun({Kind, Count, Bytes}) ->
        _ = run(Kind, Count, Bytes, 0),
        lists:foreach(fun(Iteration) ->
            io:put_chars(json:encode(run(Kind, Count, Bytes, Iteration))), io:nl()
        end, lists:seq(1, 5))
    end, Fixtures), nil.

actor(Id) ->
    {some, Session} = 'albedo@daemon@session':live(Id),
    {ok, Pid} = 'gleam@erlang@process':subject_owner(Session),
    Workers = [Worker || Worker <- processes(), Label <- [proc_lib:get_label(Worker)],
        is_tuple(Label), element(1, Label) =:= albedo_worker],
    lists:foreach(fun(Worker) ->
        Monitor = monitor(process, Worker),
        receive {'DOWN', Monitor, process, Worker, _} -> ok after 10000 -> error(worker_still_alive) end
    end, Workers),
    erlang:garbage_collect(Pid),
    {binary, BeforeEntries} = process_info(Pid, binary),
    LargePointers = maps:from_list([{Pointer, Size} || {Pointer, Size, _} <- BeforeEntries,
        Size >= 262144]),
    {Evicted, EvictionMetric} = actor_measure(Pid, history_eviction_collection, fun() ->
        DidEvict = 'albedo@daemon@session':evict_history(Session),
        %% Two synchronous actor barriers pass the self-sent Collect message.
        _ = 'albedo@daemon@session':report(Session),
        _ = 'albedo@daemon@session':report(Session),
        erlang:garbage_collect(Pid),
        DidEvict
    end),
    Check = self(),
    {Reader, ReaderMonitor} = spawn_monitor(fun() ->
        State = sys:get_state(Pid),
        %% history is field 6 in session_state.State.
        state = element(1, State),
        Check ! {checked, element(7, State) =:= none,
            contains(State, <<"REPLAY_SENTINEL:">>)}
    end),
    {Unloaded, Reachable} = receive
        {checked, A, B} -> {A, B};
        {'DOWN', ReaderMonitor, process, Reader, Reason} -> error({state_inspection_failed, Reason})
    end,
    receive {'DOWN', ReaderMonitor, process, Reader, normal} -> ok end,
    erlang:garbage_collect(Pid),
    Retained = binary_bytes(Pid),
    {binary, AfterEntries} = process_info(Pid, binary),
    Backing = lists:sum(maps:values(maps:from_list([{Pointer, Size}
        || {Pointer, Size, _} <- AfterEntries, maps:is_key(Pointer, LargePointers)]))),
    HistoryPage = 'albedo@daemon@session':context_page(Session, <<"history">>, 0),
    {_, IdleMetric} = actor_measure(Pid, idle_retention, fun() ->
        _ = 'albedo@daemon@session':report(Session),
        erlang:garbage_collect(Pid)
    end),
    {Released, ClearMetric} = actor_measure(Pid, context_clear, fun() ->
        DidRelease = 'albedo@daemon@session':release(Session),
        _ = 'albedo@daemon@session':report(Session),
        _ = 'albedo@daemon@session':report(Session),
        erlang:garbage_collect(Pid),
        DidRelease
    end),
    Pending = 'albedo@daemon@session':context(Session),
    PendingExpected = 'albedo@daemon@context_snapshot':summary(
        'albedo@daemon@context_snapshot':pending(
            <<"runtime session has not prepared a provider request">>)),
    SessionMonitor = monitor(process, Pid),
    _ = 'albedo@daemon@session':close(Session),
    Stopped = receive {'DOWN', SessionMonitor, process, Pid, _} -> true after 5000 -> false end,
    #{evicted => Evicted, history_unloaded => Unloaded, replay_reachable => Reachable,
      history_readable => element(1, HistoryPage) =:= ok,
      actor_binary_bytes => Retained, replay_backing_binary_bytes => Backing,
      replay_backing_before_bytes => lists:sum(maps:values(LargePointers)),
      kernel_released => Released, context_cleared => Pending =:= PendingExpected,
      actor_stopped => Stopped, workers_terminated => true,
      phases => [EvictionMetric, IdleMetric, ClearMetric]}.
actor_json(Id) -> iolist_to_binary(json:encode(actor(Id))).

actor_measure(Pid, Name, Action) ->
    {reductions, Before} = process_info(Pid, reductions),
    Start = erlang:monotonic_time(microsecond),
    Value = Action(),
    Elapsed = erlang:monotonic_time(microsecond) - Start,
    {reductions, After} = process_info(Pid, reductions),
    {memory, Memory} = process_info(Pid, memory),
    {message_queue_len, Mailbox} = process_info(Pid, message_queue_len),
    {Value, #{phase => Name, wall_us => Elapsed, reductions => After - Before,
        actor_memory_bytes => Memory, mailbox_messages => Mailbox,
        actor_binary_bytes => binary_bytes(Pid)}}.
