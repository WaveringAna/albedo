%% The Claude model list from the Anthropic Models API, newest first, cached in
%% $ALBEDO_HOME/claude-models.json with each model's limits, image input, and
%% effort levels. A model Anthropic releases reaches the picker without an
%% albedo update.
-module(albedo_claude_models).
-export([read/1, fetch/1, write/2, refresh/2, api_key/1]).

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
fetch({Name, Value}) ->
    Headers = [{text(Name), text(Value)},
               {"anthropic-version", "2023-06-01"},
               {"accept", "application/json"},
               {"user-agent", "albedo"}]
        ++ [{"anthropic-beta", "oauth-2025-04-20"} || Name =:= <<"authorization">>],
    pages(Headers, "", ?MAX_PAGES, []).

write(Home, Encoded) ->
    case albedo_credentials:write(path(Home), Encoded) of
        ok -> {ok, nil};
        _ -> {error, <<"could not save the Claude model list">>}
    end.

%% Refetches off the caller's process when the cache is missing or old, one
%% refresh at a time. `Reload' resolves a credential and fetches and saves the list.
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
                    Listed = Models ++ Data,
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

path(Home) -> filename:join(text(Home), ?CATALOG).

text(Value) when is_binary(Value) -> unicode:characters_to_list(Value);
text(Value) when is_list(Value) -> Value.
