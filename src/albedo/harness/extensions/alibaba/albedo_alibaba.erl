-module(albedo_alibaba).
%% Alibaba Model Studio provider: live /models discovery with disk cache,
%% non-chat entitlement filtering, and key/endpoint resolution.

-include_lib("kernel/include/file.hrl").
-export([models/2, reload/2, fetch_models/2, access/3, limited/4]).

-define(DEFAULT_BASE_URL, <<"https://token-plan.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1">>).
-define(CATALOG_FILE, "alibaba-models.json").
-define(CACHE_MAX_AGE_MS, 86400000). %% 24 hours
-define(FETCH_TIMEOUT_MS, 10000).
-define(SCOPE, <<"alibaba">>).
%% Used when a spent quota names no reset time.
-define(DEFAULT_LIMIT_MS, 900000).
%% Tokens- and requests-per-minute limits clear within a minute.
-define(RATE_LIMIT_MS, 30000).



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
        _ -> {ok, []}
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
                    {ok, lists:usort(Ids)};
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

%% ---- key pool -----------------------------------------------------------

%% The session's key as {"baseUrl", "apiKey"} JSON. Every Alibaba key albedo
%% can see is a sibling: other alibaba profiles in config.json, auth.json's
%% "alibaba" entry or list, and the environment. The key this profile would
%% use on its own comes first; limited keys go last.
access(Home0, Profile0, Session0) ->
    Session = binary(Session0),
    case pool(text(Home0), binary(Profile0)) of
        [] -> {error, <<"Alibaba API key not found; set ALIBABA_API_KEY, add to auth.json, or configure in /login">>};
        Keys ->
            [First | _] = albedo_accounts:order(?SCOPE, Keys, Session, fun id/1),
            albedo_accounts:remember(?SCOPE, Session, id(First)),
            {ok, iolist_to_binary(json:encode(maps:with([<<"baseUrl">>, <<"apiKey">>], First)))}
    end.

%% Records a 429 against the key that received it. Every Alibaba 429 is a
%% limit; one naming a spent quota or an unpaid bill lasts, the rest are
%% per-minute rate limits.
limited(Home0, Profile0, Key, Body0) ->
    Body = binary(Body0),
    Lasting = lists:any(fun(Mark) -> binary:match(Body, Mark) =/= nomatch end,
                        [<<"insufficient_quota">>, <<"exceeded your current quota">>,
                         <<"exhausted">>, <<"Arrearage">>, <<"Overdue">>]),
    Until = erlang:system_time(millisecond) + case Lasting of
        true -> ?DEFAULT_LIMIT_MS;
        false -> ?RATE_LIMIT_MS
    end,
    Id = id(#{<<"apiKey">> => Key}),
    ok = albedo_accounts:note(?SCOPE, Id, Until),
    Now = erlang:system_time(millisecond),
    Next = [K || K <- pool(text(Home0), binary(Profile0)), id(K) =/= Id,
                 not albedo_accounts:limited(K, Now)],
    {ok, iolist_to_binary(json:encode(#{
        <<"until">> => albedo_accounts:local_time(Until),
        <<"next">> => case Next of [#{<<"name">> := Name} | _] -> Name; [] -> <<>> end,
        <<"lasting">> => Lasting
    }))}.

pool(Home, Profile) ->
    {ProfileUrl, ProfileKey} = profile_settings(Home, Profile),
    BaseUrl = case ProfileUrl of <<>> -> resolve_base_url(<<>>); Url -> Url end,
    Own = case ProfileKey of
        <<>> -> case find_api_key(Home) of {ok, K} -> [{Profile, BaseUrl, K}]; _ -> [] end;
        K -> [{Profile, BaseUrl, K}]
    end,
    Siblings = [{Name, case U of <<>> -> BaseUrl; _ -> U end, K}
                || {Name, U, K} <- alibaba_profiles(Home), Name =/= Profile]
        ++ [{<<"auth.json">>, BaseUrl, K} || K <- auth_keys(filename:join(Home, "auth.json"))]
        ++ [{list_to_binary(Var), BaseUrl, unicode:characters_to_binary(K)}
            || Var <- ["ALIBABA_API_KEY", "DASHSCOPE_API_KEY"],
               K <- [os:getenv(Var)], is_list(K), K =/= ""],
    Unique = lists:foldl(fun({_, _, K} = Entry, Acc) ->
        case lists:keymember(K, 3, Acc) of true -> Acc; false -> Acc ++ [Entry] end
    end, [], Own ++ Siblings),
    [#{<<"name">> => Name, <<"baseUrl">> => U, <<"apiKey">> => K,
       <<"selected">> => I =:= 1 andalso Own =/= [],
       <<"limitedUntil">> => albedo_accounts:noted(?SCOPE, id(#{<<"apiKey">> => K}))}
     || {I, {Name, U, K}} <- lists:enumerate(Unique)].

%% A key's id in limit bookkeeping, never the key itself.
id(#{<<"apiKey">> := Key}) ->
    binary:encode_hex(binary:part(crypto:hash(sha256, Key), 0, 8), lowercase).

alibaba_profiles(Home) ->
    case file:read_file(filename:join(Home, "config.json")) of
        {ok, Bytes} ->
            try json:decode(Bytes) of
                #{<<"providers">> := Providers} when is_map(Providers) ->
                    [{Name, maps:get(<<"baseUrl">>, P, <<>>), Key}
                     || {Name, #{<<"extension">> := <<"alibaba">>, <<"apiKey">> := <<_, _/binary>> = Key} = P}
                            <- lists:sort(maps:to_list(Providers))];
                _ -> []
            catch _:_ -> [] end;
        _ -> []
    end.

auth_keys(Path) ->
    case file:read_file(Path) of
        {ok, Bytes} ->
            try json:decode(Bytes) of
                #{<<"alibaba">> := List} when is_list(List) -> lists:filtermap(fun auth_key/1, List);
                #{<<"alibaba">> := One} -> lists:filtermap(fun auth_key/1, [One]);
                _ -> []
            catch _:_ -> [] end;
        _ -> []
    end.

auth_key(<<_, _/binary>> = Key) -> {true, Key};
auth_key(#{<<"key">> := <<_, _/binary>> = Key}) -> {true, Key};
auth_key(#{<<"apiKey">> := <<_, _/binary>> = Key}) -> {true, Key};
auth_key(#{<<"access">> := <<_, _/binary>> = Key}) -> {true, Key};
auth_key(_) -> false.

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
    case auth_keys(Path) of
        [Key | _] -> {ok, Key};
        [] -> {error, not_found}
    end.

text(Val) when is_binary(Val) -> unicode:characters_to_list(Val);
text(Val) when is_list(Val) -> Val.

binary(Val) when is_list(Val) -> unicode:characters_to_binary(Val);
binary(Val) when is_binary(Val) -> Val.
