-module(albedo_antigravity).
%% Antigravity credentials, request identity, and Cloud Code Assist schemas.

-include_lib("kernel/include/file.hrl").
-export([access/1, encode/1, normalize_schema/1, session_number/1, uuid/1,
         call_id/0, now_ms/0, user_agent/1, discovered/1, refresh/1, reload/1, expire/2,
         exchange/4, discover/3, account/1, client_id/0]).

-define(KEY, <<"google-antigravity">>).
-define(CLIENT_ID, <<"MTA3MTAwNjA2MDU5MS10bWhzc2luMmgyMWxjcmUyMzV2dG9sb2poNGc0MDNlcC5hcHBzLmdvb2dsZXVzZXJjb250ZW50LmNvbQ==">>).
-define(CLIENT_SECRET, <<"R09DU1BYLUs1OEZXUjQ4NkxkTEoxbUxCOHNYQzR6NnFEQWY=">>).
-define(TOKEN_URL, "https://oauth2.googleapis.com/token").
-define(REFRESH_SKEW_MS, 60000).
%% Google access tokens live an hour; store them as expiring five minutes early.
-define(EXPIRY_MARGIN_MS, 300000).
-define(HTTP_TIMEOUT_MS, 15000).
-define(CATALOG, "antigravity.json").
-define(CATALOG_MAX_AGE_MS, 21600000).
-define(REFRESH_PROCESS, albedo_antigravity_refresh).
-define(DEFAULT_VERSION, <<"2.16.0">>).
-define(ENDPOINT, "https://daily-cloudcode-pa.googleapis.com").
-define(MANIFEST_URL, "https://antigravity-hub-auto-updater-974169037036.us-central1.run.app/manifest/latest-arm64-mac.yml").
-define(SIGNED_OUT, <<"Antigravity is not authenticated; run /login and add a Google account">>).

%% ---- credentials --------------------------------------------------------

access(Home) ->
    Path = filename:join(unicode:characters_to_list(Home), "auth.json"),
    case albedo_credentials:read(Path) of
        {ok, Data} -> first_usable(order(credentials(Data)), Path);
        {error, _} -> {error, ?SIGNED_OUT}
    end.

first_usable([], _) -> {error, ?SIGNED_OUT};
first_usable([Credential | Rest], Path) ->
    Outcome = case usable(Credential) of
        fresh -> {ok, Credential};
        stale -> albedo_credentials:with_lock(Path,
                     fun() -> refresh_current(Path, identity(Credential)) end,
                     fun() -> {error, <<"credential store is busy">>} end);
        invalid -> {error, invalid}
    end,
    case Outcome of
        {ok, Access} -> {ok, iolist_to_binary(json:encode(maps:with(
                            [<<"access">>, <<"projectId">>, <<"email">>], Access)))};
        {error, _} -> first_usable(Rest, Path)
    end.

credentials(Data) ->
    Values = case maps:get(?KEY, Data, []) of
        List when is_list(List) -> List;
        One -> [One]
    end,
    [V || V <- Values, is_map(V), maps:get(<<"type">>, V, <<>>) =:= <<"oauth">>].

order(Values) ->
    {Selected, Rest} = lists:partition(fun(V) -> maps:get(<<"selected">>, V, false) =:= true end, Values),
    Selected ++ Rest.

usable(Credential) ->
    Present = fun(Key) -> case maps:get(Key, Credential, <<>>) of
                              <<_, _/binary>> -> true;
                              _ -> false
                          end end,
    Expires = maps:get(<<"expires">>, Credential, 0),
    case lists:all(Present, [<<"access">>, <<"refresh">>, <<"projectId">>]) andalso is_integer(Expires) of
        false -> invalid;
        true ->
            case Expires > erlang:system_time(millisecond) + ?REFRESH_SKEW_MS of
                true -> fresh;
                false -> stale
            end
    end.

identity(Credential) ->
    case maps:get(<<"email">>, Credential, <<>>) of
        <<_, _/binary>> = Email -> {email, string:lowercase(Email)};
        _ -> {refresh, maps:get(<<"refresh">>, Credential, <<>>)}
    end.

%% After a 401 the stored token is marked expired, so the next turn refreshes
%% it; a revoked refresh token then leaves the account signed out.
expire(Home, Access) ->
    Path = filename:join(unicode:characters_to_list(Home), "auth.json"),
    albedo_credentials:with_lock(Path, fun() ->
        case albedo_credentials:read(Path) of
            {ok, #{?KEY := Stored} = Data} ->
                Expire = fun(#{<<"access">> := A} = V) when A =:= Access -> V#{<<"expires">> => 0};
                            (V) -> V
                         end,
                Updated = case Stored of
                    List when is_list(List) -> lists:map(Expire, List);
                    One -> Expire(One)
                end,
                case Updated =:= Stored of
                    true -> nil;
                    false -> _ = albedo_credentials:write(Path, Data#{?KEY => Updated}), nil
                end;
            _ -> nil
        end
    end, fun() -> nil end).

%% Re-read under the lock: a concurrent session may already have refreshed.
refresh_current(Path, Identity) ->
    case albedo_credentials:read(Path) of
        {ok, Data} ->
            Values = maps:get(?KEY, Data, []),
            Listed = is_list(Values),
            All = case Listed of true -> Values; false -> [Values] end,
            case [V || V <- credentials(Data), identity(V) =:= Identity] of
                [] -> {error, <<"credential changed during refresh">>};
                [Current | _] ->
                    case usable(Current) of
                        fresh -> {ok, Current};
                        invalid -> {error, <<"stored Antigravity credential is invalid">>};
                        stale ->
                            case refresh_token(Current) of
                                {ok, Updated} ->
                                    Replaced = [case is_map(V) andalso identity(V) =:= Identity of
                                                    true -> Updated;
                                                    false -> V
                                                end || V <- All],
                                    Stored = case Listed of true -> Replaced; false -> hd(Replaced) end,
                                    case albedo_credentials:write(Path, Data#{?KEY => Stored}) of
                                        ok -> {ok, Updated};
                                        {error, _} -> {error, <<"could not persist refreshed Antigravity credential">>}
                                    end;
                                Error -> Error
                            end
                    end
            end;
        Error -> Error
    end.

refresh_token(Credential) ->
    Body = uri_string:compose_query([
        {<<"client_id">>, base64:decode(?CLIENT_ID)},
        {<<"client_secret">>, base64:decode(?CLIENT_SECRET)},
        {<<"refresh_token">>, maps:get(<<"refresh">>, Credential)},
        {<<"grant_type">>, <<"refresh_token">>}
    ]),
    _ = application:ensure_all_started(inets),
    _ = application:ensure_all_started(ssl),
    Request = {?TOKEN_URL, [{"accept", "application/json"}],
               "application/x-www-form-urlencoded", binary_to_list(Body)},
    Options = [{timeout, ?HTTP_TIMEOUT_MS}, {connect_timeout, 10000},
               {ssl, albedo_credentials:tls_options("oauth2.googleapis.com")}],
    case httpc:request(post, Request, Options, [{body_format, binary}]) of
        {ok, {{_, 200, _}, _, Response}} -> refreshed(Response, Credential);
        {ok, {{_, Status, _}, _, _}} ->
            {error, iolist_to_binary(io_lib:format("Antigravity token refresh failed (~B)", [Status]))};
        _ -> {error, <<"Antigravity token refresh failed">>}
    end.

refreshed(Response, Previous) ->
    try json:decode(Response) of
        #{<<"access_token">> := <<_, _/binary>> = Access, <<"expires_in">> := In} = Token
          when is_integer(In), In > 0 ->
            Refresh = case maps:get(<<"refresh_token">>, Token, <<>>) of
                <<_, _/binary>> = Rotated -> Rotated;
                _ -> maps:get(<<"refresh">>, Previous)
            end,
            {ok, Previous#{
                <<"access">> => Access,
                <<"refresh">> => Refresh,
                <<"expires">> => erlang:system_time(millisecond) + In * 1000 - ?EXPIRY_MARGIN_MS
            }};
        _ -> {error, <<"Antigravity token refresh response is incomplete">>}
    catch
        _:_ -> {error, <<"Antigravity token refresh response is invalid">>}
    end.

%% ---- sign-in ------------------------------------------------------------

client_id() -> base64:decode(?CLIENT_ID).

-define(FREE_TIER, <<"free-tier">>).
-define(ONBOARD_BUDGET_MS, 30000).
-define(METADATA, #{<<"ideType">> => <<"ANTIGRAVITY">>}).

%% Endpoints is the Gleam record {endpoints, TokenUrl, UserinfoUrl, CloudCodeUrl}.
exchange(Code, Redirect, Progress, {endpoints, TokenUrl, UserinfoUrl, _} = Endpoints) ->
    Form = uri_string:compose_query([
        {<<"client_id">>, base64:decode(?CLIENT_ID)},
        {<<"client_secret">>, base64:decode(?CLIENT_SECRET)},
        {<<"code">>, Code},
        {<<"grant_type">>, <<"authorization_code">>},
        {<<"redirect_uri">>, Redirect}
    ]),
    case http(post, TokenUrl, [], {"application/x-www-form-urlencoded", Form}) of
        {ok, 200, Body} ->
            case json:decode(Body) of
                #{<<"access_token">> := <<_, _/binary>> = Access,
                  <<"refresh_token">> := <<_, _/binary>> = Refresh,
                  <<"expires_in">> := In} when is_integer(In), In > 0 ->
                    Progress(<<"getting user info">>),
                    Email = email(UserinfoUrl, Access),
                    case discover(Access, Endpoints, Progress) of
                        {ok, Project} ->
                            {ok, json:encode(maps:merge(Email, #{
                                <<"type">> => <<"oauth">>,
                                <<"access">> => Access,
                                <<"refresh">> => Refresh,
                                <<"expires">> => erlang:system_time(millisecond) + In * 1000 - ?EXPIRY_MARGIN_MS,
                                <<"projectId">> => Project
                            }))};
                        {error, Reason} -> {error, verification(Reason, Email)}
                    end;
                #{<<"access_token">> := _} -> {error, <<"no refresh token received; sign in again">>};
                _ -> {error, <<"Antigravity token exchange response is incomplete">>}
            end;
        {ok, Status, Body} -> {error, failure(<<"Antigravity token exchange">>, Status, Body)};
        {error, Reason} -> {error, Reason}
    end.

email(Url, Access) ->
    case http(get, Url, [{"authorization", "Bearer " ++ binary_to_list(Access)}], none) of
        {ok, 200, Body} ->
            try json:decode(Body) of
                #{<<"email">> := <<_, _/binary>> = Email} -> #{<<"email">> => string:lowercase(Email)};
                _ -> #{}
            catch _:_ -> #{} end;
        _ -> #{}
    end.

%% Finds the account's Cloud Code Assist project, provisioning the free tier
%% first when the account has none, as the Antigravity IDE does.
discover(Access, {endpoints, _, _, CloudCode}, Progress) ->
    Progress(<<"checking cloud code assist account status">>),
    Call = fun(Method, Path, Body) -> cloud_code(Method, CloudCode, Path, Access, Body) end,
    maybe
        {ok, Initial} ?= load(Call),
        ok ?= eligible(Initial),
        ok ?= case maps:get(<<"currentTier">>, Initial, null) of
            null ->
                Progress(<<"provisioning the antigravity free tier">>),
                onboard(Call, erlang:monotonic_time(millisecond) + ?ONBOARD_BUDGET_MS);
            _ -> ok
        end,
        Progress(<<"refreshing cloud code assist project">>),
        {ok, Refreshed} ?= load(Call),
        case maps:get(<<"cloudaicompanionProject">>, Refreshed, <<>>) of
            <<_, _/binary>> = Project -> {ok, Project};
            _ -> {error, <<"loadCodeAssist did not return a cloudaicompanionProject">>}
        end
    end.

%% A free account answers loadCodeAssist without its project until asked with it.
load(Call) ->
    maybe
        {ok, First} ?= Call(post, <<"/v1internal:loadCodeAssist">>, #{<<"metadata">> => ?METADATA}),
        case {maps:get(<<"paidTier">>, First, null), maps:get(<<"cloudaicompanionProject">>, First, <<>>)} of
            {null, <<_, _/binary>> = Project} ->
                Call(post, <<"/v1internal:loadCodeAssist">>,
                     #{<<"cloudaicompanionProject">> => Project, <<"metadata">> => ?METADATA});
            _ -> {ok, First}
        end
    end.

eligible(Response) ->
    Allowed = [T || #{<<"id">> := T} <- maps:get(<<"allowedTiers">>, Response, [])],
    Ineligible = [T || #{<<"tierId">> := ?FREE_TIER, <<"reasonMessage">> := <<_, _/binary>>} = T
                           <- maps:get(<<"ineligibleTiers">>, Response, [])],
    case {lists:member(?FREE_TIER, Allowed), Ineligible} of
        {false, [#{<<"reasonMessage">> := Reason} = Tier | _]} ->
            case maps:get(<<"validationUrl">>, Tier, <<>>) of
                <<_, _/binary>> = Url -> {error, <<Reason/binary, "\n", Url/binary>>};
                _ -> {error, Reason}
            end;
        _ -> ok
    end.

onboard(Call, Deadline) ->
    maybe
        {ok, Operation} ?= Call(post, <<"/v1internal:onboardUser">>,
                                #{<<"tierId">> => ?FREE_TIER, <<"metadata">> => ?METADATA}),
        settle(Call, Operation, Deadline)
    end.

settle(_, #{<<"done">> := true, <<"error">> := #{} = Error}, _) ->
    {error, <<"onboardUser operation failed: ", (maps:get(<<"message">>, Error, <<"unknown error">>))/binary>>};
settle(_, #{<<"done">> := true, <<"response">> := #{}}, _) -> ok;
settle(_, #{<<"done">> := true}, _) -> {error, <<"onboardUser returned no response">>};
settle(Call, #{<<"name">> := <<_, _/binary>> = Name}, Deadline) ->
    case erlang:monotonic_time(millisecond) + 1000 > Deadline of
        true -> {error, <<"onboardUser timed out">>};
        false ->
            timer:sleep(1000),
            maybe
                {ok, Operation} ?= Call(get, <<"/v1internal/", Name/binary>>, none),
                settle(Call, Operation, Deadline)
            end
    end;
settle(_, _, _) -> {error, <<"onboardUser returned an operation without a name">>}.

cloud_code(Method, Base, Path, Access, Body) ->
    Headers = [{"authorization", "Bearer " ++ binary_to_list(Access)},
               {"user-agent", binary_to_list(sign_in_user_agent())}],
    Encoded = case Body of
        none -> none;
        _ -> {"application/json", json:encode(Body)}
    end,
    case http(Method, <<Base/binary, Path/binary>>, Headers, Encoded) of
        {ok, 200, Response} ->
            try {ok, json:decode(Response)}
            catch _:_ -> {error, <<"Cloud Code Assist returned invalid JSON">>}
            end;
        {ok, Status, Response} -> {error, failure(Path, Status, Response)};
        Error -> Error
    end.

failure(What, Status, Body) ->
    iolist_to_binary(io_lib:format("~s failed (~B): ~s", [What, Status, binary:part(Body, 0, min(byte_size(Body), 2048))])).

%% Google asks some accounts to verify before Cloud Code Assist serves them.
verification(Reason, Email) ->
    case binary:match(Reason, <<"VALIDATION_REQUIRED">>) of
        nomatch -> Reason;
        _ ->
            Url = case re:run(Reason, <<"\"validation_url\"\\s*:\\s*\"([^\"]+)\"">>, [{capture, all_but_first, binary}]) of
                {match, [Found]} -> Found;
                _ -> <<"https://accounts.google.com">>
            end,
            For = case Email of #{<<"email">> := E} -> <<" for ", E/binary>>; _ -> <<>> end,
            <<"Account verification required", For/binary, ". Visit ", Url/binary, " to continue, then sign in again.">>
    end.

http(Method, Url0, Headers, Body) ->
    _ = application:ensure_all_started(inets),
    _ = application:ensure_all_started(ssl),
    Url = unicode:characters_to_list(Url0),
    Host = unicode:characters_to_list(maps:get(host, uri_string:parse(Url), "")),
    Request = case Body of
        none -> {Url, Headers};
        {Type, Payload} -> {Url, Headers, Type, iolist_to_binary(Payload)}
    end,
    Tls = case uri_string:parse(Url) of
        #{scheme := "https"} -> [{ssl, albedo_credentials:tls_options(Host)}];
        _ -> []
    end,
    case httpc:request(Method, Request, [{timeout, 30000}, {connect_timeout, 10000} | Tls],
                       [{body_format, binary}]) of
        {ok, {{_, Status, _}, _, Response}} -> {ok, Status, Response};
        {error, _} -> {error, <<"could not reach ", (unicode:characters_to_binary(Host))/binary>>}
    end.

%% How /login lists a stored Antigravity account.
account(Credential) when is_map(Credential) ->
    Id = case identity(Credential) of
        {email, Email} -> Email;
        {refresh, Refresh} -> binary:encode_hex(binary:part(crypto:hash(sha256, Refresh), 0, 8), lowercase)
    end,
    Label = case maps:get(<<"email">>, Credential, <<>>) of
        <<_, _/binary>> = Email0 -> Email0;
        _ -> <<"antigravity account">>
    end,
    Selected = maps:get(<<"selected">>, Credential, false) =:= true,
    Detail = case Selected of
        true -> <<"antigravity account · selected"/utf8>>;
        false -> <<"antigravity account">>
    end,
    {account, Id, Label, Detail, Selected};
account(_) -> {account, <<>>, <<"invalid antigravity account">>, <<>>, false}.

%% ---- request identity ---------------------------------------------------

encode(Value) -> json:encode(Value).

%% The negative decimal session number the antigravity/hub client sends:
%% the first 63 bits of a SHA-256 digest.
session_number(Seed) ->
    <<Value:64, _/binary>> = crypto:hash(sha256, Seed),
    <<"-", (integer_to_binary(Value band ((1 bsl 63) - 1)))/binary>>.

uuid(Seed) ->
    <<A:32, B:16, _:4, C:12, _:2, D:14, E:48, _/binary>> = crypto:hash(sha256, Seed),
    iolist_to_binary(io_lib:format("~8.16.0b-~4.16.0b-4~3.16.0b-~4.16.0b-~12.16.0b",
                                   [A, B, C, 16#8000 bor D, E])).

call_id() ->
    <<"call_", (binary:encode_hex(crypto:strong_rand_bytes(9), lowercase))/binary>>.

now_ms() -> erlang:system_time(millisecond).

%% The backend gates newer models on this client version; os and arch are
%% pinned to the reference darwin/arm64 build regardless of the host.
user_agent(Home) ->
    Version = case os:getenv("ALBEDO_ANTIGRAVITY_VERSION") of
        Pinned when is_list(Pinned), Pinned =/= "" -> unicode:characters_to_binary(Pinned);
        _ -> cached_version(Home)
    end,
    user_agent_for(Version).

sign_in_user_agent() ->
    case os:getenv("ALBEDO_ANTIGRAVITY_VERSION") of
        Pinned when is_list(Pinned), Pinned =/= "" -> user_agent_for(unicode:characters_to_binary(Pinned));
        _ -> user_agent_for(?DEFAULT_VERSION)
    end.

cached_version(Home) ->
    case discovered(Home) of
        {ok, Bytes} ->
            try json:decode(Bytes) of
                #{<<"version">> := <<_, _/binary>> = Version} -> Version;
                _ -> ?DEFAULT_VERSION
            catch _:_ -> ?DEFAULT_VERSION end;
        _ -> ?DEFAULT_VERSION
    end.

%% ---- model discovery ----------------------------------------------------

%% Model ids and their model_enum labels change server-side, so the
%% catalog is whatever fetchAvailableModels last reported.
discovered(Home) -> file:read_file(catalog_path(Home)).

catalog_path(Home) -> filename:join(unicode:characters_to_list(Home), ?CATALOG).

refresh(Home) ->
    Path = catalog_path(Home),
    Stale = case file:read_file_info(Path, [{time, posix}]) of
        {ok, #file_info{type = regular, mtime = Modified}} ->
            erlang:system_time(millisecond) - Modified * 1000 > ?CATALOG_MAX_AGE_MS;
        _ -> true
    end,
    case Stale of
        false -> nil;
        true ->
            Pid = spawn(fun() -> reload(Home) end),
            try register(?REFRESH_PROCESS, Pid) of
                true -> nil
            catch _:_ -> exit(Pid, kill), nil
            end
    end.

reload(Home) ->
    try
        case access(Home) of
            {ok, Access} ->
                #{<<"access">> := Token} = json:decode(Access),
                Version = manifest_version(),
                case fetch_models(Token, Version) of
                    {ok, Models, Renamed} ->
                        store(catalog_path(Home), #{<<"version">> => Version, <<"models">> => Models,
                                                    <<"renamed">> => Renamed});
                    Error -> Error
                end;
            Error -> Error
        end
    catch _:_ -> {error, <<"Antigravity model discovery failed">>}
    end.

manifest_version() ->
    _ = application:ensure_all_started(inets),
    _ = application:ensure_all_started(ssl),
    Request = {?MANIFEST_URL, [{"user-agent", "electron-builder"}, {"cache-control", "no-cache"}]},
    Options = [{timeout, 5000}, {connect_timeout, 5000},
               {ssl, albedo_credentials:tls_options("antigravity-hub-auto-updater-974169037036.us-central1.run.app")}],
    case httpc:request(get, Request, Options, [{body_format, binary}]) of
        {ok, {{_, 200, _}, _, Body}} ->
            case re:run(Body, <<"^\\s*version\\s*:\\s*['\"]?(\\d+\\.\\d+\\.\\d+)">>,
                        [multiline, {capture, all_but_first, binary}]) of
                {match, [Version]} -> Version;
                _ -> ?DEFAULT_VERSION
            end;
        _ -> ?DEFAULT_VERSION
    end.

fetch_models(Token, Version) ->
    Headers = [{"authorization", "Bearer " ++ binary_to_list(Token)},
               {"user-agent", binary_to_list(user_agent_for(Version))}],
    Request = {?ENDPOINT "/v1internal:fetchAvailableModels", Headers, "application/json", <<"{}">>},
    Options = [{timeout, 15000}, {connect_timeout, 10000},
               {ssl, albedo_credentials:tls_options("daily-cloudcode-pa.googleapis.com")}],
    case httpc:request(post, Request, Options, [{body_format, binary}]) of
        {ok, {{_, 200, _}, _, Body}} ->
            case json:decode(Body) of
                #{<<"models">> := Models} = Response when is_map(Models) ->
                    Renamed = maps:fold(fun
                        (Old, #{<<"newModelId">> := <<_, _/binary>> = New}, Acc) -> Acc#{Old => New};
                        (_, _, Acc) -> Acc
                    end, #{}, case maps:get(<<"deprecatedModelIds">>, Response, #{}) of
                        D when is_map(D) -> D;
                        _ -> #{}
                    end),
                    Live = maps:without(maps:keys(Renamed), Models),
                    Order = case recommended(Response) of
                        [] -> lists:sort(maps:keys(Live));
                        Ids -> Ids
                    end,
                    {ok, lists:filtermap(fun(Id) -> offered({Id, maps:get(Id, Live, undefined)}) end, Order),
                     Renamed};
                _ -> {error, <<"Antigravity model discovery response is invalid">>}
            end;
        {ok, {{_, Status, _}, _, _}} ->
            {error, iolist_to_binary(io_lib:format("Antigravity model discovery failed (~B)", [Status]))};
        _ -> {error, <<"Antigravity model discovery failed">>}
    end.

%% The ids the real client's agent picker shows, in its order.
recommended(#{<<"agentModelSorts">> := [#{<<"groups">> := Groups} | _]}) when is_list(Groups) ->
    lists:append([Ids || #{<<"modelIds">> := Ids} <- Groups, is_list(Ids)]);
recommended(_) -> [].

user_agent_for(Version) ->
    <<"antigravity/hub/", Version/binary, " (aidev_client; os_type=darwin; arch=arm64; cl=963137146)">>.

%% Chat models only: internal, autocomplete (tab_*), and unnamed tier aliases
%% are not agent models.
offered({Id, #{<<"displayName">> := <<_, _/binary>> = Name, <<"maxTokens">> := Context} = Model})
  when is_integer(Context) ->
    case maps:get(<<"isInternal">>, Model, false) =:= true orelse
         lists:member(Id, [<<"chat_20706">>, <<"chat_23310">>]) of
        true -> false;
        false ->
            Output = case maps:get(<<"maxOutputTokens">>, Model, undefined) of
                N when is_integer(N), N > 0 -> N;
                _ -> 64000
            end,
            Entry = #{<<"id">> => Id, <<"name">> => Name, <<"context">> => Context,
                      <<"output">> => Output,
                      <<"images">> => maps:get(<<"supportsImages">>, Model, false) =:= true},
            {true, case maps:get(<<"model">>, Model, undefined) of
                <<_, _/binary>> = Enum -> Entry#{<<"modelEnum">> => Enum};
                _ -> Entry
            end}
    end;
offered(_) -> false.

store(Path, Data) ->
    Temporary = Path ++ ".fetch." ++ integer_to_list(erlang:unique_integer([positive])),
    _ = filelib:ensure_dir(Path),
    case file:write_file(Temporary, json:encode(Data)) of
        ok ->
            case file:rename(Temporary, Path) of
                ok -> {ok, nil};
                _ -> _ = file:delete(Temporary), {error, <<"Antigravity model cache could not be replaced">>}
            end;
        _ -> {error, <<"Antigravity model cache could not be written">>}
    end.

%% ---- schemas ------------------------------------------------------------

%% Cloud Code Assist accepts a flat OpenAPI subset for every model family:
%% no references, combiners, nullable, or type unions. Anything else is
%% resolved, collapsed, or spilled into the description so guidance survives.
normalize_schema(Json) ->
    Root = json:decode(iolist_to_binary(Json)),
    Defs = maps:merge(defs(Root, <<"definitions">>), defs(Root, <<"$defs">>)),
    Schema = case schema(Root, Defs, 0) of
        #{<<"type">> := <<"object">>} = Object -> Object;
        _ -> #{<<"type">> => <<"object">>, <<"properties">> => #{}}
    end,
    json:encode(Schema).

defs(Root, Key) when is_map(Root) ->
    case maps:get(Key, Root, #{}) of
        Map when is_map(Map) -> Map;
        _ -> #{}
    end;
defs(_, _) -> #{}.

-define(KEPT, [<<"type">>, <<"description">>, <<"enum">>, <<"items">>,
               <<"properties">>, <<"required">>, <<"title">>]).
-define(SPILLED, [<<"format">>, <<"pattern">>, <<"minLength">>, <<"maxLength">>,
                  <<"minimum">>, <<"maximum">>, <<"exclusiveMinimum">>,
                  <<"exclusiveMaximum">>, <<"multipleOf">>, <<"minItems">>,
                  <<"maxItems">>, <<"uniqueItems">>, <<"minProperties">>,
                  <<"maxProperties">>, <<"default">>, <<"examples">>]).

schema(_, _, Depth) when Depth > 32 -> #{};
schema(Node, Defs, Depth) when is_map(Node) ->
    Resolved = resolve(Node, Defs, Depth),
    Combined = lists:any(fun(Key) -> maps:is_key(Key, Resolved) end,
                         [<<"allOf">>, <<"anyOf">>, <<"oneOf">>]),
    case Combined of
        true -> schema(collapse(Resolved, Defs, Depth), Defs, Depth + 1);
        false -> finish(Resolved, Defs, Depth)
    end;
schema(_, _, _) -> #{}.

resolve(#{<<"$ref">> := <<"#/", Pointer/binary>>} = Node, Defs, Depth) when Depth < 32 ->
    Name = lists:last(binary:split(Pointer, <<"/">>, [global])),
    case maps:get(Name, Defs, undefined) of
        Target when is_map(Target) ->
            resolve(maps:merge(Target, maps:remove(<<"$ref">>, Node)), Defs, Depth + 1);
        _ -> maps:remove(<<"$ref">>, Node)
    end;
resolve(Node, _, _) -> Node.

%% allOf merges; anyOf/oneOf keep the first non-null branch, since CCA has no
%% union. The dropped alternatives are named in the description.
collapse(Node, Defs, Depth) ->
    AllOf = [resolve(B, Defs, Depth + 1) || B <- branches(Node, <<"allOf">>)],
    Base = lists:foldl(fun merge/2, maps:without([<<"allOf">>], Node), AllOf),
    Union = [resolve(B, Defs, Depth + 1) || B <- branches(Base, <<"anyOf">>) ++ branches(Base, <<"oneOf">>)],
    Rest = maps:without([<<"anyOf">>, <<"oneOf">>], Base),
    case [B || B <- Union, not null_type(B)] of
        [] -> Rest;
        [Only] -> merge(Only, Rest);
        [First | _] = Options ->
            case lists:all(fun(B) -> maps:is_key(<<"const">>, B) orelse maps:is_key(<<"enum">>, B) end, Options) of
                true -> Rest#{<<"enum">> => lists:append([values(B) || B <- Options])};
                false -> describe(merge(First, Rest), <<"one of: ">>,
                                  lists:join(<<", ">>, [kind(B) || B <- Options]))
            end
    end.

branches(Node, Key) ->
    case maps:get(Key, Node, []) of
        List when is_list(List) -> [B || B <- List, is_map(B)];
        _ -> []
    end.

null_type(Branch) -> maps:get(<<"type">>, Branch, undefined) =:= <<"null">>.

values(#{<<"const">> := Value}) -> [Value];
values(#{<<"enum">> := Values}) when is_list(Values) -> Values;
values(_) -> [].

kind(Branch) ->
    case maps:get(<<"type">>, Branch, undefined) of
        Type when is_binary(Type) -> Type;
        _ -> maps:get(<<"title">>, Branch, <<"schema">>)
    end.

merge(Branch, Into) ->
    maps:fold(fun
        (<<"properties">>, Props, Acc) when is_map(Props) ->
            Acc#{<<"properties">> => maps:merge(Props, maps:get(<<"properties">>, Acc, #{}))};
        (<<"required">>, Names, Acc) when is_list(Names) ->
            Acc#{<<"required">> => lists:usort(Names ++ maps:get(<<"required">>, Acc, []))};
        (Key, Value, Acc) -> maps:merge(#{Key => Value}, Acc)
    end, Into, Branch).

finish(Node0, Defs, Depth) ->
    Node1 = case maps:get(<<"const">>, Node0, undefined) of
        undefined -> Node0;
        Const -> Node0#{<<"enum">> => [Const]}
    end,
    Type = scalar_type(Node1),
    Spilled = [{K, V} || K <- ?SPILLED, V <- [maps:get(K, Node1, undefined)], V =/= undefined],
    Node2 = maps:with(?KEPT, Node1),
    Node3 = case Spilled of
        [] -> Node2;
        _ -> describe(Node2, <<>>, lists:join(<<", ">>,
                 [[K, <<": ">>, json:encode(V)] || {K, V} <- Spilled]))
    end,
    Node4 = case Type of
        undefined -> maps:remove(<<"type">>, Node3);
        _ -> Node3#{<<"type">> => Type}
    end,
    children(enum(Node4), Defs, Depth).

%% A type union keeps its first non-null member.
scalar_type(Node) ->
    Inferred = fun() ->
        case Node of
            #{<<"properties">> := _} -> <<"object">>;
            #{<<"items">> := _} -> <<"array">>;
            #{<<"enum">> := _} -> <<"string">>;
            _ -> undefined
        end
    end,
    case maps:get(<<"type">>, Node, undefined) of
        Type when is_binary(Type), Type =/= <<"null">> -> Type;
        Types when is_list(Types) ->
            case [T || T <- Types, is_binary(T), T =/= <<"null">>] of
                [First | _] -> First;
                [] -> Inferred()
            end;
        _ -> Inferred()
    end.

%% Google enums are strings only.
enum(#{<<"enum">> := Values} = Node) when is_list(Values) ->
    Strings = lists:usort([string_value(V) || V <- Values, V =/= null]),
    case Strings of
        [] -> maps:remove(<<"enum">>, Node);
        _ -> Node#{<<"enum">> => Strings, <<"type">> => <<"string">>}
    end;
enum(Node) -> maps:remove(<<"enum">>, Node).

string_value(V) when is_binary(V) -> V;
string_value(V) -> iolist_to_binary(json:encode(V)).

children(#{<<"type">> := <<"object">>} = Node, Defs, Depth) ->
    Props = maps:map(fun(_, V) -> schema(V, Defs, Depth + 1) end,
                     case maps:get(<<"properties">>, Node, #{}) of
                         P when is_map(P) -> P;
                         _ -> #{}
                     end),
    Required = [R || R <- maps:get(<<"required">>, Node, []), is_binary(R), maps:is_key(R, Props)],
    WithProps = Node#{<<"properties">> => Props},
    case Required of
        [] -> maps:remove(<<"required">>, WithProps);
        _ -> WithProps#{<<"required">> => lists:usort(Required)}
    end;
children(#{<<"type">> := <<"array">>} = Node, Defs, Depth) ->
    Items = case maps:get(<<"items">>, Node, #{}) of
        List when is_list(List) -> case List of [I | _] -> I; [] -> #{} end;
        I -> I
    end,
    maps:remove(<<"required">>, Node#{<<"items">> => schema(Items, Defs, Depth + 1)});
children(Node, _, _) ->
    maps:without([<<"properties">>, <<"required">>, <<"items">>], Node).

describe(Node, Prefix, Detail) ->
    Note = iolist_to_binary([Prefix, Detail]),
    Node#{<<"description">> => case maps:get(<<"description">>, Node, <<>>) of
        <<>> -> Note;
        Text when is_binary(Text) -> <<Text/binary, " (", Note/binary, ")">>;
        _ -> Note
    end}.
