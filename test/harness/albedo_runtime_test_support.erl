-module(albedo_runtime_test_support).
-export([temporary_database/0, cleanup/1, temporary_workspace/0, cleanup_workspace/1,
         kernel_memory/1, catalog_does_not_block/3, catalog_forget_while_blocked/3,
         hold_preparation/2, capture_during_preparation/3]).
temporary_workspace() ->
    Path = filename:join(os:getenv("TMPDIR", "/tmp"),
                         "runtime-workspace-" ++ binary_to_list(albedo_native:new_id())),
    ok = file:make_dir(Path),
    unicode:characters_to_binary(Path).
cleanup_workspace(Path) ->
    _ = file:del_dir_r(Path),
    nil.
temporary_database() ->
    unicode:characters_to_binary(filename:join(os:getenv("TMPDIR", "/tmp"), "albedo-" ++ binary_to_list(albedo_native:new_id()) ++ ".sqlite" )).
cleanup(Path) ->
    lists:foreach(fun(Suffix) -> file:delete(<<Path/binary, Suffix/binary>>) end,
                  [<<>>, <<"-wal">>, <<"-shm">>]),
    _ = file:del_dir_r(<<Path/binary, ".backup">>),
    nil.

%% A barrier followed by GC measures retained ownership, not transient boot garbage.
kernel_memory({session, _, _, Kernel, _, _, _, _, _}) ->
    _ = albedo_python:events(Kernel),
    true = erlang:garbage_collect(Kernel),
    {memory, Bytes} = erlang:process_info(Kernel, memory),
    Bytes.

%% A catalog worker waiting on the real ledger must not own the runtime loop.
catalog_does_not_block(Runtime, Home, Id) ->
    Store = 'albedo@harness@runtime':ledger(Runtime),
    Owner = 'albedo@daemon@store':owner(Store),
    erlang:suspend_process(Owner),
    Parent = self(),
    Worker = spawn_link(fun() ->
        Result = 'albedo@harness@runtime':observe_catalog(Runtime, Home, Id),
        Parent ! {catalog_complete, self(), Result}
    end),
    try
        await_store_query(Owner, erlang:monotonic_time(millisecond) + 3000),
        Reader = spawn_link(fun() ->
            Loaded = 'albedo@harness@runtime':loaded_sessions(Runtime),
            Parent ! {loaded_complete, self(), Loaded}
        end),
        Responsive = receive
            {loaded_complete, Reader, _} -> true
        after 1000 -> false
        end,
        erlang:resume_process(Owner),
        Completed = receive
            {catalog_complete, Worker, {ok, _}} -> true;
            {catalog_complete, Worker, {error, _}} -> false
        after 10000 -> false
        end,
        {Responsive, Completed}
    after
        catch erlang:resume_process(Owner)
    end.

%% The catalog began against a prepared composition that is removed while its
%% discovery is held. Its eventual response must observe that newer ownership.
catalog_forget_while_blocked(Runtime, Home, Id) ->
    Store = 'albedo@harness@runtime':ledger(Runtime),
    Owner = 'albedo@daemon@store':owner(Store),
    erlang:suspend_process(Owner),
    Parent = self(),
    Worker = spawn_link(fun() ->
        Result = 'albedo@harness@runtime':observe_catalog(Runtime, Home, Id),
        Parent ! {catalog_complete, self(), Result}
    end),
    try
        await_store_query(Owner, erlang:monotonic_time(millisecond) + 3000),
        'albedo@harness@runtime':forget_session(Runtime, Id),
        erlang:resume_process(Owner),
        receive
            {catalog_complete, Worker, Result} -> Result
        after 10000 -> error(catalog_did_not_complete)
        end
    after
        catch erlang:resume_process(Owner)
    end.

await_store_query(Owner, Deadline) ->
    case process_info(Owner, message_queue_len) of
        {message_queue_len, N} when N > 0 -> ok;
        _ ->
            case erlang:monotonic_time(millisecond) < Deadline of
                true -> receive after 10 -> ok end, await_store_query(Owner, Deadline);
                false -> error(catalog_did_not_query_store)
            end
    end.

%% The real composition worker calls this context loader. Only an explicit
%% release lets it finish; no process state or runtime messages are injected.
hold_preparation(Parent, Workspace) ->
    Parent ! {preparation_held, self(), Workspace},
    receive
        release_preparation -> {ok, <<>>}
    after 20000 -> {error, <<"preparation release was not received">>}
    end.

capture_during_preparation(Runtime, Session, Requests) ->
    Parent = self(),
    %% Fixture startup follows peek_commands' deadline, not a latency assertion.
    Deadline = erlang:monotonic_time(millisecond) + 15000,
    %% Inspect only the public runtime handle's subject, never actor State.
    {ok, Owner} = 'gleam@erlang@process':subject_owner(element(2, Runtime)),
    Callers = [spawn(fun() ->
        erlang:trace(self(), true, [send, {tracer, Parent}]),
        Result = try 'albedo@harness@runtime':peek_commands(Runtime, Id, Workspace)
                 catch Class:Reason -> {error, {preparation_caller_failed, Class, Reason}}
                 end,
        erlang:trace(self(), false, [send]),
        Parent ! {preparation_complete, self(), Result}
    end) || {Id, Workspace} <- Requests],
    try
        await_preparation_requests(Callers, Owner, Deadline),
        %% All actual request sends precede this public owner roundtrip.
        _ = 'albedo@harness@runtime':loaded_sessions(Runtime),
        await_preparation_hold(Deadline),
        Captured = 'albedo@daemon@session':capture(Session),
        Completed = release_preparations(Callers, true),
        {Captured, Completed}
    catch Class:Reason:Stack ->
        %% Failure during setup must also release callbacks and drain callers.
        _ = release_preparations(Callers, true),
        erlang:raise(Class, Reason, Stack)
    end.

await_preparation_requests([], _Owner, _Deadline) -> ok;
await_preparation_requests(Callers, Owner, Deadline) ->
    receive
        {trace, Caller, send, _, Owner} ->
            await_preparation_requests(lists:delete(Caller, Callers), Owner, Deadline);
        {preparation_complete, _, _} = Completion ->
            self() ! Completion,
            error({preparation_completed_before_admission, Completion})
    after max(0, Deadline - erlang:monotonic_time(millisecond)) ->
        error(preparation_request_was_not_sent)
    end.

await_preparation_hold(Deadline) ->
    receive
        {preparation_held, _, _} = Held ->
            %% Retain the hold so cleanup releases it after synchronous capture.
            self() ! Held;
        {preparation_complete, _, _} = Completion ->
            self() ! Completion,
            error({preparation_completed_before_context_hold, Completion})
    after max(0, Deadline - erlang:monotonic_time(millisecond)) ->
        error(preparation_context_did_not_start_before_call_deadline)
    end.

release_preparations([], Completed) -> Completed;
release_preparations(Callers, Completed) ->
    receive
        {preparation_held, Worker, _} ->
            Worker ! release_preparation,
            release_preparations(Callers, Completed);
        {preparation_complete, Caller, Result} ->
            Successful = case Result of {ok, _} -> true; _ -> false end,
            release_preparations(lists:delete(Caller, Callers), Completed andalso Successful);
        {trace, _, send, _, _} -> release_preparations(Callers, Completed)
    after 10000 -> false
    end.
