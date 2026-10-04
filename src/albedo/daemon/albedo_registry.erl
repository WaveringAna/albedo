%% Shared ETS plumbing for session-id -> closure registries whose table must
%% outlive every individual session. Each table's payload contract belongs to
%% its own module: albedo_wakes carries turn submissions, albedo_mailbox
%% carries letters, albedo_commands carries session state operations.
-module(albedo_registry).
-export([register/3, forget/2, lookup/2, call/6]).

register(Table, Id, Fun) ->
    ensure_table(Table),
    true = ets:insert(Table, {Id, Fun}),
    nil.

forget(Table, Id) ->
    try ets:delete(Table, Id) catch error:badarg -> ok end,
    nil.

%% The stored value, or undefined when the table or the entry is gone.
lookup(Table, Id) ->
    try ets:lookup(Table, Id) of
        [{_, Value}] -> {ok, Value};
        _ -> undefined
    catch error:badarg -> undefined end.

%% Runs a registered closure and answers Missing when it is not registered and
%% Crashed when it dies mid-call: the caller runs outside the session actor,
%% so a dead closure must still produce an answer, not an exception.
call(Table, Id, Arity, Args, Missing, Crashed) ->
    case lookup(Table, Id) of
        {ok, Fun} when is_function(Fun, Arity) ->
            try apply(Fun, Args)
            catch _:_ -> Crashed
            end;
        _ -> Missing
    end.

ensure_table(Table) ->
    case ets:whereis(Table) of
        undefined ->
            Parent = self(),
            Ready = make_ref(),
            {Owner, Monitor} = spawn_monitor(fun() -> table_owner(Table, Parent, Ready) end),
            receive
                {Ready, ready} -> demonitor(Monitor, [flush]), ok;
                {'DOWN', Monitor, process, Owner, Reason} -> error({table_start_failed, Table, Reason})
            end;
        _ -> ok
    end.

%% The winning owner outlives registering callers. Losing creators acknowledge
%% the existing table and exit instead of leaving an idle process behind.
table_owner(Table, Parent, Ready) ->
    Created = try ets:new(Table, [public, named_table, {read_concurrency, true}]) of
        _ -> true
    catch error:badarg ->
        case ets:whereis(Table) of
            undefined -> error({table_creation_failed, Table});
            _ -> false
        end
    end,
    Parent ! {Ready, ready},
    case Created of
        true -> receive stop -> ok end;
        false -> ok
    end.
