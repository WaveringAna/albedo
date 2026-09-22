%% Session wake registry: session id -> the submit closure its actor registered.
%%
%% The kernel reports finished background jobs through a host route, which runs
%% outside any session actor, so the notice needs a lookup from session id to
%% the actor that can submit a turn. The table is owned by a process nothing
%% else depends on, so it outlives every individual session and dies with the
%% daemon. Registered closures answer "" when the wake was submitted and a
%% refusal message otherwise; "session is busy" is the one the kernel retries.
-module(albedo_wakes).
-export([register/2, forget/1, deliver/3]).

-define(TABLE, albedo_wakes).

register(Id, Fun) ->
    ensure_table(),
    true = ets:insert(?TABLE, {Id, Fun}),
    nil.

forget(Id) ->
    case ets:whereis(?TABLE) of
        undefined -> nil;
        _ -> ets:delete(?TABLE, Id), nil
    end.

%% The refusal the caller should relay, or "" when the wake was submitted.
deliver(Id, Display, Text) ->
    case ets:whereis(?TABLE) of
        undefined -> <<"session unavailable">>;
        _ ->
            case ets:lookup(?TABLE, Id) of
                [{_, Fun}] when is_function(Fun, 2) ->
                    try Fun(Display, Text)
                    catch _:_ -> <<"session unavailable">>
                    end;
                _ -> <<"session unavailable">>
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
