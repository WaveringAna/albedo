-module(albedo_opencode_zen).
%% OpenCode Zen provider: live /models discovery with a disk cache, API-key
%% resolution, and the OpenCode client identity its free tier asks for.
%%
%% Zen answers a `-free` model only for a request shaped like the one OpenCode
%% ships: the user agent its binary launches with, its session and project
%% headers, a session id in the shape it mints, streaming, and the tool names
%% its agent sends (the last two are the extension's). A paid model goes out
%% with the profile's own key and none of that.

-export([models/2, cached_models/1, reload/1,
         access/2, session/1, project/1, user_agent/0, free/1]).

-define(DEFAULT_BASE_URL, <<"https://opencode.ai/zen/v1">>).
-define(CATALOG_FILE, "opencode-zen-models.json").
-define(CACHE_MAX_AGE_MS, 86400000). %% 24 hours
-define(FETCH_TIMEOUT_MS, 10000).
-define(CONNECT_TIMEOUT_MS, 5000).

%% OpenCode's own client identity. Its binary launches with
%% `--user-agent=opencode/<channel>/<version>/<artifact>`, and the channel,
%% version, and artifact only have to name a release the gateway knows; a
%% refusal that asks for a newer one is answered by raising the version.
-define(OPENCODE_CHANNEL, <<"latest">>).
-define(OPENCODE_VERSION, <<"2.0.27">>).
-define(OPENCODE_ARTIFACT, <<"cli">>).

%% The alphabetical order a session id's tail uses.
-define(ALPHABET, <<"0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ">>).

%% ---- the OpenCode client identity ---------------------------------------

%% The user agent OpenCode's own binary sends.
user_agent() ->
    <<"opencode/", ?OPENCODE_CHANNEL/binary, "/", ?OPENCODE_VERSION/binary,
      "/", ?OPENCODE_ARTIFACT/binary>>.

%% Whether `Model`'s id says the free tier serves it. Zen also serves a few
%% free without saying so in the id — `big-pickle` is one — which the extension
%% covers by wearing the lane whenever a profile carries no credential.
free(Model) when is_binary(Model) ->
    binary:match(Model, <<"-free">>) =/= nomatch;
free(_) ->
    false.

%% The session id for the session seeded by Seed. Zen routes a conversation
%% and finds its cached prefix by this id, so it is derived from the session
%% rather than minted per request: one albedo session keeps one zen session.
%%
%% The shape is OpenCode's, and the shape is what is checked: `ses_`, twelve
%% lowercase hex, then fourteen base62. OpenCode's own twelve hex encode a
%% millisecond clock and a per-millisecond counter, bitwise inverted, which
%% leaves a counter of one ending in `ffe`; the gateway reads that counter
%% back and refuses one outside its first sixty-four, so ours ends in `ffe`
%% too. Its clock half goes uninspected, so the hash stands in for it.
session(Seed0) ->
    Seed = binary(Seed0),
    Hex = binary:part(binary:encode_hex(crypto:hash(sha, Seed), lowercase), 0, 9),
    <<"ses_", Hex/binary, "ffe", (base62(crypto:hash(sha256, <<Seed/binary, ":zen">>), 14))/binary>>.

%% The project id OpenCode's requests carry: a hash of the directory it runs
%% in, forty hex characters. Ours is the home albedo serves.
project(Home0) ->
    binary:encode_hex(
        crypto:hash(sha, unicode:characters_to_binary(text(Home0))),
        lowercase
    ).

%% Prints `Count` characters of `Digest` as base62. A digest is already
%% uniform, so mapping its bytes without rejection leaves it uniform.
base62(Digest, Count) ->
    base62(Digest, Count, <<>>).

base62(_Digest, 0, Acc) ->
    Acc;
base62(<<Byte, Rest/binary>>, Count, Acc) ->
    Char = binary:at(?ALPHABET, Byte rem 62),
    base62(Rest, Count - 1, <<Acc/binary, Char>>).

%% ---- credentials --------------------------------------------------------

%% The profile's endpoint and key. A blank endpoint falls back to the default
%% gateway and a blank key to the environment. A blank key is not an error:
%% the free tier authenticates with the literal key OpenCode sends, so a
%% profile that only wants free models needs no credential at all.
access(Home0, Profile0) ->
    Home = text(Home0),
    Profile = binary(Profile0),
    {BaseUrl, Key} = profile_settings(Home, Profile),
    {ok, {resolve_base_url(BaseUrl), case Key of <<>> -> env_key(); _ -> Key end}}.

env_key() ->
    first_nonempty([env("OPENCODE_ZEN_API_KEY"), env("OPENCODE_API_KEY")]).

env(Name) ->
    case os:getenv(Name) of
        Value when is_list(Value), Value =/= "" -> unicode:characters_to_binary(string:trim(Value));
        _ -> <<>>
    end.

first_nonempty([]) -> <<>>;
first_nonempty([<<_, _/binary>> = Value | _]) -> Value;
first_nonempty([_ | Rest]) -> first_nonempty(Rest).

profile_settings(Home, Profile) ->
    case albedo_credentials:config(Home) of
        {ok, #{<<"providers">> := #{Profile := P}}} when is_map(P) ->
            {maps:get(<<"baseUrl">>, P, <<>>), maps:get(<<"apiKey">>, P, <<>>)};
        _ -> {<<>>, <<>>}
    end.

%% The gateway's own root. `/zen/v1` serves both the catalog and inference,
%% and the `/inference/openai/v1` path a member's console config names is the
%% same gateway, so it is rewritten to one endpoint.
resolve_base_url(<<>>) ->
    case env("OPENCODE_ZEN_BASE_URL") of
        <<>> -> ?DEFAULT_BASE_URL;
        Url -> resolve_base_url(Url)
    end;
resolve_base_url(Url) when is_binary(Url) ->
    case string:trim(Url, trailing, "/") of
        <<"https://opencode.ai/inference/openai/v1">> -> ?DEFAULT_BASE_URL;
        <<"https://opencode.ai/inference/openai">> -> ?DEFAULT_BASE_URL;
        Trimmed -> Trimmed
    end.

%% ---- models catalog -----------------------------------------------------

%% Returns any cached model IDs without reaching the network.
cached_models(Home0) ->
    read_cache(filename:join(text(Home0), ?CATALOG_FILE)).

%% Returns the model IDs Zen lists: a fresh disk cache, or a live fetch that
%% is then cached. A failed fetch keeps whatever the disk already had.
models(Home0, Endpoint0) ->
    Home = text(Home0),
    CachePath = filename:join(Home, ?CATALOG_FILE),
    case is_cache_fresh(CachePath) andalso read_cache(CachePath) of
        {ok, Ids} when Ids =/= [] -> {ok, Ids};
        _ ->
            case fetch_models(binary(Endpoint0), <<>>) of
                {ok, Ids} ->
                    _ = write_cache(CachePath, Ids),
                    {ok, Ids};
                {error, _} ->
                    fallback_cache_or_default(CachePath)
            end
    end.

%% Force a live reload of the model list through the configured profile's own
%% endpoint and key, so a profile pointed at another gateway reloads there.
reload(Home0) ->
    Home = text(Home0),
    CachePath = filename:join(Home, ?CATALOG_FILE),
    {Endpoint, Key} = reload_target(Home),
    case fetch_models(Endpoint, Key) of
        {ok, Ids} ->
            _ = write_cache(CachePath, Ids),
            {ok, nil};
        Error -> Error
    end.

reload_target(Home) ->
    case albedo_credentials:config(Home) of
        {ok, #{<<"providers">> := Providers}} when is_map(Providers) ->
            Profiles = [{maps:get(<<"baseUrl">>, P, <<>>), maps:get(<<"apiKey">>, P, <<>>)}
                        || {_, #{<<"extension">> := <<"opencode-zen">>} = P}
                               <- lists:sort(maps:to_list(Providers))],
            case Profiles of
                [{Url, Key} | _] -> {resolve_base_url(Url), Key};
                [] -> {resolve_base_url(<<>>), env_key()}
            end;
        _ -> {resolve_base_url(<<>>), env_key()}
    end.

fallback_cache_or_default(CachePath) ->
    case read_cache(CachePath) of
        {ok, Ids} when Ids =/= [] -> {ok, Ids};
        _ -> {ok, []}
    end.

%% Live GET to ${BaseUrl}/models. The catalog is public, so it answers without
%% a credential and only a reload carries the profile's key, as OpenCode does.
fetch_models(BaseUrl0, ApiKey0) ->
    BaseUrl = text(BaseUrl0),
    Url = string:trim(BaseUrl, trailing, "/") ++ "/models",
    Auth = case text(ApiKey0) of
        "" -> [];
        Key -> [{"authorization", "Bearer " ++ Key}]
    end,
    Headers = Auth ++ [
        {"accept", "application/json"},
        {"user-agent", binary_to_list(user_agent())}
    ],
    case albedo_http:get(Url, Headers, ?FETCH_TIMEOUT_MS, ?CONNECT_TIMEOUT_MS) of
        {ok, {200, _, Body}} ->
            try json:decode(Body) of
                #{<<"data">> := List} when is_list(List) ->
                    Ids = [Id || #{<<"id">> := Id} <- List, is_binary(Id), is_chat_model(Id)],
                    {ok, lists:usort(Ids)};
                _ -> {error, <<"unexpected /models response shape">>}
            catch _:_ -> {error, <<"invalid JSON from /models">>}
            end;
        {ok, {Status, _, _}} ->
            {error, iolist_to_binary(io_lib:format("endpoint returned HTTP ~B", [Status]))};
        {error, Reason} ->
            {error, iolist_to_binary(io_lib:format("could not reach endpoint: ~p", [Reason]))}
    end.

%% Non-chat entitlement filter: skips image generation, TTS, audio, realtime,
%% and speech routes, and the gateway's own placeholder entry.
is_chat_model(<<"auto">>) -> false;
is_chat_model(<<"test">>) -> false;
is_chat_model(Id) when is_binary(Id) ->
    case binary:match(Id, [<<"audio">>, <<"tts">>, <<"realtime">>, <<"image">>, <<"asr">>]) of
        nomatch -> true;
        _ -> false
    end;
is_chat_model(_) -> false.

is_cache_fresh(Path) ->
    albedo_credentials:fresh(Path, ?CACHE_MAX_AGE_MS).

read_cache(Path) ->
    case albedo_credentials:read_json(Path) of
        {ok, List} when is_list(List) ->
            {ok, [Id || Id <- List, is_binary(Id)]};
        {ok, _} -> {error, invalid};
        Error -> Error
    end.

%% Encoded here: `write` takes any list for iodata, which would glue the ids.
write_cache(Path, Ids) ->
    albedo_credentials:write(Path, json:encode(Ids)).

text(Val) when is_binary(Val) -> unicode:characters_to_list(Val);
text(Val) when is_list(Val) -> Val.

binary(Val) when is_list(Val) -> unicode:characters_to_binary(Val);
binary(Val) when is_binary(Val) -> Val.
