-module(albedo_openai_rate_bench).
-export([env/2, token/0, measure/3, trust/1]).

%% Helpers for manual/stream_rate_benchmark: one stream against
%% test/manual/mock_openai_server.py, measured from the calling process.

env(Name, Default) ->
    case os:getenv(binary_to_list(Name)) of
        false -> Default;
        Value -> unicode:characters_to_binary(Value)
    end.

%% Trusts the CA in File for this run, for a mock serving https.
trust(<<>>) -> nil;
trust(File) ->
    ok = public_key:cacerts_load(File),
    nil.

%% Called from the stream callback for every text delta.
token() ->
    put(arrivals, [os:system_time(nanosecond) | get(arrivals)]),
    nil.

%% Runs Run in a fresh process; returns {Result, Metrics} where Metrics is a
%% list of {Name, Number} pairs. VM CPU is microstate accounting over every
%% scheduler and thread, so the connection process and the poller count too.
measure(Origin, Tokens, Run) ->
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
            Latency = latency(Origin, lists:reverse(Arrivals)),
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
latency(Origin, Arrivals) ->
    Sent = timings(Origin),
    case length(Sent) =:= length(Arrivals) of
        _ when Arrivals =:= [] -> [];
        false -> [{<<"latency_mismatch">>, length(Sent)}];
        true ->
            Sorted = lists:sort([(A - S) / 1000 || {S, A} <- lists:zip(Sent, Arrivals)]),
            [{<<"lat_p50_us">>, pct(Sorted, 0.50)}, {<<"lat_p99_us">>, pct(Sorted, 0.99)},
             {<<"lat_max_us">>, lists:last(Sorted)}]
    end.

pct(Sorted, P) -> lists:nth(max(1, round(P * length(Sorted))), Sorted).

timings(Origin) ->
    #{scheme := Scheme, host := Host, port := Port} = uri_string:parse(Origin),
    Options = [binary, {active, false}],
    {Module, {ok, Socket}} = case Scheme of
        <<"https">> -> {ssl, ssl:connect(binary_to_list(Host), Port, [{verify, verify_none} | Options])};
        <<"http">> -> {gen_tcp, gen_tcp:connect(binary_to_list(Host), Port, Options)}
    end,
    ok = Module:send(Socket, <<"GET /timings HTTP/1.1\r\nhost: mock\r\n\r\n">>),
    Body = response_body(Module, Socket, <<>>),
    Module:close(Socket),
    json:decode(Body).

response_body(Module, Socket, Read) ->
    {ok, Bytes} = Module:recv(Socket, 0, 5000),
    Response = <<Read/binary, Bytes/binary>>,
    case binary:split(Response, <<"\r\n\r\n">>) of
        [Head, Body] ->
            {match, [Length]} = re:run(Head, <<"content-length: (\\d+)">>, [caseless, {capture, all_but_first, binary}]),
            case byte_size(Body) >= binary_to_integer(Length) of
                true -> Body;
                false -> response_body(Module, Socket, Response)
            end;
        [_] -> response_body(Module, Socket, Response)
    end.
