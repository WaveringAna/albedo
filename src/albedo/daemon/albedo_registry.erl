%% Shared ETS plumbing for session-id -> closure registries whose table must
%% outlive every individual session. Each table's payload contract belongs to
%% its own module: albedo_wakes carries turn submissions, albedo_commands
%% carries session state operations.
-module(albedo_registry).
-export([register/3, forget/2, fetch/3]).

register(Table, Id, Fun) ->
    ensure_table(Table),
    true = ets:insert(Table, {Id, Fun}),
    nil.

forget(Table, Id) ->
    case ets:whereis(Table) of
        undefined -> nil;
        _ -> ets:delete(Table, Id), nil
    end.

fetch(Table, Id, Arity) ->
    case ets:whereis(Table) of
        undefined -> undefined;
        _ ->
            case ets:lookup(Table, Id) of
                [{_, Fun}] when is_function(Fun, Arity) -> {ok, Fun};
                _ -> undefined
            end
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
