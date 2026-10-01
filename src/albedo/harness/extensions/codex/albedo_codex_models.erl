%% Transport, atomic storage, and one background refresh per account.
-module(albedo_codex_models).
-export([refresh_async/2, read/1, write/2, get/2]).

-define(TIMEOUT_MS, 20000).
-define(MAX_BYTES, 8388608).

refresh_async(Account, Job) ->
    Name = list_to_atom("albedo_codex_models_" ++ integer_to_list(erlang:phash2(Account))),
    Pid = spawn(fun() -> receive go -> Job() end end),
    try register(Name, Pid) of
        true -> Pid ! go, nil
    catch
        _:_ -> exit(Pid, kill), nil
    end.

read(Home) ->
    case file:read_file(filename:join(text(Home), "codex-models.json")) of
        {ok, Bytes} -> {ok, Bytes};
        _ -> {error, nil}
    end.

write(Home, Encoded) ->
    case albedo_credentials:write(filename:join(text(Home), "codex-models.json"), Encoded) of
        ok -> {ok, nil};
        _ -> {error, <<"Codex model cache could not be written">>}
    end.

get(Url, Headers) ->
    NativeHeaders = [{text(Name), text(Value)} || {Name, Value} <- Headers],
    case albedo_http:get(text(Url), [{"user-agent", "albedo"} | NativeHeaders], ?TIMEOUT_MS, 10000) of
        {ok, {Status, ResponseHeaders, Body}} when byte_size(Body) =< ?MAX_BYTES ->
            {ok, {response, Status,
                [{unicode:characters_to_binary(Name), unicode:characters_to_binary(Value)}
                 || {Name, Value} <- ResponseHeaders], Body}};
        _ -> {error, nil}
    end.

text(Value) when is_binary(Value) -> binary_to_list(Value);
text(Value) -> Value.
