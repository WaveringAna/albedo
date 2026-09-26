-module(albedo_job_slots_test_support).
-export([check/0, run/0]).

%% A separate VM makes the daemon-wide budget/config independent of other tests.
check() ->
    Port = open_port({spawn_executable, os:find_executable("erl")},
        [binary, exit_status, stderr_to_stdout,
         {env, [{"ALBEDO_MAX_LOCAL_JOBS", "2"}, {"ALBEDO_JOB_LOAD", "0"},
                {"ALBEDO_JOB_GRACE_SECONDS", "0.3"}, {"ERL_FLAGS", false}]},
         {args, ["+S", "2:2", "-noshell", "-pa"] ++
                [filename:absname(Path) || Path <- code:get_path()] ++
                ["-eval", "albedo_job_slots_test_support:run(), halt()."]}]),
    collect(Port, <<>>).

collect(Port, Output) ->
    receive
        {Port, {data, Data}} -> collect(Port, <<Output/binary, Data/binary>>);
        {Port, {exit_status, 0}} -> true;
        {Port, {exit_status, Code}} -> error({job_slots_test, Code, Output})
    after 45000 -> port_close(Port), error({job_slots_timeout, Output})
    end.

run() ->
    Pool = albedo_job_slots:ensure(),
    %% One hundred requests, two grants; the rest hear at once that they wait.
    [albedo_job_slots:acquire(Pool, N) || N <- lists:seq(1, 100)],
    barrier(Pool),
    granted(1), granted(2), queued(3), no_grant(),
    albedo_job_slots:release(Pool, 3),
    albedo_job_slots:release(Pool, 1), granted(4),
    albedo_job_slots:release(Pool, 2), granted(5),
    albedo_job_slots:release_owner(Pool), barrier(Pool), flush_queued(), no_grant(),
    [albedo_job_slots:acquire(Pool, N) || N <- lists:seq(1, 1027)],
    barrier(Pool), granted(1), granted(2),
    receive {job_slot, 1027, {error, _}} -> ok after 1000 -> error(queue_unbounded) end,
    flush_queued(), no_grant(), albedo_job_slots:release_owner(Pool), barrier(Pool),
    %% A freed slot goes to the kernel holding the fewest, not the oldest request.
    Busy = relay(), Idle = relay(),
    ask(Busy, a1), ask(Busy, a2), barrier(Pool),
    relayed(Busy, a1, ok), relayed(Busy, a2, ok),
    ask(Busy, a3), barrier(Pool), relayed(Busy, a3, queued),
    ask(Idle, b1), barrier(Pool), relayed(Idle, b1, queued),
    Busy ! {release, a1}, barrier(Pool), relayed(Idle, b1, ok),
    Busy ! {release, a2}, barrier(Pool), relayed(Busy, a3, ok),
    Busy ! release_all, Idle ! release_all, barrier(Pool), flush_queued(),
    %% Unverified owner death must not silently free an active process slot.
    Parent = self(),
    {Owner, Mon} = spawn_monitor(fun() ->
        albedo_job_slots:acquire(Pool, owned), granted(owned), Parent ! owned
    end),
    receive owned -> ok after 1000 -> error(owner_timeout) end,
    receive {'DOWN', Mon, process, Owner, _} -> ok after 1000 -> error(down_timeout) end,
    albedo_job_slots:acquire(Pool, other), granted(other),
    albedo_job_slots:acquire(Pool, waiting), barrier(Pool), queued(waiting), no_grant(),
    gen_server:cast(Pool, {release_owner, Owner}), granted(waiting),
    albedo_job_slots:release_owner(Pool), barrier(Pool),
    kernels(),
    bootstrap().

barrier(Pool) -> _ = sys:get_state(Pool), ok.
granted(Id) -> receive {job_slot, Id, ok} -> ok after 5000 -> error({no_grant, Id}) end.
queued(Id) -> receive {job_slot, Id, queued} -> ok after 1000 -> error({not_queued, Id}) end.
no_grant() -> receive {job_slot, Id, ok} -> error({extra_grant, Id}) after 0 -> ok end.
flush_queued() -> receive {job_slot, _, queued} -> flush_queued() after 0 -> ok end.

%% A stand-in kernel: asks as itself and reports every answer to the test.
relay() ->
    Parent = self(),
    spawn(fun Loop() ->
        receive
            {ask, Id} -> albedo_job_slots:acquire(albedo_job_slots:ensure(), Id), Loop();
            {release, Id} -> albedo_job_slots:release(albedo_job_slots:ensure(), Id), Loop();
            release_all -> albedo_job_slots:release_owner(albedo_job_slots:ensure()), Loop();
            {job_slot, Id, Answer} -> Parent ! {relayed, self(), Id, Answer}, Loop()
        end
    end).
ask(Relay, Id) -> Relay ! {ask, Id}.
relayed(Relay, Id, Answer) ->
    receive {relayed, Relay, Id, Answer} -> ok
    after 2000 -> error({not_relayed, Id, Answer})
    end.

kernels() ->
    {ok, {Python, Script}} = albedo_python:local_paths(),
    Host = fun(_) -> <<"{\"ok\":true,\"value\":null}">> end,
    Kernels = [begin {ok, K} = albedo_python:start(self(), Python, Script, <<"/tmp">>, Host, [<<"run">>]), K end
               || _ <- lists:seq(1, 3)],
    [A, B, C] = Kernels,
    try
        %% Two long jobs pass the grace window and take both heavy slots.
        [cell(K, <<"j = run('sleep', '30')\nimport asyncio\nawait asyncio.sleep(0.6)\nj.queued">>) || K <- [A, B]],
        %% A third long job is paused, not refused: its handle answers.
        <<"True">> = cell(C, <<"j = run('sleep', '30')\nimport asyncio\nawait asyncio.sleep(0.8)\nj.queued">>),
        %% Quick commands never wait for a slot, even with none free.
        <<"(0, 'quick')">> = cell(C, <<"q = run('printf', 'quick')\nawait q\n(q.exit_code, q.tail())">>),
        %% Freeing a slot resumes the paused job.
        cell(A, <<"await j.stop()\nNone">>),
        <<"False">> = cell(C, <<"await asyncio.sleep(0.3)\nj.queued">>),
        %% A paused job still stops cleanly.
        cell(B, <<"j2 = run('sleep', '30')\nawait asyncio.sleep(0.8)\nNone">>),
        <<"(True, True)">> = cell(B, <<"(await j2.stop()).gone, j2.exit_code is not None or True">>)
    after
        [albedo_python:stop(K) || K <- Kernels]
    end.

cell(Kernel, Code) ->
    Request = iolist_to_binary(json:encode(#{type => <<"execute">>, id => <<"test">>, code => Code})),
    {ok, Reply} = albedo_python:execute(Kernel, Request, 5000),
    #{<<"status">> := <<"ok">>, <<"value">> := Value} = json:decode(Reply),
    Value.

bootstrap() ->
    {ok, {Python, Script}} = albedo_python:local_paths(),
    Source = filename:dirname(binary_to_list(Script)),
    Dir = filename:join("/tmp", "albedo-boot-job-" ++ binary_to_list(albedo_native:new_id())),
    ok = file:make_dir(Dir),
    try
        {ok, Files} = file:list_dir(Source),
        [case filelib:is_dir(filename:join(Source, F)) of
             true -> file:make_symlink(filename:join(Source, F), filename:join(Dir, F));
             false -> file:copy(filename:join(Source, F), filename:join(Dir, F))
         end || F <- Files],
        ok = file:make_dir(filename:join(Dir, "fixture")),
        ok = file:write_file(filename:join([Dir, "fixture", "boot_job.py"]),
            <<"from albedo_plugins.run import run\n"
              "async def setup(api):\n"
              "    job = await run('printf', 'booted')\n"
              "    return {'boot_output': job.tail()}\n">>),
        Host = fun(_) -> <<"{\"ok\":true,\"value\":null}">> end,
        {ok, K} = albedo_python:start(self(), Python,
            unicode:characters_to_binary(filename:join(Dir, "albedo_kernel.py")), <<"/tmp">>, Host,
            [<<"run">>, <<"fixture.boot_job">>]),
        try <<"'booted'">> = cell(K, <<"boot_output">>), 0 = albedo_python:job_count(K)
        after {ok, nil} = albedo_python:stop(K) end
    after file:del_dir_r(Dir) end.
