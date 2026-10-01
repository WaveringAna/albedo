%% Count payload decodes on the preparation caller without production metrics.
-module(albedo_lcm_preparation_test_support).
-export([count_decodes/2]).

count_decodes(Owner, Run) ->
    Processes = lists:usort([self(), Owner]),
    Patterns = [{albedo_conversation, unpack, 2}, {albedo_conversation, unpack_fit, 2}],
    Tracer = spawn(fun() -> collect(0, none) end),
    lists:foreach(fun(Pattern) -> erlang:trace_pattern(Pattern, true, [local]) end, Patterns),
    lists:foreach(fun(Pid) -> erlang:trace(Pid, true, [call, {tracer, Tracer}]) end, Processes),
    try
        Value = Run(),
        Tracer ! {count, self(), Processes},
        receive {decode_count, Count} -> {Value, Count} end
    after
        lists:foreach(fun(Pid) -> erlang:trace(Pid, false, [call]) end, Processes),
        lists:foreach(fun(Pattern) -> erlang:trace_pattern(Pattern, false, [local]) end, Patterns),
        exit(Tracer, kill)
    end.

%% The tracer drains its own delivery markers before answering. Keep call
%% tracing enabled until the markers arrive, so queued events are retained.
collect(Count, Finish) ->
    receive
        {trace, _, call, {albedo_conversation, Function, [_, _]}}
                when Function =:= unpack; Function =:= unpack_fit ->
            collect(Count + 1, Finish);
        {count, Reply, Processes} ->
            Refs = [erlang:trace_delivered(Pid) || Pid <- Processes],
            collect(Count, {Reply, Refs});
        {trace_delivered, _, Ref} ->
            {Reply, Refs} = Finish,
            case lists:delete(Ref, Refs) of
                [] -> Reply ! {decode_count, Count}, collect(Count, none);
                Pending -> collect(Count, {Reply, Pending})
            end;
        _ -> collect(Count, Finish)
    end.
