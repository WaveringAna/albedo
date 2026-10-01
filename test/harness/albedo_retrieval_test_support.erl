%% BEAM calls and returned rows expose bounded work that E2E cannot measure.
-module(albedo_retrieval_test_support).
-export([measure/2]).

measure(Owner, Run) ->
    %% EUnit's inherited inparallel mode can overlap tests from this module.
    %% Legacy trace patterns are VM-wide, so measurements must not disable
    %% one another's patterns while a different test is still running.
    global:trans({?MODULE, self()}, fun() -> measure_locked(Owner, Run) end, [node()]).

measure_locked(Owner, Run) ->
    Processes = lists:usort([self(), Owner]),
    Patterns = [
        {'albedo@harness@search', pages, 3},
        {'albedo@daemon@conversation', read_input, 2},
        {'albedo@daemon@conversation', sourced_entry, 3}
    ],
    Rows = {'albedo@daemon@store', rows, 4},
    lists:foreach(fun({Module, _, _}) -> {module, Module} = code:ensure_loaded(Module) end, [Rows | Patterns]),
    Tracer = spawn(fun() -> collect({counts, 0, 0, 0, 0, 0, #{}}, none) end),
    lists:foreach(fun(Pattern) -> erlang:trace_pattern(Pattern, true, [local]) end, Patterns),
    erlang:trace_pattern(Rows, [{'_', [], [{return_trace}]}], [local]),
    lists:foreach(fun(Pid) -> erlang:trace(Pid, true, [call, {tracer, Tracer}]) end, Processes),
    try
        Value = Run(),
        Tracer ! {result, self(), Processes},
        receive {measurement, Counts} -> {Value, Counts} end
    after
        lists:foreach(fun(Pid) -> erlang:trace(Pid, false, [call]) end, Processes),
        lists:foreach(fun(Pattern) -> erlang:trace_pattern(Pattern, false, [local]) end, [Rows | Patterns]),
        exit(Tracer, kill)
    end.

%% Consume delivery markers in the same mailbox as trace events before
%% reporting counts, while call tracing remains enabled.
collect(State, Finish) ->
    receive
        {result, Reply, Processes} ->
            Refs = [erlang:trace_delivered(Pid) || Pid <- Processes],
            collect(State, {Reply, Refs});
        {trace_delivered, _, Ref} ->
            {Reply, Refs} = Finish,
            case lists:delete(Ref, Refs) of
                [] ->
                    {counts, Pages, Decoded, Sources, Nodes, Kept, _} = State,
                    Reply ! {measurement, {counts, Pages, Decoded, Sources, Nodes, Kept}},
                    collect(State, none);
                Pending -> collect(State, {Reply, Pending})
            end;
        Event -> collect(event(Event, State), Finish)
    end.

event({trace, _, call, {'albedo@harness@search', pages, [_, _, Acc]}},
      {counts, Pages, Decoded, Sources, Nodes, Kept, Queries}) ->
    Size = case Acc of {page, _, Matches} -> length(Matches); _ -> 0 end,
    {counts, Pages + 1, Decoded, Sources, Nodes, max(Kept, Size), Queries};
event({trace, _, call, {'albedo@daemon@conversation', read_input, _}},
      {counts, Pages, Decoded, Sources, Nodes, Kept, Queries}) ->
    {counts, Pages, Decoded + 1, Sources, Nodes, Kept, Queries};
event({trace, _, call, {'albedo@daemon@conversation', sourced_entry, _}},
      {counts, Pages, Decoded, Sources, Nodes, Kept, Queries}) ->
    {counts, Pages, Decoded, Sources + 1, Nodes, Kept, Queries};
event({trace, Pid, call, {'albedo@daemon@store', rows, [_, Sql, _, _]}},
      {counts, Pages, Decoded, Sources, Nodes, Kept, Queries}) ->
    IsNodes = case Sql of
        <<"SELECT id,depth", _/binary>> -> true;
        <<"SELECT n.id,n.depth", _/binary>> -> true;
        _ -> false
    end,
    {counts, Pages, Decoded, Sources, Nodes, Kept, Queries#{Pid => IsNodes}};
event({trace, Pid, return_from, {'albedo@daemon@store', rows, 4}, Result},
      {counts, Pages, Decoded, Sources, Nodes, Kept, Queries}) ->
    Count = case {maps:get(Pid, Queries, false), Result} of
        {true, {ok, Values}} when is_list(Values) -> length(Values);
        _ -> 0
    end,
    {counts, Pages, Decoded, Sources, Nodes + Count, Kept, maps:remove(Pid, Queries)};
event(_, State) -> State.
