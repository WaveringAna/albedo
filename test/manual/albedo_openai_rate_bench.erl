-module(albedo_openai_rate_bench).
-export([env/2, token/0, measure/2, trust/1]).

%% Helpers for manual/stream_rate_benchmark: streams against
%% test/manual/mock_openai_server.py, each in its own process, measured
%% together.

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

%% Called from the stream callback for every text or argument delta.
token() ->
    put(arrivals, [os:system_time(nanosecond) | get(arrivals)]),
    nil.

%% Runs every {StreamId, Run} at once, each in a fresh process; returns
%% {Results, Metrics} where Metrics is a list of {Name, Number} pairs, per
%% token across all streams. VM CPU is microstate accounting over every
%% scheduler and thread, so the poller and the pool count too.
measure(Origin, Runs) ->
    Owner = self(),
    erlang:garbage_collect(),
    {Reductions0, _} = statistics(reductions),
    {Runtime0, _} = statistics(runtime),
    msacc:start(),
    msacc:reset(),
    Start = erlang:monotonic_time(microsecond),
    Workers = [{Id, spawn_monitor(fun() ->
        put(arrivals, []),
        Result = Run(),
        {reductions, Reductions} = process_info(self(), reductions),
        {memory, Memory} = process_info(self(), memory),
        Owner ! {self(), done, Result, Reductions, Memory, get(arrivals)}
    end)} || {Id, Run} <- Runs],
    Done = [receive
        {Pid, done, Result, Reductions, Memory, Arrivals} ->
            demonitor(Ref, [flush]),
            {Id, Result, Reductions, Memory, lists:reverse(Arrivals)};
        {'DOWN', Ref, process, Pid, Reason} -> error({benchmark_worker_crashed, Reason})
    end || {Id, {Pid, Ref}} <- Workers],
    Elapsed = erlang:monotonic_time(microsecond) - Start,
    Stats = msacc:stats(),
    Runtime = msacc:stats(system_runtime, Stats),
    msacc:stop(),
    {Runtime1, _} = statistics(runtime),
    case os:getenv("ALBEDO_BENCH_MSACC") of false -> ok; _ -> msacc:print(Stats) end,
    {Reductions1, _} = statistics(reductions),
    Received = lists:sum([length(Arrivals) || {_, _, _, _, Arrivals} <- Done]),
    Latency = latency([{timings(Origin, Id), Arrivals} || {Id, _, _, _, Arrivals} <- Done]),
    Per = fun(X) -> X / max(1, Received) end,
    Metrics = [
        {<<"tokens">>, Received},
        {<<"wall_ms">>, Elapsed / 1000},
        {<<"tok_per_s">>, Received / (Elapsed / 1000000)},
        {<<"vm_cpu_us_per_tok">>, Per(Runtime)},
        {<<"vm_cpu_pct">>, 100 * Runtime / Elapsed},
        {<<"os_cpu_us_per_tok">>, Per(1000 * (Runtime1 - Runtime0))},
        {<<"worker_reds_per_tok">>, Per(lists:sum([R || {_, _, R, _, _} <- Done]))},
        {<<"vm_reds_per_tok">>, Per(Reductions1 - Reductions0)},
        {<<"worker_memory_kb">>, lists:max([M || {_, _, _, M, _} <- Done]) / 1024}
        | Latency
    ],
    {[Result || {_, Result, _, _, _} <- Done], [{Name, float(Value)} || {Name, Value} <- Metrics]}.

%% Send-to-callback latency per token, from each stream's send times.
latency(Streams) ->
    case lists:all(fun({Sent, Arrivals}) -> length(Sent) =:= length(Arrivals) end, Streams) of
        false -> [{<<"latency_mismatch">>, 1}];
        true ->
            case lists:sort([(A - S) / 1000 || {Sent, Arrivals} <- Streams,
                                                {S, A} <- lists:zip(Sent, Arrivals)]) of
                [] -> [];
                Sorted ->
                    [{<<"lat_p50_us">>, pct(Sorted, 0.50)}, {<<"lat_p99_us">>, pct(Sorted, 0.99)},
                     {<<"lat_max_us">>, lists:last(Sorted)}]
            end
    end.

pct(Sorted, P) -> lists:nth(max(1, round(P * length(Sorted))), Sorted).

timings(Origin, Id) ->
    #{scheme := Scheme, host := Host, port := Port} = uri_string:parse(Origin),
    Options = [binary, {active, false}],
    {Module, {ok, Socket}} = case Scheme of
        <<"https">> -> {ssl, ssl:connect(binary_to_list(Host), Port, [{verify, verify_none} | Options])};
        <<"http">> -> {gen_tcp, gen_tcp:connect(binary_to_list(Host), Port, Options)}
    end,
    ok = Module:send(Socket, [<<"GET /timings/">>, Id, <<" HTTP/1.1\r\nhost: mock\r\n\r\n">>]),
    Body = response_body(Module, Socket, <<>>),
    Module:close(Socket),
    json:decode(Body).

response_body(Module, Socket, Read) ->
    {ok, Bytes} = Module:recv(Socket, 0, 5000),
    Response = <<Read/binary, Bytes/binary>>,
    case binary:split(Response, <<"\r\n\r\n">>) of
        [Head, Body] ->
            {match, [Length]} = re:run(Head, <<"content-length: (\\d+)">>,
                                       [caseless, {capture, all_but_first, binary}]),
            case byte_size(Body) >= binary_to_integer(Length) of
                true -> Body;
                false -> response_body(Module, Socket, Response)
            end;
        [_] -> response_body(Module, Socket, Response)
    end.
