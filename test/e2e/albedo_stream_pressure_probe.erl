%% Inspect real stream owners while publishers fill an unread TCP connection.
-module(albedo_stream_pressure_probe).
-export([pressure_json/1, subscriptions_json/0, removed_json/0,
    progress_json/1, session_pressure_json/1, session_removed_json/1, burst_json/3,
    suspend_session_json/1, resume_session_json/1, worker_exit_json/3, maintenance_json/1]).

rows(Table) ->
    case ets:whereis(Table) of
        undefined -> [];
        _ -> ets:tab2list(Table)
    end.

bytes(Binary) when is_binary(Binary) -> byte_size(Binary);
bytes(Map) when is_map(Map) -> bytes(maps:to_list(Map));
bytes(Tuple) when is_tuple(Tuple) -> bytes(tuple_to_list(Tuple));
bytes([Head | Tail]) -> bytes(Head) + bytes(Tail);
bytes(_) -> 0.

blocked(Owner) ->
    case process_info(Owner, current_stacktrace) of
        {current_stacktrace, Frames} ->
            case lists:any(fun({_, Function, _, _}) ->
                lists:member(Function, [send, send_event, port_command])
            end, Frames) of true -> 1; false -> 0 end;
        undefined -> 0
    end.

sample({Ref, {Owner, _, Control, _}}) ->
    {Count, Bytes} = case ets:lookup(albedo_bus_queues, Ref) of
        [{_, {_, C, B}}] -> {C, B};
        [] -> {0, 0}
    end,
    case process_info(Owner, [messages, message_queue_len]) of
        undefined -> #{count => Count, bytes => Bytes, mailbox => 0,
            mailbox_bytes => 0, blocked => 0, overflow => atomics:get(Control, 1)};
        Info -> #{count => Count, bytes => Bytes,
            mailbox => proplists:get_value(message_queue_len, Info),
            mailbox_bytes => bytes(proplists:get_value(messages, Info)),
            blocked => blocked(Owner), overflow => atomics:get(Control, 1)}
    end.

measure() ->
    lists:foldl(fun(Row, Peak) ->
        maps:merge_with(fun(_, A, B) -> max(A, B) end, Peak, sample(Row))
    end, #{count => 0, bytes => 0, mailbox => 0, mailbox_bytes => 0, blocked => 0, overflow => 0}, rows(albedo_bus)).

activity_event(Id, Index, Size) ->
    Prefix = iolist_to_binary([<<"pressure:">>, Id, <<":">>, integer_to_binary(Index), <<":">>]),
    Remaining = max(0, min(256 - byte_size(Prefix), Size)),
    Scalar = case Size > 4096 of true -> <<240, 159, 152, 128>>; false -> <<"x">> end,
    Text = <<Prefix/binary, (binary:copy(Scalar, Remaining))/binary>>,
    Line = #{kind => <<"assistant">>, text => Text},
    json:encode(#{type => <<"activity">>, data => #{session_id => Id,
        cursor => #{generation => <<"AAAAAAAAAAAAAAAAAAAAAA">>, sequence => Index},
        status => #{phase => <<"idle">>, run_id => null,
            interrupt_requested => false, blocking_reason => null},
        current_progress => [], activity => #{lines => lists:duplicate(12, Line),
            output_scalars => Index, output_utf8_bytes => Index,
            observed_at => <<"2026-10-03T00:00:00Z">>,
            latest_input => null, latest_answer => null}}}).

publish(Ids, Start, Count, Size) ->
    lists:foreach(fun(Index) ->
        Id = lists:nth(1 + ((Index - 1) rem length(Ids)), Ids),
        albedo_bus:publish(iolist_to_binary(activity_event(Id, Index, Size)))
    end, lists:seq(Start, Start + Count - 1)),
    nil.

burst_event(_Id, Size) when Size > 1048576 ->
    %% Internal admission boundary: this oversized payload is deliberately not
    %% a valid public event and must never reach a socket.
    json:encode(#{type => <<"invalidate">>, data => #{padding => binary:copy(<<"x">>, Size)}});
burst_event(Id, Size) when Size =< 16 ->
    json:encode(#{type => <<"invalidate">>, data => #{session_ids => [Id],
        urls => [<<"/sessions/", Id/binary>>], scope_dirty => false}});
burst_event(Id, Size) -> activity_event(Id, 1, Size).

publish_batch(Ids, Published) ->
    Workers = [spawn_monitor(fun() ->
        publish([Id], Published div length(Ids) + 1, 12, 4096)
    end) || Id <- Ids],
    lists:foreach(fun({Worker, Monitor}) ->
        receive
            {'DOWN', Monitor, process, Worker, normal} -> ok;
            {'DOWN', Monitor, process, Worker, Reason} -> error({publisher_failed, Reason})
        after 10000 -> error(publisher_blocked)
        end
    end, Workers).

pressure_json(Ids) ->
    io_lib:format("~s", [json:encode(pressure(Ids, 0, measure()))]).

pressure(Ids, Published, Peak) when Published < 10000 ->
    publish_batch(Ids, Published),
    Current = measure(),
    Next = maps:merge_with(fun(_, A, B) -> max(A, B) end, Peak, Current),
    case maps:get(overflow, Current) > 0 andalso maps:get(blocked, Next) > 0 of
        true -> Next#{published => Published + 96, pressure => true};
        false ->
            %% Pace below a responsive subscriber's per-flush queue budget.
            receive after 150 -> ok end,
            pressure(Ids, Published + 96, Next)
    end;
pressure(_, Published, Peak) -> Peak#{published => Published, pressure => false}.

burst_json(Ids, Count, Size) ->
    [{_, {Owner, _, _, _}}] = rows(albedo_bus),
    %% Hold the real stream handler at a barrier while testing each budget.
    ok = sys:suspend(Owner),
    try
        Peak = lists:foldl(fun(_, Acc) ->
            [Id | _] = Ids,
            albedo_bus:publish(iolist_to_binary(burst_event(Id, Size))),
            maps:merge_with(fun(_, A, B) -> max(A, B) end, Acc, measure())
        end, measure(), lists:seq(1, Count)),
        json:encode(Peak)
    after sys:resume(Owner)
    end.

subscriptions_json() -> json:encode(#{subscribers => length(rows(albedo_bus)),
    queues => length(rows(albedo_bus_queues))}).

removed_json() -> removed(1000).
removed(0) -> subscriptions_json();
removed(Left) ->
    case {rows(albedo_bus), rows(albedo_bus_queues)} of
        {[], []} -> subscriptions_json();
        _ -> receive after 10 -> ok end, removed(Left - 1)
    end.

session_state(Id) ->
    {some, Session} = 'albedo@daemon@session':live(Id),
    {ok, Owner} = 'gleam@erlang@process':subject_owner(Session),
    sys:get_state(Owner).

wakes(wake) -> 1;
wakes(Tuple) when is_tuple(Tuple) -> wakes(tuple_to_list(Tuple));
wakes([Head | Tail]) -> wakes(Head) + wakes(Tail);
wakes(_) -> 0.

session_sample(Id) ->
    State = session_state(Id),
    Watchers = element(14, State),
    Samples = [case process_info(element(2, Watcher), messages) of
        undefined -> #{wakes => 0, blocked => 0};
        {messages, Messages} -> #{wakes => wakes(Messages), blocked => blocked(element(2, Watcher))}
    end || Watcher <- Watchers],
    Peak = lists:foldl(fun(Sample, Acc) ->
        maps:merge_with(fun(_, A, B) -> max(A, B) end, Acc, Sample)
    end, #{wakes => 0, blocked => 0}, Samples),
    Peak#{watchers => length(Watchers), sequence => element(12, State)}.

session_pressure_json(Id) -> json:encode(session_pressure(Id, 1500, #{})).
session_pressure(Id, Left, Peak) ->
    Sample = session_sample(Id),
    Next = maps:merge_with(fun(_, A, B) -> max(A, B) end, Peak, Sample),
    Complete = maps:get(blocked, Next) > 0 andalso not 'albedo@daemon@bus':is_running(Id),
    case Complete orelse Left =:= 0 of
        true -> Next;
        false -> receive after 10 -> ok end, session_pressure(Id, Left - 1, Next)
    end.

session_removed_json(Id) -> json:encode(session_removed(Id, 1000)).
session_removed(Id, Left) ->
    Sample = session_sample(Id),
    case maps:get(watchers, Sample) =:= 0 orelse Left =:= 0 of
        true -> Sample;
        false -> receive after 10 -> ok end, session_removed(Id, Left - 1)
    end.

%% The actor owns one projection regardless of subscriber count. Inspect that
%% bounded value rather than copying the worker's full durable argument state.
progress_json(Id) ->
    State = session_state(Id),
    Projection = lists:keyfind(projection, 1,
        [Value || Value <- tuple_to_list(State), is_tuple(Value)]),
    true = is_tuple(Projection),
    json:encode(#{projection_bytes => bytes(Projection),
        projection_size => erlang:external_size(Projection),
        watchers => length(element(14, State))}).

%% sys calls acknowledge suspension/resumption of the real session owner.
suspend_session_json(Id) ->
    {some, Session} = 'albedo@daemon@session':live(Id),
    {ok, Owner} = 'gleam@erlang@process':subject_owner(Session),
    ok = sys:suspend(Owner),
    json:encode(#{suspended => true}).

resume_session_json(Id) ->
    {some, Session} = 'albedo@daemon@session':live(Id),
    {ok, Owner} = 'gleam@erlang@process':subject_owner(Session),
    ok = sys:resume(Owner),
    json:encode(#{resumed => true}).

%% The ready file acknowledges the monitor before the HTTP client cancels.
worker_exit_json(Id, RunId, ReadyPath) ->
    State = session_state(Id),
    {some, Run} = 'albedo@daemon@turn':owner(element(9, State), RunId),
    Worker = element(3, Run),
    Monitor = monitor(process, Worker),
    true = is_process_alive(Worker),
    ok = file:write_file(ReadyPath, <<"monitor_ready">>),
    receive
        {'DOWN', Monitor, process, Worker, Reason} ->
            Classification = case Reason of
                normal -> <<"normal">>;
                killed -> <<"killed">>;
                _ -> <<"other">>
            end,
            json:encode(#{reason => Classification})
    after 30000 ->
        demonitor(Monitor, [flush]),
        error(worker_still_alive)
    end.

%% Hold a real owner across several timer ticks, then let the sweep encounter
%% its death. Calls are traced at the worker boundary, without reading registry
%% state or assuming where its maintenance field is stored.
maintenance_json(Id) ->
    {some, Session} = 'albedo@daemon@session':live(Id),
    {ok, Owner} = 'gleam@erlang@process':subject_owner(Session),
    Module = 'albedo@daemon@maintenance',
    {module, Module} = code:ensure_loaded(Module),
    erlang:suspend_process(Owner),
    erlang:trace_pattern({Module, run, 1}, true, [local]),
    erlang:trace(all, true, [call, {tracer, self()}]),
    try
        Worker = receive
            {trace, Pid, call, {Module, run, [_]}} -> Pid
        after 3000 -> error(maintenance_not_started)
        end,
        Monitor = monitor(process, Worker),
        Deadline = erlang:monotonic_time(millisecond) + 2000,
        Workers = maintenance_calls(Module, Deadline, [Worker]),
        exit(Owner, kill),
        Outcome = receive
            {'DOWN', Monitor, process, Worker, normal} -> <<"completed">>;
            {'DOWN', Monitor, process, Worker, Reason} -> error({sweep_failed, Reason})
        after 7000 -> error(maintenance_still_blocked)
        end,
        json:encode(#{admitted => length(lists:usort(Workers)), outcome => Outcome})
    after
        erlang:trace(all, false, [call]),
        erlang:trace_pattern({Module, run, 1}, false, [local]),
        catch erlang:resume_process(Owner)
    end.

maintenance_calls(Module, Deadline, Workers) ->
    Remaining = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {trace, Pid, call, {Module, run, [_]}} ->
            maintenance_calls(Module, Deadline, [Pid | Workers])
    after Remaining -> Workers
    end.
