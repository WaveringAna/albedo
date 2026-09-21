-module(albedo_live_coding).
-export([take_key/0, now/0, with_runtime/2]).
take_key() ->
    Value = albedo_openai_bench:env(<<"ALBEDO_BENCH_KEY">>),
    os:unsetenv("ALBEDO_BENCH_KEY"),
    Value.
now() -> erlang:monotonic_time(millisecond).
with_runtime(Host, Run) ->
    try Run() after 'albedo@harness@runtime':stop(Host) end.
