-module(albedo_openai_rate_bench).
-export([env/2, token/0, measure/3]).

%% Helpers for manual/stream_rate_benchmark: one stream against
%% test/manual/mock_openai_server.py, measured from the calling process.

env(Name, Default) ->
    case os:getenv(binary_to_list(Name)) of
        false -> Default;
        Value -> unicode:characters_to_binary(Value)
    end.

%% Called from the stream callback for every text delta.
token() ->
    put(arrivals, [os:system_time(nanosecond) | get(arrivals)]),
    nil.

%% Runs Run in a fresh process; returns {Result, Metrics} where Metrics is a
%% list of {Name, Number} pairs. VM CPU is microstate accounting over every
%% scheduler and thread, so the connection process and the poller count too.
measure(Port, Tokens, Run) ->
    {ok, _} = application:ensure_all_started(gun),
    Owner = self(),
    erlang:garbage_collect(),
    {Reductions0, _} = statistics(reductions),
    {Runtime0, _} = statistics(runtime),
    msacc:start(),
    msacc:reset(),
    {Pid, Ref} = spawn_monitor(fun() ->
        put(arrivals, []),
        Start = erlang:monotonic_time(microsecond),
        Result = Run(),
        End = erlang:monotonic_time(microsecond),
        {reductions, Reductions} = process_info(self(), reductions),
        {memory, Memory} = process_info(self(), memory),
        Owner ! {self(), done, Result, End - Start, Reductions, Memory, get(arrivals)}
    end),
    receive
        {Pid, done, Result, Elapsed, Worker, Memory, Arrivals} ->
            Stats = msacc:stats(),
            Runtime = msacc:stats(system_runtime, Stats),
            msacc:stop(),
            {Runtime1, _} = statistics(runtime),
            case os:getenv("ALBEDO_BENCH_MSACC") of false -> ok; _ -> msacc:print(Stats) end,
            {Reductions1, _} = statistics(reductions),
            demonitor(Ref, [flush]),
            Received = length(Arrivals),
            Latency = latency(Port, lists:reverse(Arrivals)),
            Per = fun(X) -> X / max(1, Tokens) end,
            {Result, [{Name, float(Value)} || {Name, Value} <- [
                {<<"tokens">>, Received},
                {<<"wall_ms">>, Elapsed / 1000},
                {<<"tok_per_s">>, Received / (Elapsed / 1000000)},
                {<<"vm_cpu_us_per_tok">>, Per(Runtime)},
                {<<"vm_cpu_pct">>, 100 * Runtime / Elapsed},
                {<<"os_cpu_us_per_tok">>, Per(1000 * (Runtime1 - Runtime0))},
                {<<"worker_reds_per_tok">>, Per(Worker)},
                {<<"vm_reds_per_tok">>, Per(Reductions1 - Reductions0)},
                {<<"worker_memory_kb">>, Memory / 1024}
                | Latency
            ]]};
        {'DOWN', Ref, process, Pid, Reason} -> error({benchmark_worker_crashed, Reason})
    end.

%% Send-to-callback latency per token, from the mock's send times.
latency(Port, Arrivals) ->
    Sent = timings(Port),
    case length(Sent) =:= length(Arrivals) of
        false -> [{<<"latency_mismatch">>, length(Sent)}];
        true ->
            Sorted = lists:sort([(A - S) / 1000 || {S, A} <- lists:zip(Sent, Arrivals)]),
            [{<<"lat_p50_us">>, pct(Sorted, 0.50)}, {<<"lat_p99_us">>, pct(Sorted, 0.99)},
             {<<"lat_max_us">>, lists:last(Sorted)}]
    end.

pct(Sorted, P) -> lists:nth(max(1, round(P * length(Sorted))), Sorted).

timings(Port) ->
    {ok, Socket} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}]),
    ok = gen_tcp:send(Socket, <<"GET /timings HTTP/1.1\r\nhost: mock\r\n\r\n">>),
    Response = read_all(Socket, []),
    [_, Body] = binary:split(Response, <<"\r\n\r\n">>),
    json:decode(Body).

read_all(Socket, Acc) ->
    case gen_tcp:recv(Socket, 0, 5000) of
        {ok, Data} -> read_all(Socket, [Data | Acc]);
        {error, closed} -> iolist_to_binary(lists:reverse(Acc))
    end.
