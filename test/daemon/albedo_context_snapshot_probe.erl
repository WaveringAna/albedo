%% Test-only structural inspection. Never returns inspected actor state.
-module(albedo_context_snapshot_probe).
-export([retention/0, actor/1, actor_json/1]).

capture(Inputs) ->
    Request = 'albedo@openai_api':request(<<"fixture">>, Inputs),
    'albedo@daemon@context_snapshot':from_request(
        {some, 1234}, <<"fixture">>, <<"responses">>, responses, Request, none).

payload(Prefix, Index, Bytes) ->
    Head = iolist_to_binary([Prefix, integer_to_binary(Index), <<":">>]),
    <<Head/binary, (binary:copy(<<"x">>, Bytes - byte_size(Head)))/binary>>.
replay(Index, Bytes) ->
    Encoded = iolist_to_binary(json:encode(#{type => <<"reasoning">>,
        opaque => payload(<<"REPLAY_SENTINEL:">>, Index, Bytes)})),
    {ok, Item} = 'gleam@json':parse(Encoded,
        'albedo@openai_api@types':replay_decoder(responses)),
    {replay, Item}.

inline() ->
    {ok, Image} = 'albedo@openai_api@types':image(<<"image/png">>,
        payload(<<"INLINE_SENTINEL:">>, 1, 1048576), 10, 10, 786432),
    Image.
stored() ->
    Sentinel = payload(<<"READER_SENTINEL:">>, 1, 1048576),
    {ok, Image} = 'albedo@openai_api@types':stored_image(<<"image/png">>,
        <<"stored-hash">>, 1048576, fun() -> {ok, Sentinel} end, 10, 10, 786432),
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

binary_bytes(Pid) ->
    {binary, Entries} = process_info(Pid, binary),
    lists:sum(maps:values(maps:from_list([{Pointer, Bytes} || {Pointer, Bytes, _} <- Entries]))).
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
        Check ! {checked, 'albedo@daemon@session_diagnostics':history_unloaded(State),
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
    {ok, Snapshot} = 'albedo@daemon@session':prepared_context(Session, none),
    HistoryPage = 'albedo@daemon@context_snapshot':page(Snapshot, <<"history">>, 0),
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
    {ok, Pending} = 'albedo@daemon@session':prepared_context(Session, none),
    {pending, _} = Pending,
    SessionMonitor = monitor(process, Pid),
    _ = 'albedo@daemon@session':close(Session),
    Stopped = receive {'DOWN', SessionMonitor, process, Pid, _} -> true after 5000 -> false end,
    #{evicted => Evicted, history_unloaded => Unloaded, replay_reachable => Reachable,
      history_readable => element(1, HistoryPage) =:= ok,
      actor_binary_bytes => Retained, replay_backing_binary_bytes => Backing,
      replay_backing_before_bytes => lists:sum(maps:values(LargePointers)),
      kernel_released => Released, context_cleared => element(1, Pending) =:= pending,
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
