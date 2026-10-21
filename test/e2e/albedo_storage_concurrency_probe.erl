%% Hold a real connection until the HTTP scenario explicitly releases it.
-module(albedo_storage_concurrency_probe).
-export([hold_snapshot/1, hold_writer/1, release/0, reader_cache_growth/0]).

hold_snapshot(Path) -> start(snapshot, Path).
hold_writer(Path) -> start(writer, Path).

start(Kind, Path) ->
    Parent = self(),
    {Pid, Monitor} = spawn_monitor(fun() -> gate(Kind, Path, Parent) end),
    true = register(albedo_storage_concurrency_gate, Pid),
    receive
        {ready, Pid} -> demonitor(Monitor, [flush]), <<"ready">>;
        {'DOWN', Monitor, process, Pid, Reason} -> error({gate_failed, Reason})
    after 10000 -> exit(Pid, kill), error(gate_start_timeout)
    end.

release() ->
    case whereis(albedo_storage_concurrency_gate) of
        undefined -> <<"absent">>;
        Pid -> Pid ! release, <<"released">>
    end.

gate(Kind, Path, Parent) ->
    Gate = self(),
    Ref = make_ref(),
    Ledger = ledger(),
    Callback = fun(Db) ->
        {ok, nil} = 'albedo@daemon@store':exec(Db, <<"SELECT COUNT(*) FROM sessions">>),
        Gate ! {entered, self()},
        receive {release, Ref} -> nil after 60000 -> error(gate_timeout) end
    end,
    {Worker, Monitor} = spawn_monitor(fun() ->
        run(Kind, Ledger, Callback)
    end),
    receive
        {entered, Owner} ->
            ok = file:write_file(Path, <<"ready\n">>),
            Parent ! {ready, self()},
            receive release -> Owner ! {release, Ref} end;
        {'DOWN', Monitor, process, Worker, Reason} -> error({callback_failed, Reason})
    end,
    receive
        {'DOWN', Monitor, process, Worker, normal} -> ok;
        {'DOWN', Monitor, process, Worker, Reason1} -> error({callback_failed, Reason1})
    end,
    file:delete(Path).

run(snapshot, Ledger, Callback) ->
    'albedo@daemon@store':snapshot(Ledger, Callback);
run(writer, Ledger, Callback) ->
    'albedo@daemon@store':query(Ledger, fun(Db) ->
        {ok, nil} = 'albedo@daemon@store':exec(Db, <<"BEGIN IMMEDIATE">>),
        {ok, nil} = 'albedo@daemon@store':exec(Db, <<"UPDATE sessions SET title='uncommitted storage gate'">>),
        Callback(Db),
        {ok, nil} = 'albedo@daemon@store':exec(Db, <<"ROLLBACK">>)
    end).

%% Measure cache growth after schema loading, not the writer's fixture allocation.
reader_cache_growth() ->
    Ledger = ledger(),
    {ok, nil} = 'albedo@daemon@store':query(Ledger, fun(Db) ->
        'albedo@daemon@store':exec(Db, <<"CREATE TABLE storage_cache_fixture(payload BLOB); WITH RECURSIVE ids(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM ids WHERE x<100000) INSERT INTO storage_cache_fixture SELECT zeroblob(128) FROM ids;">>)
    end),
    [begin
        {ok, _} = 'albedo@daemon@store':snapshot(Ledger, fun(Db) ->
            sqlight_ffi:query(<<"SELECT name FROM sqlite_schema">>, Db, [])
        end)
    end || _ <- lists:seq(1, 12)],
    #{pagecache_overflow := #{used := Before}} = esqlite3:status(),
    [begin
        {ok, [{12800000}]} = 'albedo@daemon@store':snapshot(Ledger, fun(Db) ->
            sqlight_ffi:query(<<"SELECT SUM(length(payload)) FROM storage_cache_fixture">>, Db, [])
        end)
    end || _ <- lists:seq(1, 12)],
    #{pagecache_overflow := #{used := After}} = esqlite3:status(),
    json:encode(#{before => Before, after_read => After, growth => After-Before}).

ledger() ->
    [Name] = [Candidate || Candidate <- registered(),
        lists:prefix("albedo_registry", atom_to_list(Candidate))],
    Registry = 'gleam@erlang@process':named_subject(Name),
    {ok, Runtime} = 'albedo@daemon@registry':host(Registry),
    'albedo@harness@runtime':ledger(Runtime).
