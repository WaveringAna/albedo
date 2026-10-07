-module(albedo_openai_bench).
-export([env/1, measure/1, text/1]).

env(Name) ->
    case os:getenv(binary_to_list(Name)) of
        false -> <<>>;
        Value -> unicode:characters_to_binary(Value)
    end.

text(Bytes) when Bytes > 0 ->
    case get(first_text) of undefined -> put(first_text, erlang:monotonic_time(microsecond)); _ -> ok end,
    put(text_bytes, get(text_bytes) + Bytes),
    put(text_chunks, get(text_chunks) + 1),
    nil;
text(_) -> nil.

measure(Run) ->
    Owner = self(),
    Baseline = erlang:memory(binary),
    {Pid, Ref} = spawn_monitor(fun() ->
        put(text_bytes, 0), put(text_chunks, 0),
        Start = erlang:monotonic_time(microsecond),
        Result = Run(),
        End = erlang:monotonic_time(microsecond),
        First = case get(first_text) of undefined -> none; Time -> {some, (Time - Start) / 1000} end,
        {reductions, Reductions} = process_info(self(), reductions),
        {memory, Memory} = process_info(self(), memory),
        Owner ! {self(), measured, Result, (End - Start) / 1000, First,
            get(text_bytes), get(text_chunks), Memory, Reductions},
        receive release -> ok end
    end),
    sample(Pid, Ref, Baseline, 0, Baseline).

sample(Pid, Ref, Baseline, PeakProcess, PeakBinary) ->
    receive
        {Pid, measured, Result, Elapsed, First, Bytes, Chunks, Memory, Reductions} ->
            Binary = erlang:memory(binary),
            Pid ! release,
            demonitor(Ref, [flush]),
            {Result, {metrics, Elapsed, First, Bytes, Chunks,
                max(PeakProcess, Memory), max(0, max(PeakBinary, Binary) - Baseline), Reductions}};
        {'DOWN', Ref, process, Pid, Reason} -> error({benchmark_worker_crashed, Reason})
    after 10 ->
        Memory = case process_info(Pid, memory) of {memory, M} -> M; undefined -> 0 end,
        sample(Pid, Ref, Baseline, max(PeakProcess, Memory), max(PeakBinary, erlang:memory(binary)))
    end.

