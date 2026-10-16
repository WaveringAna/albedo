-module(albedo_opencode_go).
%% OpenCode Go provider: OpenCode Console RFC 8628 device OAuth, live /models
%% discovery with disk cache, non-chat entitlement filtering, and key/account
%% pool resolution.

-include_lib("kernel/include/file.hrl").
-export([models/2, cached_models/1, reload/1, fetch_models/2,
         device_start/0, device_start/1, account/1, accounts/1, expire/2,
         access/3, limited/4]).

-define(DEFAULT_BASE_URL, <<"https://opencode.ai/inference/go/v1">>).
-define(DEFAULT_CONSOLE_URL, <<"https://opencode.ai/console">>).
-define(CLIENT_ID, <<"opencode-cli">>).
-define(STORE, <<"opencode-go">>).
-define(CATALOG_FILE, "opencode-go-models.json").
-define(CACHE_MAX_AGE_MS, 86400000). %% 24 hours
-define(FETCH_TIMEOUT_MS, 10000).
-define(REFRESH_SKEW_MS, 60000).
-define(EXPIRY_MARGIN_MS, 60000).
-define(SCOPE, <<"opencode-go">>).
%% Used when a spent quota names no reset time.
-define(DEFAULT_LIMIT_MS, 900000).
%% Tokens- and requests-per-minute limits clear within a minute.
-define(RATE_LIMIT_MS, 30000).

%% ---- OAuth device authorization (RFC 8628) ------------------------------

device_start() ->
    device_start(console_server()).

device_start(Server0) ->
    Server = string:trim(binary(Server0), trailing, "/"),
    Body = json:encode(#{<<"client_id">> => ?CLIENT_ID, <<"supports_org_scope">> => true}),
    case post_json(<<Server/binary, "/auth/device/code">>, Body) of
        {ok, 200, Response} ->
            try json:decode(Response) of
                #{<<"device_code">> := <<_, _/binary>> = DeviceCode,
                  <<"user_code">> := <<_, _/binary>> = UserCode,
                  <<"verification_uri_complete">> := <<_, _/binary>> = Verification} = Data ->
                    ExpiresIn = positive_int(maps:get(<<"expires_in">>, Data, 600), 600),
                    Interval = positive_int(maps:get(<<"interval">>, Data, 5), 5),
                    case verification_url(Server, Verification) of
                        {ok, Url} ->
                            Deadline = erlang:system_time(millisecond) + ExpiresIn * 1000,
                            Instructions = <<"Confirm code ", UserCode/binary,
                                             " in your browser and select Authorize.">>,
                            Complete = fun(Progress) ->
                                poll_device(Server, DeviceCode, Interval * 1000, Deadline, Progress)
                            end,
                            {ok, {Url, Instructions, Complete}};
                        Error -> Error
                    end;
                _ -> {error, <<"OpenCode Console returned an incomplete device-code response.">>}
            catch _:_ -> {error, <<"OpenCode Console returned an invalid device-code response.">>}
            end;
        {ok, Status, Response} ->
            {error, albedo_http:failure(<<"OpenCode Console device authorization">>, Status, Response)};
        {error, Reason} ->
            {error, Reason}
    end.

console_server() ->
    case os:getenv("OPENCODE_CONSOLE_SERVER") of
        Url when is_list(Url), Url =/= "" ->
            unicode:characters_to_binary(string:trim(Url, trailing, "/"));
        _ -> ?DEFAULT_CONSOLE_URL
    end.

verification_url(Server, Verification) ->
    case uri_string:parse(Verification) of
        #{scheme := Scheme, host := Host} when (Scheme =:= <<"http">> orelse Scheme =:= <<"https">>),
                                               Host =/= <<>> ->
            {ok, Verification};
        #{path := Path} = Rel when is_binary(Path), byte_size(Path) > 0 ->
            case uri_string:parse(Server) of
                #{scheme := Scheme, host := Host} = Base
                  when (Scheme =:= <<"http">> orelse Scheme =:= <<"https">>), Host =/= <<>> ->
                    PortPart = case maps:find(port, Base) of
                        {ok, Port} when is_integer(Port) -> [":", integer_to_binary(Port)];
                        _ -> []
                    end,
                    QueryPart = case maps:find(query, Rel) of
                        {ok, Q} when is_binary(Q), Q =/= <<>> -> ["?", Q];
                        _ -> []
                    end,
                    JoinedPath = case binary:at(Path, 0) of
                        $/ -> Path;
                        _ -> <<(maps:get(path, Base, <<>>))/binary, "/", Path/binary>>
                    end,
                    {ok, iolist_to_binary([Scheme, "://", Host, PortPart, JoinedPath, QueryPart])};
                _ -> {error, <<"Invalid OpenCode Console server URL.">>}
            end;
        _ -> {error, <<"Invalid OpenCode Console verification URL.">>}
    end.

poll_device(Server, DeviceCode, IntervalMs, Deadline, Progress) ->
    case erlang:system_time(millisecond) >= Deadline of
        true -> {error, <<"OpenCode Console device code expired.">>};
        false ->
            Progress(<<"Waiting for authorization in your browser…"/utf8>>),
            receive
                {input, _} -> ok
            after IntervalMs -> ok
            end,
            Body = json:encode(#{
                <<"grant_type">> => <<"urn:ietf:params:oauth:grant-type:device_code">>,
                <<"device_code">> => DeviceCode,
                <<"client_id">> => ?CLIENT_ID
            }),
            case post_json(<<Server/binary, "/auth/device/token">>, Body) of
                {ok, 200, Response} ->
                    try json:decode(Response) of
                        #{<<"access_token">> := <<_, _/binary>> = Access,
                          <<"refresh_token">> := <<_, _/binary>> = Refresh} = Token ->
                            ExpiresIn = positive_int(maps:get(<<"expires_in">>, Token, 3600), 3600),
                            GrantedOrg = optional_binary(maps:get(<<"org_id">>, Token, undefined)),
                            build_credential(Server, Access, Refresh, ExpiresIn, GrantedOrg);
                        #{<<"error">> := Error} ->
                            handle_poll_error(Server, DeviceCode, IntervalMs, Deadline, Progress, Error);
                        _ -> {error, <<"OpenCode Console token response is incomplete.">>}
                    catch _:_ -> {error, <<"OpenCode Console token response is invalid.">>}
                    end;
                {ok, Status, Response} when Status =:= 400; Status =:= 428 ->
                    case decode_error(Response) of
                        {ok, Error} ->
                            handle_poll_error(Server, DeviceCode, IntervalMs, Deadline, Progress, Error);
                        error ->
                            {error, albedo_http:failure(<<"OpenCode Console token exchange">>, Status, Response)}
                    end;
                {ok, Status, Response} ->
                    {error, albedo_http:failure(<<"OpenCode Console token exchange">>, Status, Response)};
                {error, Reason} ->
                    {error, Reason}
            end
    end.

handle_poll_error(Server, DeviceCode, IntervalMs, Deadline, Progress, <<"authorization_pending">>) ->
    poll_device(Server, DeviceCode, IntervalMs, Deadline, Progress);
handle_poll_error(Server, DeviceCode, IntervalMs, Deadline, Progress, <<"slow_down">>) ->
    poll_device(Server, DeviceCode, IntervalMs + 5000, Deadline, Progress);
handle_poll_error(_, _, _, _, _, <<"expired_token">>) ->
    {error, <<"OpenCode Console device code expired.">>};
handle_poll_error(_, _, _, _, _, <<"access_denied">>) ->
    {error, <<"OpenCode Console authorization was denied.">>};
handle_poll_error(_, _, _, _, _, Error) when is_binary(Error) ->
    {error, <<"OpenCode Console authorization failed: ", Error/binary>>}.

decode_error(Response) ->
    try json:decode(Response) of
        #{<<"error">> := Error} when is_binary(Error) -> {ok, Error};
        _ -> error
    catch _:_ -> error
    end.

build_credential(Server, Access, Refresh, ExpiresIn, GrantedOrg) ->
    User = fetch_user(Server, Access),
    Orgs = fetch_orgs(Server, Access),
    {OrgId, OrgName} = select_org(GrantedOrg, Orgs),
    Email = maps:get(<<"email">>, User, <<>>),
    AccountId = case maps:get(<<"id">>, User, <<>>) of
        <<>> -> case OrgId of <<>> -> token_id(Refresh); _ -> OrgId end;
        Uid -> Uid
    end,
    Base = #{
        <<"type">> => <<"oauth">>,
        <<"access">> => Access,
        <<"refresh">> => Refresh,
        <<"expires">> => erlang:system_time(millisecond) + ExpiresIn * 1000 - ?EXPIRY_MARGIN_MS,
        <<"accountId">> => AccountId,
        <<"server">> => Server
    },
    WithEmail = case Email of <<>> -> Base; _ -> Base#{<<"email">> => Email} end,
    WithOrg = case OrgId of <<>> -> WithEmail; _ -> WithEmail#{<<"orgId">> => OrgId} end,
    WithOrgName = case OrgName of <<>> -> WithOrg; _ -> WithOrg#{<<"orgName">> => OrgName} end,
    {ok, WithOrgName}.

fetch_user(Server, Access) ->
    case get_json(<<Server/binary, "/api/user">>, Access) of
        {ok, Map} when is_map(Map) ->
            maps:filter(fun(_, V) -> is_binary(V) andalso V =/= <<>> end,
                        maps:with([<<"id">>, <<"email">>], Map));
        _ -> #{}
    end.

fetch_orgs(Server, Access) ->
    case get_json(<<Server/binary, "/api/orgs">>, Access) of
        {ok, List} when is_list(List) ->
            Orgs = [{Id, Name} || #{<<"id">> := Id, <<"name">> := Name} <- List,
                                  is_binary(Id), Id =/= <<>>, is_binary(Name), Name =/= <<>>],
            lists:sort(fun({IdA, NameA}, {IdB, NameB}) ->
                {string:lowercase(NameA), IdA} =< {string:lowercase(NameB), IdB}
            end, Orgs);
        _ -> []
    end.

select_org(GrantedOrg, Orgs) when is_binary(GrantedOrg), GrantedOrg =/= <<>> ->
    case lists:keyfind(GrantedOrg, 1, Orgs) of
        {Id, Name} -> {Id, Name};
        false -> {GrantedOrg, <<>>}
    end;
select_org(_, [{Id, Name} | _]) ->
    {Id, Name};
select_org(_, []) ->
    {<<>>, <<>>}.

post_json(Url, Body) ->
    Headers = [{"accept", "application/json"}, {"user-agent", "albedo/1.0"}],
    albedo_http:fetch(post, Url, Headers, {"application/json", Body}).

get_json(Url, Access) ->
    Headers = [{"authorization", "Bearer " ++ text(Access)},
               {"accept", "application/json"},
               {"user-agent", "albedo/1.0"}],
    case albedo_http:fetch(get, Url, Headers, none) of
        {ok, 200, Body} ->
            try {ok, json:decode(Body)} catch _:_ -> error end;
        _ -> error
    end.

positive_int(Value, _) when is_integer(Value), Value > 0 -> Value;
positive_int(Value, _) when is_float(Value), Value > 0 -> round(Value);
positive_int(_, Default) -> Default.

optional_binary(Value) when is_binary(Value), Value =/= <<>> -> Value;
optional_binary(_) -> <<>>.

%% ---- /login & quota account representation ------------------------------

account(Credential) when is_map(Credential) ->
    Selected = maps:get(<<"selected">>, Credential, false) =:= true,
    Email = optional_binary(maps:get(<<"email">>, Credential, <<>>)),
    OrgName = optional_binary(maps:get(<<"orgName">>, Credential, <<>>)),
    AccountId = optional_binary(maps:get(<<"accountId">>, Credential, <<>>)),
    BaseLabel = first_nonempty([Email, OrgName, AccountId, <<"OpenCode Go">>]),
    Label = case Email =/= <<>> andalso OrgName =/= <<>> of
        true -> <<Email/binary, " · "/utf8, OrgName/binary>>;
        false -> BaseLabel
    end,
    Now = erlang:system_time(millisecond),
    Detail = iolist_to_binary([
        <<"opencode go account">>,
        case Selected of true -> <<" · selected"/utf8>>; false -> <<>> end,
        case albedo_accounts:limited(Credential, Now) of
            true -> [<<" · limited until "/utf8>>, albedo_accounts:local_time(maps:get(<<"limitedUntil">>, Credential))];
            false -> <<>>
        end
    ]),
    {account, credential_identity(Credential), Label, Detail, Selected};
account(_) ->
    {account, <<>>, <<"invalid OpenCode Go account">>, <<>>, false}.

credential_identity(Credential) when is_map(Credential) ->
    AccountId = optional_binary(maps:get(<<"accountId">>, Credential, <<>>)),
    OrgId = optional_binary(maps:get(<<"orgId">>, Credential, <<>>)),
    Email = optional_binary(maps:get(<<"email">>, Credential, <<>>)),
    case AccountId =/= <<>> andalso OrgId =/= <<>> andalso AccountId =/= OrgId of
        true -> <<AccountId/binary, ":", OrgId/binary>>;
        false ->
            first_nonempty([
                AccountId,
                OrgId,
                Email,
                token_id(optional_binary(maps:get(<<"refresh">>, Credential,
                    maps:get(<<"access">>, Credential,
                        maps:get(<<"apiKey">>, Credential,
                            maps:get(<<"key">>, Credential, <<>>))))))
            ])
    end.

first_nonempty([]) -> <<>>;
first_nonempty([<<_, _/binary>> = V | _]) -> V;
first_nonempty([_ | Rest]) -> first_nonempty(Rest).

token_id(<<>>) -> <<>>;
token_id(Token) ->
    binary:encode_hex(binary:part(crypto:hash(sha256, Token), 0, 8), lowercase).

%% Every OpenCode Go OAuth account for the quota poller, refreshed the way
%% requests refresh it.
accounts(Home0) ->
    Path = albedo_credentials:creds_path(text(Home0)),
    case albedo_credentials:accounts(Path) of
        {ok, Data} ->
            [quota_entry(refreshed_oauth(Path, V))
             || V <- albedo_credentials:oauth(Data, ?STORE),
                credential_identity(V) =/= <<>>];
        _ -> []
    end.

quota_entry(Value) ->
    {account, Id, Label, _, _} = account(Value),
    #{
        <<"label">> => first_nonempty([Label, Id]),
        <<"access">> => optional_binary(maps:get(<<"access">>, Value, <<>>)),
        <<"accountId">> => Id,
        <<"email">> => optional_binary(maps:get(<<"email">>, Value, <<>>))
    }.

expire(Home0, Access0) ->
    albedo_credentials:expire_access(albedo_credentials:creds_path(text(Home0)), ?STORE, binary(Access0)).

%% ---- models catalog -----------------------------------------------------

%% Returns any cached model IDs without reaching the network.
cached_models(Home0) ->
    read_cache(filename:join(text(Home0), ?CATALOG_FILE)).

%% Returns the entitled model IDs for OpenCode Go: reads fresh disk cache,
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
        [] -> {error, <<"no OpenCode Go API key found">>}
    end.

fallback_cache_or_default(CachePath) ->
    case read_cache(CachePath) of
        {ok, Ids} when Ids =/= [] -> {ok, Ids};
        _ -> {ok, []}
    end.

%% Live GET to ${BaseUrl}/models with optional Bearer auth.
fetch_models(BaseUrl0, ApiKey0) ->
    BaseUrl = text(BaseUrl0),
    ApiKey = text(ApiKey0),
    Url = string:trim(BaseUrl, trailing, "/") ++ "/models",
    Auth = case ApiKey of
        "" -> [];
        _ -> [{"authorization", "Bearer " ++ ApiKey}]
    end,
    Headers = Auth ++ [
        {"accept", "application/json"},
        {"user-agent", "albedo/1.0"}
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

%% Non-chat entitlement filter: skips image generation, TTS, audio, and realtime routes.
is_chat_model(<<"auto">>) -> false;
is_chat_model(Id) when is_binary(Id) ->
    case binary:match(Id, [
        <<"audio">>,
        <<"tts">>,
        <<"realtime">>,
        <<"image">>,
        <<"asr">>
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

%% ---- key & OAuth account pool -------------------------------------------

%% The session's credential as {BaseUrl, ApiKey, OrgId}. Every OpenCode Go
%% credential albedo can see is a sibling: the profile's own key or selected
%% OAuth account first, then sibling opencode-go profiles, creds.json's
%% "opencode-go" accounts/keys, and the environment. Limited entries go last.
access(Home0, Profile0, Session0) ->
    Home = text(Home0),
    Profile = binary(Profile0),
    Session = binary(Session0),
    case pool_for_profile(Home, Profile) of
        {error, Reason} ->
            {error, Reason};
        {ok, []} ->
            {error, <<"OpenCode Go is not authenticated; run /login to sign in or set OPENCODE_API_KEY">>};
        {ok, Keys} ->
            [First | _] = albedo_accounts:order(?SCOPE, Keys, Session, fun id/1),
            albedo_accounts:remember(?SCOPE, Session, id(First)),
            {ok, {maps:get(<<"baseUrl">>, First),
                  maps:get(<<"apiKey">>, First),
                  maps:get(<<"orgId">>, First, <<>>)}}
    end.

%% Records a 429 against the key that received it. Every OpenCode Go 429 is a
%% limit; one naming a spent quota or usage limit lasts, the rest are
%% per-minute rate limits.
limited(Home0, Profile0, Key, Body0) ->
    Body = binary(Body0),
    Lasting = lists:any(fun(Mark) -> binary:match(Body, Mark) =/= nomatch end,
                        [<<"insufficient_quota">>, <<"exceeded your current quota">>,
                         <<"usage_limit">>, <<"UsageLimit">>, <<"RateLimit">>,
                         <<"monthly">>, <<"weekly">>, <<"rolling">>, <<"exhausted">>]),
    Until = erlang:system_time(millisecond) + case Lasting of
        true -> ?DEFAULT_LIMIT_MS;
        false -> ?RATE_LIMIT_MS
    end,
    Id = id(#{<<"apiKey">> => Key}),
    ok = albedo_accounts:note(?SCOPE, Id, Until),
    Now = erlang:system_time(millisecond),
    Next = [K || K <- pool(text(Home0), binary(Profile0)), id(K) =/= Id,
                 not albedo_accounts:limited(K, Now)],
    UntilText = albedo_accounts:local_time(Until),
    NextName = case Next of [#{<<"name">> := Name} | _] -> Name; [] -> <<>> end,
    {ok, {limited, <<>>, UntilText, NextName, Lasting}}.

pool(Home, Profile) ->
    case pool_for_profile(Home, Profile) of
        {ok, Keys} -> Keys;
        {error, _} -> []
    end.

pool_for_profile(Home, Profile) ->
    {ProfileUrl, ProfileKey, AccountId} = profile_settings(Home, Profile),
    BaseUrl = case ProfileUrl of <<>> -> resolve_base_url(<<>>); Url -> Url end,
    Path = albedo_credentials:creds_path(Home),
    case AccountId of
        <<_, _/binary>> ->
            case selected_oauth_entry(Path, Profile, BaseUrl, AccountId) of
                {ok, Entry} -> {ok, [Entry]};
                Error -> Error
            end;
        _ ->
            AccountEntries = account_entries(Path, BaseUrl),
            EnvEntries = [{list_to_binary(Var), BaseUrl, unicode:characters_to_binary(K), <<>>}
                          || Var <- ["OPENCODE_GO_API_KEY", "OPENCODE_API_KEY"],
                             K <- [os:getenv(Var)], is_list(K), K =/= ""],
            Own = case ProfileKey of
                <<>> ->
                    case AccountEntries ++ EnvEntries of
                        [{_, U, K, Org} | _] -> [{Profile, U, K, Org}];
                        [] -> []
                    end;
                K -> [{Profile, BaseUrl, K, <<>>}]
            end,
            Siblings = [{Name, case U of <<>> -> BaseUrl; _ -> U end, K, <<>>}
                        || {Name, U, K} <- opencode_go_profiles(Home), Name =/= Profile]
                ++ AccountEntries
                ++ EnvEntries,
            Unique = lists:foldl(fun({_, _, K, _} = Entry, Acc) ->
                case lists:keymember(K, 3, Acc) of true -> Acc; false -> Acc ++ [Entry] end
            end, [], Own ++ Siblings),
            {ok, [#{<<"name">> => Name, <<"baseUrl">> => U, <<"apiKey">> => K, <<"orgId">> => Org,
                    <<"selected">> => I =:= 1 andalso Own =/= [],
                    <<"limitedUntil">> => albedo_accounts:noted(?SCOPE, id(#{<<"apiKey">> => K}))}
                  || {I, {Name, U, K, Org}} <- lists:enumerate(Unique)]}
    end.

selected_oauth_entry(Path, Profile, BaseUrl, AccountId) ->
    case albedo_credentials:accounts(Path) of
        {ok, Data} ->
            Stored = albedo_credentials:values(Data, ?STORE),
            case [V || V <- Stored, maps:get(<<"_albedo_account_id">>, V, null) =:= AccountId] of
                [Chosen | _] ->
                    case resolve_account_entry(Path, BaseUrl, Chosen) of
                        {true, {Label, U, K, Org}} ->
                            Name = case Profile of <<>> -> Label; _ -> Profile end,
                            {ok, #{<<"name">> => Name, <<"baseUrl">> => U, <<"apiKey">> => K, <<"orgId">> => Org,
                                   <<"selected">> => true,
                                   <<"limitedUntil">> => albedo_accounts:noted(?SCOPE, id(#{<<"apiKey">> => K}))}};
                        false ->
                            {error, <<"Profile's selected OpenCode Go account could not be refreshed; run /login">>}
                    end;
                [] ->
                    {error, <<"Profile's selected account is unavailable">>}
            end;
        _ ->
            {error, <<"Profile's selected account is unavailable">>}
    end.

%% A key's id in limit bookkeeping, never the key itself.
id(#{<<"apiKey">> := Key}) ->
    token_id(Key).

opencode_go_profiles(Home) ->
    case albedo_credentials:config(Home) of
        {ok, #{<<"providers">> := Providers}} when is_map(Providers) ->
            [{Name, maps:get(<<"baseUrl">>, P, <<>>), Key}
             || {Name, #{<<"extension">> := <<"opencode-go">>, <<"apiKey">> := <<_, _/binary>> = Key} = P}
                    <- lists:sort(maps:to_list(Providers))];
        _ -> []
    end.

account_entries(Path, BaseUrl) ->
    case albedo_credentials:accounts(Path) of
        {ok, #{?STORE := List}} when is_list(List) ->
            lists:filtermap(fun(V) -> resolve_account_entry(Path, BaseUrl, V) end, List);
        {ok, #{?STORE := One}} ->
            lists:filtermap(fun(V) -> resolve_account_entry(Path, BaseUrl, V) end, [One]);
        _ -> []
    end.

resolve_account_entry(_, BaseUrl, <<_, _/binary>> = Key) ->
    {true, {<<"creds.json">>, BaseUrl, Key, <<>>}};
resolve_account_entry(Path, BaseUrl, #{<<"type">> := <<"oauth">>} = V) ->
    Current = refreshed_oauth(Path, V),
    case optional_binary(maps:get(<<"access">>, Current, <<>>)) of
        <<>> -> false;
        Access ->
            {account, _, Label, _, _} = account(Current),
            OrgId = optional_binary(maps:get(<<"orgId">>, Current, <<>>)),
            {true, {first_nonempty([Label, <<"creds.json">>]), BaseUrl, Access, OrgId}}
    end;
resolve_account_entry(_, BaseUrl, #{<<"key">> := <<_, _/binary>> = Key} = V) ->
    {true, {<<"creds.json">>, BaseUrl, Key, optional_binary(maps:get(<<"orgId">>, V, <<>>))}};
resolve_account_entry(_, BaseUrl, #{<<"apiKey">> := <<_, _/binary>> = Key} = V) ->
    {true, {<<"creds.json">>, BaseUrl, Key, optional_binary(maps:get(<<"orgId">>, V, <<>>))}};
resolve_account_entry(_, BaseUrl, #{<<"access">> := <<_, _/binary>> = Key} = V) ->
    {true, {<<"creds.json">>, BaseUrl, Key, optional_binary(maps:get(<<"orgId">>, V, <<>>))}};
resolve_account_entry(_, _, _) ->
    false.

refreshed_oauth(Path, Value) ->
    Expires = maps:get(<<"expires">>, Value, 0),
    Refresh = optional_binary(maps:get(<<"refresh">>, Value, <<>>)),
    case is_integer(Expires) andalso Expires > erlang:system_time(millisecond) + ?REFRESH_SKEW_MS of
        true -> Value;
        false when Refresh =:= <<>> -> Value;
        false ->
            Id = credential_identity(Value),
            case albedo_settings_lock:with_lock(filename:dirname(Path),
                    fun() -> refresh_locked(Path, Id) end,
                    fun() -> {error, busy} end) of
                {ok, Updated} -> Updated;
                _ -> Value
            end
    end.

refresh_locked(Path, Id) ->
    case albedo_credentials:accounts(Path) of
        {ok, Data} ->
            Values = albedo_credentials:values(Data, ?STORE),
            case [V || V <- Values, is_map(V), credential_identity(V) =:= Id] of
                [Current | _] ->
                    case maps:get(<<"expires">>, Current, 0) > erlang:system_time(millisecond) + ?REFRESH_SKEW_MS of
                        true -> {ok, Current};
                        false -> refresh_current(Path, Data, Values, Current, Id)
                    end;
                [] -> {error, not_found}
            end;
        Error -> Error
    end.

refresh_current(Path, Data, Values, Current, Id) ->
    Server = case optional_binary(maps:get(<<"server">>, Current, <<>>)) of
        <<>> -> console_server();
        S -> string:trim(S, trailing, "/")
    end,
    Refresh = optional_binary(maps:get(<<"refresh">>, Current, <<>>)),
    Body = json:encode(#{
        <<"grant_type">> => <<"refresh_token">>,
        <<"refresh_token">> => Refresh,
        <<"client_id">> => ?CLIENT_ID
    }),
    case post_json(<<Server/binary, "/auth/device/token">>, Body) of
        {ok, 200, Response} ->
            try json:decode(Response) of
                #{<<"access_token">> := <<_, _/binary>> = Access,
                  <<"refresh_token">> := <<_, _/binary>> = NewRefresh} = Token ->
                    ExpiresIn = positive_int(maps:get(<<"expires_in">>, Token, 3600), 3600),
                    Updated0 = Current#{
                        <<"type">> => <<"oauth">>,
                        <<"access">> => Access,
                        <<"refresh">> => NewRefresh,
                        <<"expires">> => erlang:system_time(millisecond) + ExpiresIn * 1000 - ?EXPIRY_MARGIN_MS
                    },
                    Updated = case optional_binary(maps:get(<<"org_id">>, Token, undefined)) of
                        <<>> -> Updated0;
                        OrgId -> Updated0#{<<"orgId">> => OrgId}
                    end,
                    Replaced = [case is_map(V) andalso credential_identity(V) =:= Id of
                        true -> Updated;
                        false -> V
                    end || V <- Values],
                    case albedo_credentials:put_accounts(Path, albedo_credentials:put_values(Data, ?STORE, Replaced)) of
                        ok -> {ok, Updated};
                        Error -> Error
                    end;
                _ -> {error, invalid_refresh_response}
            catch _:_ -> {error, invalid_refresh_response}
            end;
        _ -> {error, refresh_failed}
    end.

resolve_base_url(<<>>) ->
    case os:getenv("OPENCODE_GO_BASE_URL") of
        Url when is_list(Url), Url =/= "" -> unicode:characters_to_binary(string:trim(Url, trailing, "/"));
        _ -> ?DEFAULT_BASE_URL
    end;
resolve_base_url(Url) when is_binary(Url) ->
    string:trim(Url, trailing, "/").

profile_settings(Home, Profile) ->
    case albedo_credentials:config(Home) of
        {ok, #{<<"providers">> := #{Profile := P}}} when is_map(P) ->
            Bin = fun(K) -> case maps:get(K, P, <<>>) of B when is_binary(B) -> B; _ -> <<>> end end,
            {Bin(<<"baseUrl">>), Bin(<<"apiKey">>), Bin(<<"accountId">>)};
        _ -> {<<>>, <<>>, <<>>}
    end.

text(Val) when is_binary(Val) -> unicode:characters_to_list(Val);
text(Val) when is_list(Val) -> Val.

binary(Val) when is_list(Val) -> unicode:characters_to_binary(Val);
binary(Val) when is_binary(Val) -> Val.
