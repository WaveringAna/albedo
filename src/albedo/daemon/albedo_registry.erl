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
            _ = spawn(fun() -> table_owner(Table) end),
            wait_table(Table, 200);
        _ -> ok
    end.

%% The owner needs a moment to create the table; bounded, because a table that
%% never appears should fail loudly in register, not hang here.
wait_table(_Table, 0) -> ok;
wait_table(Table, N) ->
    case ets:whereis(Table) of
        undefined -> receive after 1 -> ok end, wait_table(Table, N - 1);
        _ -> ok
    end.

table_owner(Table) ->
    try ets:new(Table, [public, named_table, {read_concurrency, true}])
    catch _:_ -> ok   %% a concurrent creator won the name; ours is theirs
    end,
    receive stop -> ok
    after infinity -> ok
    end.
