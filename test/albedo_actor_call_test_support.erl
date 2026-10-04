-module(albedo_actor_call_test_support).
-export([monitor_state/0]).

monitor_state() ->
    {monitors, Monitors} = process_info(self(), monitors),
    {messages, Messages} = process_info(self(), messages),
    Downs = [Ref || {'DOWN', Ref, process, _, _} <- Messages],
    {length(Monitors), length(Downs)}.
