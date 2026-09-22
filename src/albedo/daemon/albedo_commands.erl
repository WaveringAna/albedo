%% Session command state-op registry: session id -> the state closure its actor
%% registered.
%%
%% A command run executes outside the session actor (the kernel's host-call
%% process or an HTTP request process), so its state access needs a lookup from
%% session id to the actor that owns the state. The closure returns a Gleam
%% Result ({ok, Json} | {error, Message}); exceptions answer an error rather
%% than propagating into the caller. Registration mirrors albedo_wakes.
-module(albedo_commands).
-export([register/2, forget/1, call/3]).

-define(TABLE, albedo_commands).

register(Id, Fun) ->
    ensure_table(),
    true = ets:insert(?TABLE, {Id, Fun}),
    nil.

forget(Id) ->
    case ets:whereis(?TABLE) of
        undefined -> nil;
        _ -> ets:delete(?TABLE, Id), nil
    end.

%% The registered closure's Result, or an error when the session is not here.
call(Id, Op, Args) ->
    case ets:whereis(?TABLE) of
        undefined -> {error, <<"session unavailable">>};
        _ ->
            case ets:lookup(?TABLE, Id) of
                [{_, Fun}] when is_function(Fun, 2) ->
                    try Fun(Op, Args)
                    catch _:_ -> {error, <<"session unavailable">>}
                    end;
                _ -> {error, <<"session unavailable">>}
            end
    end.

ensure_table() ->
    case ets:whereis(?TABLE) of
        undefined ->
            _ = spawn(fun table_owner/0),
            wait_table(200);
        _ -> ok
    end.

%% The owner needs a moment to create the table; bounded, because a table that
%% never appears should fail loudly in register, not hang here.
wait_table(0) -> ok;
wait_table(N) ->
    case ets:whereis(?TABLE) of
        undefined -> receive after 1 -> ok end, wait_table(N - 1);
        _ -> ok
    end.

table_owner() ->
    try ets:new(?TABLE, [public, named_table, {read_concurrency, true}])
    catch _:_ -> ok   %% a concurrent creator won the name; ours is theirs
    end,
    receive stop -> ok
    after infinity -> ok
    end.
