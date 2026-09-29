%% The Claude model list from the Anthropic Models API, newest first, cached in
%% $ALBEDO_HOME/claude-models.json with each model's limits, image input, and
%% effort levels. A model Anthropic releases reaches the picker without an
%% albedo update.
-module(albedo_claude_models).
-export([read/1, reload/2, refresh/2, api_key/1]).

-define(CATALOG, "claude-models.json").
-define(URL, "https://api.anthropic.com/v1/models?limit=1000").
-define(MAX_AGE_MS, 21600000).
-define(TIMEOUT_MS, 20000).
%% A thousand models a page; more pages than this is a runaway cursor.
-define(MAX_PAGES, 10).
-define(REFRESH_PROCESS, albedo_claude_models_refresh).

%% The cache as JSON text for the Gleam decoder.
read(Home) ->
    case file:read_file(path(Home)) of
        {ok, Bytes} -> {ok, Bytes};
        _ -> {error, nil}
    end.

%% Refetches the list with one credential header. A bearer token is a Claude
%% Code subscription, which the API accepts only with the OAuth beta.
reload(Home, {Name, Value}) ->
    Headers = [{text(Name), text(Value)},
               {"anthropic-version", "2023-06-01"},
               {"accept", "application/json"},
               {"user-agent", "albedo"}]
        ++ [{"anthropic-beta", "oauth-2025-04-20"} || Name =:= <<"authorization">>],
    case pages(Headers, "", ?MAX_PAGES, []) of
        {ok, Models} ->
            case albedo_credentials:write(path(Home), json:encode(Models)) of
                ok -> {ok, nil};
                _ -> {error, <<"could not save the Claude model list">>}
            end;
        Error -> Error
    end.

%% Refetches off the caller's process when the cache is missing or old, one
%% refresh at a time. `Reload' resolves a credential and calls reload/2.
refresh(Home, Reload) ->
    case albedo_credentials:stale(path(Home), ?MAX_AGE_MS) of
        false -> nil;
        true ->
            Pid = spawn(fun() -> receive go -> Reload() end end),
            try register(?REFRESH_PROCESS, Pid) of
                true -> Pid ! go, nil
            catch _:_ -> exit(Pid, kill), nil
            end
    end.

%% The Console key of the first claude profile that sets one.
api_key(Home) ->
    case albedo_credentials:config(Home) of
        {ok, #{<<"providers">> := Providers}} when is_map(Providers) ->
            case [Key || {_, #{<<"extension">> := <<"claude">>, <<"apiKey">> := <<_, _/binary>> = Key}}
                             <- lists:sort(maps:to_list(Providers))] of
                [Key | _] -> {ok, Key};
                [] -> {error, nil}
            end;
        _ -> {error, nil}
    end.

pages(_, _, 0, Models) -> {ok, Models};
pages(Headers, After, Left, Models) ->
    Url = ?URL ++ [["&after_id=", After] || After =/= ""],
    case albedo_http:get(lists:flatten(Url), Headers, ?TIMEOUT_MS, 10000) of
        {ok, {200, _, Body}} ->
            try json:decode(Body) of
                #{<<"data">> := Data} = Page when is_list(Data) ->
                    Listed = Models ++ [M || Raw <- Data, M <- [trim(Raw)], M =/= skip],
                    case Page of
                        #{<<"has_more">> := true, <<"last_id">> := <<_, _/binary>> = Last} ->
                            pages(Headers, binary_to_list(Last), Left - 1, Listed);
                        _ -> {ok, Listed}
                    end;
                _ -> {error, <<"Anthropic model list is not valid">>}
            catch _:_ -> {error, <<"Anthropic model list is not valid">>}
            end;
        {ok, {Status, _, _}} ->
            {error, iolist_to_binary(io_lib:format("Anthropic model list returned HTTP ~B", [Status]))};
        _ -> {error, <<"Anthropic model list request failed">>}
    end.

%% Only what lookup and listing read.
trim(#{<<"id">> := <<_, _/binary>> = Id} = Model) ->
    Capabilities = case maps:get(<<"capabilities">>, Model, null) of
        C when is_map(C) -> C;
        _ -> #{}
    end,
    #{<<"id">> => Id,
      <<"context">> => positive(maps:get(<<"max_input_tokens">>, Model, null)),
      <<"output">> => positive(maps:get(<<"max_tokens">>, Model, null)),
      <<"images">> => supported(maps:get(<<"image_input">>, Capabilities, null)),
      <<"efforts">> => efforts(maps:get(<<"effort">>, Capabilities, null))};
trim(_) -> skip.

supported(#{<<"supported">> := true}) -> true;
supported(_) -> false.

%% The supported levels, lowest first; a level albedo does not know sorts last.
efforts(#{<<"supported">> := true} = Levels) ->
    Supported = [Level || {Level, Detail} <- maps:to_list(Levels),
                          Level =/= <<"supported">>, supported(Detail)],
    lists:sort(fun(A, B) -> {rank(A), A} =< {rank(B), B} end, Supported);
efforts(_) -> [].

rank(<<"minimal">>) -> 0;
rank(<<"low">>) -> 1;
rank(<<"medium">>) -> 2;
rank(<<"high">>) -> 3;
rank(<<"xhigh">>) -> 4;
rank(<<"max">>) -> 5;
rank(_) -> 6.

positive(N) when is_integer(N), N > 0 -> N;
positive(_) -> null.

path(Home) -> filename:join(text(Home), ?CATALOG).

text(Value) when is_binary(Value) -> unicode:characters_to_list(Value);
text(Value) when is_list(Value) -> Value.
