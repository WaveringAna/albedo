-module(albedo_alibaba).
%% Alibaba Model Studio provider: live /models discovery with disk cache,
%% non-chat entitlement filtering, and key/endpoint resolution.

-include_lib("kernel/include/file.hrl").
-export([models/2, reload/1, fetch_models/2, access/3, limited/4]).

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
    CachePath = filename:join(Home, ?CATALOG_FILE),
    case is_cache_fresh(CachePath) andalso read_cache(CachePath) of
        {ok, Ids} when Ids =/= [] -> {ok, Ids};
        _ -> refresh_or_default(Home, binary(Endpoint0), CachePath)
    end.

%% Force a live reload of the model list with the first key albedo can see,
%% at that key's own endpoint.
reload(Home0) ->
    Home = text(Home0),
    case fetch_live(Home, <<>>, filename:join(Home, ?CATALOG_FILE)) of
        {ok, _} -> {ok, nil};
        Error -> Error
    end.

refresh_or_default(Home, Endpoint, CachePath) ->
    case fetch_live(Home, Endpoint, CachePath) of
        {ok, Ids} -> {ok, Ids};
        {error, _} -> fallback_cache_or_default(CachePath)
    end.

%% Any pooled key may list models: one configured at Endpoint first, else the
%% first key albedo can see. An empty Endpoint means that key's own.
fetch_live(Home, Endpoint0, CachePath) ->
    Endpoint = string:trim(Endpoint0, trailing, "/"),
    Keys = pool(Home, <<>>),
    At = [Key || #{<<"baseUrl">> := Url} = Key <- Keys,
                 string:trim(Url, trailing, "/") =:= Endpoint],
    case At ++ Keys of
        [#{<<"baseUrl">> := BaseUrl, <<"apiKey">> := ApiKey} | _] ->
            Url = case Endpoint of
                <<>> -> BaseUrl;
                _ -> Endpoint
            end,
            case fetch_models(Url, ApiKey) of
                {ok, Ids} ->
                    _ = write_cache(CachePath, Ids),
                    {ok, Ids};
                Error -> Error
            end;
        [] -> {error, <<"no Alibaba API key found">>}
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
    Headers = [
        {"authorization", "Bearer " ++ ApiKey},
        {"accept", "application/json"},
        {"user-agent", "albedo"}
    ],
    case albedo_http:get(Url, Headers, ?FETCH_TIMEOUT_MS, 5000) of
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
        ++ [{<<"auth.json">>, BaseUrl, K} || K <- auth_keys(albedo_credentials:auth_path(Home))]
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
    case albedo_credentials:read_json(filename:join(Home, "config.json")) of
        {ok, #{<<"providers">> := Providers}} when is_map(Providers) ->
            [{Name, maps:get(<<"baseUrl">>, P, <<>>), Key}
             || {Name, #{<<"extension">> := <<"alibaba">>, <<"apiKey">> := <<_, _/binary>> = Key} = P}
                    <- lists:sort(maps:to_list(Providers))];
        _ -> []
    end.

auth_keys(Path) ->
    case albedo_credentials:read(Path) of
        {ok, #{<<"alibaba">> := List}} when is_list(List) -> lists:filtermap(fun auth_key/1, List);
        {ok, #{<<"alibaba">> := One}} -> lists:filtermap(fun auth_key/1, [One]);
        _ -> []
    end.

auth_key(<<_, _/binary>> = Key) -> {true, Key};
auth_key(#{<<"key">> := <<_, _/binary>> = Key}) -> {true, Key};
auth_key(#{<<"apiKey">> := <<_, _/binary>> = Key}) -> {true, Key};
auth_key(#{<<"access">> := <<_, _/binary>> = Key}) -> {true, Key};
auth_key(_) -> false.

resolve_base_url(<<>>) ->
    case os:getenv("ALIBABA_BASE_URL") of
        Url when is_list(Url), Url =/= "" -> unicode:characters_to_binary(string:trim(Url, trailing, "/"));
        _ -> ?DEFAULT_BASE_URL
    end;
resolve_base_url(Url) when is_binary(Url) ->
    string:trim(Url, trailing, "/").

profile_settings(Home, Profile) ->
    case albedo_credentials:read_json(filename:join(Home, "config.json")) of
        {ok, #{<<"providers">> := #{Profile := P}}} when is_map(P) ->
            Bin = fun(K) -> case maps:get(K, P, <<>>) of B when is_binary(B) -> B; _ -> <<>> end end,
            {Bin(<<"baseUrl">>), Bin(<<"apiKey">>)};
        _ -> {<<>>, <<>>}
    end.

find_api_key(Home) ->
    case key_from_auth_file(albedo_credentials:auth_path(Home)) of
        {ok, Key} -> {ok, Key};
        _ ->
            EnvKey = hd([K || Var <- ["ALIBABA_API_KEY", "DASHSCOPE_API_KEY"],
                              K <- [os:getenv(Var)], is_list(K), K =/= ""] ++ [none]),
            case EnvKey of
                none -> {error, <<"no Alibaba API key found">>};
                Val -> {ok, unicode:characters_to_binary(Val)}
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
