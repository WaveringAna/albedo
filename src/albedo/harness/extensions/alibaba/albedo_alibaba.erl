-module(albedo_alibaba).
%% Alibaba Model Studio provider: live /models discovery with disk cache,
%% non-chat entitlement filtering, and key/endpoint resolution.

-include_lib("kernel/include/file.hrl").
-export([models/2, reload/2, fetch_models/2, resolve_credentials/2]).

-define(DEFAULT_BASE_URL, <<"https://token-plan.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1">>).
-define(CATALOG_FILE, "alibaba-models.json").
-define(CACHE_MAX_AGE_MS, 86400000). %% 24 hours
-define(FETCH_TIMEOUT_MS, 10000).

-define(DEFAULT_MODELS, [
    <<"deepseek-v4-flash-0731">>,
    <<"deepseek-v4-pro">>,
    <<"deepseek-v4.1-flash">>,
    <<"glm-5.2">>,
    <<"glm-5.3">>,
    <<"qwen3.6-flash">>,
    <<"qwen3.7-max">>,
    <<"qwen3.7-plus">>,
    <<"qwen3.8-flash">>,
    <<"qwen3.8-max">>
]).

%% Returns the entitled model IDs for Alibaba: reads fresh disk cache,
%% or fetches live from the endpoint and caches to disk.
models(Home0, Endpoint0) ->
    Home = text(Home0),
    Endpoint = binary(Endpoint0),
    CachePath = filename:join(Home, ?CATALOG_FILE),
    case is_cache_fresh(CachePath) of
        true ->
            case read_cache(CachePath) of
                {ok, Ids} when Ids =/= [] -> {ok, Ids};
                _ -> refresh_or_default(Home, Endpoint, CachePath)
            end;
        false ->
            refresh_or_default(Home, Endpoint, CachePath)
    end.

%% Force a live reload of the model list from the endpoint.
reload(Home0, Endpoint0) ->
    Home = text(Home0),
    Endpoint = binary(Endpoint0),
    CachePath = filename:join(Home, ?CATALOG_FILE),
    BaseUrl = resolve_base_url(Endpoint),
    case find_api_key(Home) of
        {ok, ApiKey} ->
            case fetch_models(BaseUrl, ApiKey) of
                {ok, Ids} ->
                    _ = write_cache(CachePath, Ids),
                    {ok, Ids};
                {error, Reason} -> {error, Reason}
            end;
        {error, _} ->
            {error, <<"no Alibaba API key found">>}
    end.

refresh_or_default(Home, Endpoint, CachePath) ->
    BaseUrl = resolve_base_url(Endpoint),
    case find_api_key(Home) of
        {ok, ApiKey} ->
            case fetch_models(BaseUrl, ApiKey) of
                {ok, Ids} ->
                    _ = write_cache(CachePath, Ids),
                    {ok, Ids};
                {error, _} ->
                    fallback_cache_or_default(CachePath)
            end;
        {error, _} ->
            fallback_cache_or_default(CachePath)
    end.

fallback_cache_or_default(CachePath) ->
    case read_cache(CachePath) of
        {ok, Ids} when Ids =/= [] -> {ok, Ids};
        _ -> {ok, ?DEFAULT_MODELS}
    end.

%% Live GET to ${BaseUrl}/models with Bearer auth.
fetch_models(BaseUrl0, ApiKey0) ->
    BaseUrl = text(BaseUrl0),
    ApiKey = text(ApiKey0),
    Url = string:trim(BaseUrl, trailing, "/") ++ "/models",
    Parsed = uri_string:parse(Url),
    Host = maps:get(host, Parsed, ""),
    Headers = [
        {"authorization", "Bearer " ++ ApiKey},
        {"accept", "application/json"},
        {"user-agent", "albedo"}
    ],
    Tls = case maps:get(scheme, Parsed, "") of
        "https" -> [{ssl, albedo_credentials:tls_options(Host)}];
        _ -> []
    end,
    _ = application:ensure_all_started(inets),
    _ = application:ensure_all_started(ssl),
    Request = {Url, Headers},
    HttpOptions = [{timeout, ?FETCH_TIMEOUT_MS}, {connect_timeout, 5000} | Tls],
    case httpc:request(get, Request, HttpOptions, [{body_format, binary}]) of
        {ok, {{_, 200, _}, _, Body}} ->
            try json:decode(Body) of
                #{<<"data">> := List} when is_list(List) ->
                    Ids = [Id || #{<<"id">> := Id} <- List, is_binary(Id), is_chat_model(Id)],
                    case Ids of
                        [] -> {ok, ?DEFAULT_MODELS};
                        _ -> {ok, lists:usort(Ids)}
                    end;
                _ -> {error, <<"unexpected /models response shape">>}
            catch _:_ -> {error, <<"invalid JSON from /models">>}
            end;
        {ok, {{_, Status, _}, _, _}} ->
            {error, iolist_to_binary(io_lib:format("endpoint returned HTTP ~B", [Status]))};
        {error, Reason} ->
            {error, iolist_to_binary(io_lib:format("could not reach endpoint: ~p", [Reason]))}
    end.

%% Non-chat entitlement filter: skips image generation, TTS, audio, realtime, and internal routes.
is_chat_model(<<"auto">>) -> false;
is_chat_model(Id) when is_binary(Id) ->
    case binary:match(Id, [
        <<"audio">>,
        <<"tts">>,
        <<"realtime">>,
        <<"image">>,
        <<"wan">>,
        <<"asr">>,
        <<"livetranslate">>
    ]) of
        nomatch -> true;
        _ -> false
    end;
is_chat_model(_) -> false.

is_cache_fresh(Path) ->
    case file:read_file_info(Path, [{time, posix}]) of
        {ok, #file_info{type = regular, mtime = Mtime}} ->
            erlang:system_time(millisecond) - Mtime * 1000 < ?CACHE_MAX_AGE_MS;
        _ -> false
    end.

read_cache(Path) ->
    case file:read_file(Path) of
        {ok, Bytes} ->
            try json:decode(Bytes) of
                List when is_list(List) ->
                    {ok, [Id || Id <- List, is_binary(Id)]};
                _ -> {error, invalid}
            catch _:_ -> {error, invalid} end;
        Error -> Error
    end.

write_cache(Path, Ids) ->
    Temp = Path ++ ".tmp." ++ integer_to_list(erlang:unique_integer([positive])),
    _ = filelib:ensure_dir(Path),
    case file:write_file(Temp, json:encode(Ids)) of
        ok ->
            _ = file:rename(Temp, Path),
            ok;
        Error ->
            _ = file:delete(Temp),
            Error
    end.

%% Resolves BaseUrl and ApiKey for a session or profile.
%% Resolution order for key:
%% 1. Profile setting in config.json
%% 2. auth.json -> "alibaba"
%% 3. ALIBABA_API_KEY / DASHSCOPE_API_KEY environment variables
resolve_credentials(Home0, Profile0) ->
    Home = text(Home0),
    Profile = binary(Profile0),
    {ProfileUrl, ProfileKey} = profile_settings(Home, Profile),
    BaseUrl = case ProfileUrl of
        <<>> -> resolve_base_url(<<>>);
        Url -> Url
    end,
    ApiKeyRes = case ProfileKey of
        <<>> -> find_api_key(Home);
        Key -> {ok, Key}
    end,
    case ApiKeyRes of
        {ok, ApiKey} ->
            {ok, {BaseUrl, ApiKey}};
        {error, Reason} ->
            {error, Reason}
    end.

resolve_base_url(<<>>) ->
    case os:getenv("ALIBABA_BASE_URL") of
        false -> ?DEFAULT_BASE_URL;
        "" -> ?DEFAULT_BASE_URL;
        Url -> unicode:characters_to_binary(string:trim(Url, trailing, "/"))
    end;
resolve_base_url(Url) when is_binary(Url) ->
    string:trim(Url, trailing, "/").

profile_settings(Home, Profile) ->
    ConfigPath = filename:join(Home, "config.json"),
    case file:read_file(ConfigPath) of
        {ok, Bytes} ->
            try json:decode(Bytes) of
                #{<<"providers">> := Providers} when is_map(Providers) ->
                    case maps:get(Profile, Providers, undefined) of
                        #{<<"baseUrl">> := B, <<"apiKey">> := K} when is_binary(B), is_binary(K) ->
                            {B, K};
                        #{<<"baseUrl">> := B} when is_binary(B) ->
                            {B, <<>>};
                        #{<<"apiKey">> := K} when is_binary(K) ->
                            {<<>>, K};
                        _ -> {<<>>, <<>>}
                    end;
                _ -> {<<>>, <<>>}
            catch _:_ -> {<<>>, <<>>} end;
        _ -> {<<>>, <<>>}
    end.

find_api_key(Home) ->
    case key_from_auth_file(filename:join(Home, "auth.json")) of
        {ok, Key} -> {ok, Key};
        _ ->
            case os:getenv("ALIBABA_API_KEY") of
                false ->
                    case os:getenv("DASHSCOPE_API_KEY") of
                        false -> {error, <<"no Alibaba API key found">>};
                        "" -> {error, <<"no Alibaba API key found">>};
                        Key -> {ok, unicode:characters_to_binary(Key)}
                    end;
                "" -> {error, <<"no Alibaba API key found">>};
                Key -> {ok, unicode:characters_to_binary(Key)}
            end
    end.

key_from_auth_file(Path) ->
    case file:read_file(Path) of
        {ok, Bytes} ->
            try json:decode(Bytes) of
                #{<<"alibaba">> := #{<<"key">> := Key}} when is_binary(Key), Key =/= <<>> ->
                    {ok, Key};
                #{<<"alibaba">> := #{<<"apiKey">> := Key}} when is_binary(Key), Key =/= <<>> ->
                    {ok, Key};
                #{<<"alibaba">> := #{<<"access">> := Key}} when is_binary(Key), Key =/= <<>> ->
                    {ok, Key};
                #{<<"alibaba">> := Key} when is_binary(Key), Key =/= <<>> ->
                    {ok, Key};
                _ -> {error, not_found}
            catch _:_ -> {error, not_found} end;
        _ -> {error, not_found}
    end.

text(Val) when is_binary(Val) -> unicode:characters_to_list(Val);
text(Val) when is_list(Val) -> Val.

binary(Val) when is_list(Val) -> unicode:characters_to_binary(Val);
binary(Val) when is_binary(Val) -> Val.
