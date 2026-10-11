-module(albedo_antigravity).
%% Antigravity credentials and request identity.

-include_lib("kernel/include/file.hrl").
-export([access/1, access/2, access/3, access/4, limited/3, limited/4, limit/1, limit/2,
         meter_of/1, meter_of/2, heal/3, encode/1, session_number/1, uuid/1,
         call_id/0, user_agent/1, discovered/1, refresh/1, reload/1, expire/2,
         exchange/4, discover/3, account/1, client_id/0, accounts/1]).

-define(KEY, <<"google-antigravity">>).
-define(CLIENT_ID, <<"MTA3MTAwNjA2MDU5MS10bWhzc2luMmgyMWxjcmUyMzV2dG9sb2poNGc0MDNlcC5hcHBzLmdvb2dsZXVzZXJjb250ZW50LmNvbQ==">>).
-define(CLIENT_SECRET, <<"R09DU1BYLUs1OEZXUjQ4NkxkTEoxbUxCOHNYQzR6NnFEQWY=">>).
-define(CATALOG, "antigravity.json").
-define(CATALOG_MAX_AGE_MS, 21600000).
-define(REFRESH_PROCESS, albedo_antigravity_refresh).
-define(DEFAULT_VERSION, <<"2.16.0">>).
-define(ENDPOINT, "https://daily-cloudcode-pa.googleapis.com").
-define(MANIFEST_URL, "https://antigravity-hub-auto-updater-974169037036.us-central1.run.app/manifest/latest-arm64-mac.yml").
-define(SCOPE, <<"antigravity">>).
%% Used when a quota response names no reset time.
-define(DEFAULT_LIMIT_MS, 900000).
%% Used when a rate limit names no retry delay.
-define(RATE_LIMIT_MS, 30000).
%% Limits longer than this are not worth waiting on.
-define(BRIEF_MS, 300000).
-define(SIGNED_OUT, <<"Antigravity is not authenticated; run /login and add a Google account">>).

%% ---- credentials --------------------------------------------------------

access(Home) -> access(Home, <<>>).

%% The session's account: selected first, then its sticky or hashed choice,
%% with accounts inside a reported limit last.
access(Home, Session0) -> access(Home, Session0, <<>>).

access(Home, Session0, Profile) -> access(Home, Session0, Profile, undefined).

access(Home, Session0, Profile, Meter0) ->
    Session = unicode:characters_to_binary(Session0),
    Meter = case Meter0 of
        {some, M} when is_binary(M) -> M;
        none -> undefined;
        undefined -> undefined;
        M when is_binary(M) -> M;
        _ -> undefined
    end,
    Path = albedo_credentials:creds_path(Home),
    case albedo_credentials:accounts(Path) of
        {ok, Data} ->
            Raw = credentials(Data),
            case albedo_credentials:bound_values(Home, Profile, Raw) of
                {ok, Credentials} -> first_usable(albedo_accounts:order(?SCOPE, Credentials, Session, fun account_id/1, Meter), Path, Session);
                Error -> Error
            end;
        {error, _} -> {error, ?SIGNED_OUT}
    end.

first_usable([], _, _) -> {error, ?SIGNED_OUT};
first_usable([Credential | Rest], Path, Session) ->
    case albedo_google_oauth:ensure(app(), Path, Credential) of
        {ok, Access} ->
            albedo_accounts:remember(?SCOPE, Session, account_id(Access)),
            Token = maps:get(<<"access">>, Access),
            Project = maps:get(<<"projectId">>, Access, <<>>),
            Email = maps:get(<<"email">>, Access, <<>>),
            {ok, {access, Token, Project, Email}};
        {error, _} -> first_usable(Rest, Path, Session)
    end.

credentials(Data) ->
    albedo_credentials:oauth(Data, ?KEY).

%% Every Google account for the quota poller, each refreshed the way a request
%% refreshes it: `label` is the account's non-secret identity, the rest are
%% the provide-usage credential fields, projectId included. The refresh
%% token stays home: albedo refreshes, and the core never reads it. A refresh
%% that fails keeps the stored credential, so the poll records the auth failure as
%% a reading instead of silently dropping the account.
accounts(Home) ->
    Path = albedo_credentials:creds_path(Home),
    case albedo_credentials:accounts(Path) of
        {ok, Data} ->
            [entry(refreshed_account(Path, V)) || V <- credentials(Data), account_id(V) =/= <<>>];
        _ -> []
    end.

refreshed_account(Path, Credential) ->
    case albedo_google_oauth:ensure(app(), Path, Credential) of
        {ok, Updated} -> Updated;
        _ -> Credential
    end.

entry(Value) ->
    maps:merge(#{<<"label">> => account_id(Value)}, fields(Value)).

fields(Value) ->
    maps:from_list([{K, field(Value, K)}
                    || K <- [<<"access">>, <<"email">>, <<"projectId">>]]).

field(Value, Key) ->
    case maps:get(Key, Value, <<>>) of
        Text when is_binary(Text) -> Text;
        _ -> <<>>
    end.

%% Records a Cloud Code Assist 429 against the account whose token received
%% it. Returns a JSON summary, or {error, not_a_limit} when the body is not a
%% per-account limit: a model out of capacity for everyone moves nobody.
limited(Home, Access, Body) ->
    limited(Home, Access, Body, undefined).

limited(Home, Access, Body, FallbackMeter0) ->
    FallbackMeter = case FallbackMeter0 of
        {some, FM} -> FM;
        none -> undefined;
        FM -> FM
    end,
    case limit(Body, FallbackMeter) of
        {ok, {limit, Until, Lasting, OptMeter}} ->
            Meter = case OptMeter of {some, M} -> M; none -> undefined; M when is_binary(M) -> M end,
            Path = albedo_credentials:creds_path(Home),
            Hit = fun(V) -> maps:get(<<"access">>, V, <<>>) =:= Access end,
            case albedo_accounts:mark(Path, ?KEY, Hit, Until, Meter) of
                {ok, Updated} ->
                    Values = credentials(#{?KEY => Updated}),
                    Now = erlang:system_time(millisecond),
                    Next = [V || V <- albedo_accounts:order(?SCOPE, Values, <<>>, fun account_id/1, Meter),
                                 not Hit(V), not albedo_accounts:limited(V, Now, Meter)],
                    Account = label([V || V <- Values, Hit(V)]),
                    UntilText = albedo_accounts:local_time(Until),
                    NextText = label(Next),
                    MeterText = case Meter of undefined -> <<>>; Val -> Val end,
                    SiblingStatus = case Next of
                        [] -> sibling_status(Values, Hit, Now);
                        _ -> <<>>
                    end,
                    {ok, {limited, Account, UntilText, NextText, Lasting, MeterText, SiblingStatus}};
                Error -> Error
            end;
        {error, _} -> {error, <<"not_a_limit">>};
        error -> {error, <<"not_a_limit">>}
    end.

label([#{<<"email">> := <<_, _/binary>> = Email} | _]) -> Email;
label([_ | _]) -> <<"another Google account">>;
label([]) -> <<>>.

sibling_status(Values, Hit, Now) ->
    Siblings = [V || V <- Values, not Hit(V)],
    Notes = lists:filtermap(fun(V) -> sibling_note(V, Now) end, Siblings),
    case Notes of
        [] -> <<>>;
        _ -> iolist_to_binary([<<" ">>, lists:join(<<" ">>, Notes)])
    end.

sibling_note(V, Now) ->
    Label = account_id(V),
    case maps:get(<<"limitedMeters">>, V, undefined) of
        Meters when is_map(Meters), map_size(Meters) > 0 ->
            Active = [{M, U} || {M, U} <- maps:to_list(Meters), is_integer(U), U > Now],
            case Active of
                [{Meter, Until} | _] ->
                    {true, iolist_to_binary(io_lib:format("~s is limited on ~s until ~s.",
                        [Label, meter_title(Meter), albedo_accounts:local_time(Until)]))};
                [] -> false
            end;
        _ ->
            case maps:get(<<"limitedUntil">>, V, 0) of
                Until when is_integer(Until), Until > Now ->
                    {true, iolist_to_binary(io_lib:format("~s is limited until ~s.",
                        [Label, albedo_accounts:local_time(Until)]))};
                _ -> false
            end
    end.

meter_title(<<"gemini">>) -> <<"Gemini">>;
meter_title(<<"claude">>) -> <<"Claude">>;
meter_title(<<"gpt-oss">>) -> <<"GPT-OSS">>;
meter_title(Other) when is_binary(Other) -> Other.

meter_of(undefined) -> undefined;
meter_of(<<>>) -> undefined;
meter_of(<<"claude-", _/binary>>) -> <<"claude">>;
meter_of(<<"gpt-oss-", _/binary>>) -> <<"gpt-oss">>;
meter_of(<<"claude">>) -> <<"claude">>;
meter_of(<<"gpt-oss">>) -> <<"gpt-oss">>;
meter_of(<<"gemini">>) -> <<"gemini">>;
meter_of(Text) when is_binary(Text) -> <<"gemini">>;
meter_of(Text) when is_list(Text) -> meter_of(unicode:characters_to_binary(Text));
meter_of(_) -> undefined.

meter_of(Model, Fallback) ->
    case meter_of(Model) of
        undefined -> meter_of(Fallback);
        Meter -> Meter
    end.

%% Google explains a 429 in google.rpc details: an ErrorInfo reason with an
%% optional reset in its metadata, and a RetryInfo delay.
limit(Body) -> limit(Body, undefined).

limit(Body, {some, Fallback}) -> limit(Body, Fallback);
limit(Body, none) -> limit(Body, undefined);
limit(Body, Fallback) ->
    try json:decode(unicode:characters_to_binary(Body)) of
        #{<<"error">> := #{} = Error} ->
            Details = [D || D <- maps:get(<<"details">>, Error, []), is_map(D)],
            Reasons = [R || #{<<"reason">> := R} <- Details],
            Metadata = lists:foldl(fun(#{<<"metadata">> := M}, Acc) when is_map(M) -> maps:merge(Acc, M);
                                      (_, Acc) -> Acc end, #{}, Details),
            Now = erlang:system_time(millisecond),
            Reset = first_reset([
                reset_at(maps:get(<<"quotaResetTimeStamp">>, Metadata, undefined), Now),
                duration(maps:get(<<"quotaResetDelay">>, Metadata, undefined)),
                duration(hd([D || #{<<"retryDelay">> := D} <- Details] ++ [undefined]))
            ]),
            Quota = lists:member(<<"QUOTA_EXHAUSTED">>, Reasons),
            Capacity = lists:member(<<"MODEL_CAPACITY_EXHAUSTED">>, Reasons),
            Exhausted = maps:get(<<"status">>, Error, <<>>) =:= <<"RESOURCE_EXHAUSTED">>
                        orelse maps:get(<<"code">>, Error, 0) =:= 429,
            Meter = meter_of(maps:get(<<"model">>, Metadata, undefined), Fallback),
            OptMeter = case Meter of undefined -> none; M -> {some, M} end,
            case {Capacity, Quota, Reset} of
                {true, _, _} -> {error, nil};
                {_, true, undefined} -> {ok, {limit, Now + ?DEFAULT_LIMIT_MS, true, OptMeter}};
                {_, true, In} -> {ok, {limit, Now + In, true, OptMeter}};
                {_, _, undefined} when Exhausted -> {ok, {limit, Now + ?RATE_LIMIT_MS, false, OptMeter}};
                {_, _, In} when Exhausted -> {ok, {limit, Now + In, In > ?BRIEF_MS, OptMeter}};
                _ -> {error, nil}
            end;
        _ -> {error, nil}
    catch _:_ -> {error, nil}
    end.

first_reset(List) -> hd([In || In <- List, is_integer(In), In > 0] ++ [undefined]).

reset_at(Stamp, Now) when is_binary(Stamp) ->
    try calendar:rfc3339_to_system_time(binary_to_list(Stamp), [{unit, millisecond}]) - Now
    catch _:_ -> undefined
    end;
reset_at(_, _) -> undefined.

%% A protobuf duration as Google prints it: "3s", "1.5s", "2h3m4.5s", "500ms".
duration(Text) when is_binary(Text) ->
    case re:run(Text, <<"([0-9]+(?:\\.[0-9]+)?)(ms|h|m|s)">>, [global, {capture, all_but_first, binary}]) of
        {match, Parts} ->
            round(lists:sum([number(N) * unit(U) || [N, U] <- Parts]));
        nomatch -> undefined
    end;
duration(_) -> undefined.

number(N) -> try binary_to_float(N) catch _:_ -> binary_to_integer(N) end.

unit(<<"h">>) -> 3600000;
unit(<<"m">>) -> 60000;
unit(<<"s">>) -> 1000;
unit(<<"ms">>) -> 1.

%% The account's stable id: its email, or a hash of its refresh token.
account_id(Credential) ->
    case albedo_google_oauth:identity(Credential) of
        {email, Email} -> Email;
        {refresh, Refresh} -> binary:encode_hex(binary:part(crypto:hash(sha256, Refresh), 0, 8), lowercase)
    end.

%% After a 401 the stored token is marked expired, so the next turn refreshes
%% it; a revoked refresh token then leaves the account signed out.
expire(Home, Access) ->
    albedo_credentials:expire_access(albedo_credentials:creds_path(Home), ?KEY, Access).

%% ---- sign-in ------------------------------------------------------------

client_id() -> base64:decode(?CLIENT_ID).
client_secret() -> base64:decode(?CLIENT_SECRET).

-define(FREE_TIER, <<"free-tier">>).
-define(ONBOARD_BUDGET_MS, 30000).
-define(METADATA, #{<<"ideType">> => <<"ANTIGRAVITY">>}).

app() ->
    #{name => <<"Antigravity">>, client_id => client_id(), client_secret => client_secret(),
      key => ?KEY, required => [<<"access">>, <<"refresh">>, <<"projectId">>]}.

%% Endpoints is the Gleam record {endpoints, TokenUrl, UserinfoUrl, CloudCodeUrl}.
exchange(Code, Redirect, Progress, {endpoints, TokenUrl, UserinfoUrl, _} = Endpoints) ->
    maybe
        {ok, #{<<"access">> := Access} = Tokens} ?= albedo_google_oauth:exchange(app(), TokenUrl, Code, Redirect),
        Progress(<<"getting user info">>),
        Email = albedo_google_oauth:email(UserinfoUrl, Access),
        {ok, Project} ?= discover(Access, Endpoints, Progress, Email),
        {ok, maps:merge(Email, Tokens#{<<"type">> => <<"oauth">>, <<"projectId">> => Project})}
    end.

%% Finds the account's Cloud Code Assist project, provisioning the free tier
%% first when the account has none, as the Antigravity IDE does.
discover(Access, Endpoints, Progress) ->
    discover(Access, Endpoints, Progress, #{}).

discover(Access, {endpoints, _, _, CloudCode}, Progress, Email) ->
    Progress(<<"checking cloud code assist account status">>),
    Call = fun(Method, Path, Body) -> cloud_code(Method, CloudCode, Path, Access, Body, Email) end,
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

cloud_code(Method, Base, Path, Access, Body, Email) ->
    Headers = [{"authorization", "Bearer " ++ binary_to_list(Access)},
               {"user-agent", binary_to_list(sign_in_user_agent())}],
    Encoded = case Body of
        none -> none;
        _ -> {"application/json", json:encode(Body)}
    end,
    case albedo_http:fetch(Method, <<Base/binary, Path/binary>>, Headers, Encoded) of
        {ok, 200, Response} ->
            try {ok, json:decode(Response)}
            catch _:_ -> {error, <<"Cloud Code Assist returned invalid JSON">>}
            end;
        {ok, Status, Response} ->
            case 'albedo@harness@extensions@antigravity@errors':verification_url(Response) of
                {ok, Url} -> {error, verification(Url, Email)};
                {error, nil} -> {error, albedo_http:failure(Path, Status, Response)}
            end;
        Error -> Error
    end.

%% Google asks some accounts to verify before Cloud Code Assist serves them.
verification(Link, Email) ->
    Url = case Link of
        <<>> -> <<"https://accounts.google.com">>;
        _ -> Link
    end,
    For = case Email of #{<<"email">> := E} -> <<" for ", E/binary>>; _ -> <<>> end,
    <<"Account verification required", For/binary, ". Visit ", Url/binary, " to continue, then sign in again.">>.

%% How /login lists a stored Antigravity account.
account(Credential) when is_map(Credential) ->
    Id = account_id(Credential),
    Label = case maps:get(<<"email">>, Credential, <<>>) of
        <<_, _/binary>> = Email0 -> Email0;
        _ -> <<"antigravity account">>
    end,
    Selected = maps:get(<<"selected">>, Credential, false) =:= true,
    Now = erlang:system_time(millisecond),
    Detail = iolist_to_binary([
        <<"antigravity account">>,
        case Selected of true -> [<<" · selected"/utf8>>]; false -> [] end,
        account_limit_detail(Credential, Now)
    ]),
    {account, Id, Label, Detail, Selected};
account(_) -> {account, <<>>, <<"invalid antigravity account">>, <<>>, false}.

account_limit_detail(Credential, Now) ->
    case maps:get(<<"limitedMeters">>, Credential, undefined) of
        Meters when is_map(Meters), map_size(Meters) > 0 ->
            Active = [{M, U} || {M, U} <- maps:to_list(Meters), is_integer(U), U > Now],
            case Active of
                [] -> [];
                _ ->
                    [begin
                        [<<" · limited on "/utf8>>, meter_title(M), <<" until ">>, albedo_accounts:local_time(U)]
                    end || {M, U} <- Active]
            end;
        _ ->
            case maps:get(<<"limitedUntil">>, Credential, 0) of
                Until when is_integer(Until), Until > Now ->
                    [<<" · limited until "/utf8>>, albedo_accounts:local_time(Until)];
                _ -> []
            end
    end.

heal(Home, AccountId, LimitPairs) ->
    Path = albedo_credentials:creds_path(Home),
    albedo_settings_lock:with_lock(filename:dirname(Path), fun() ->
        case albedo_credentials:accounts(Path) of
            {ok, Data} ->
                Stored = maps:get(?KEY, Data, []),
                Values = case Stored of L when is_list(L) -> L; One -> [One] end,
                Now = erlang:system_time(millisecond),
                {Updated, Changed} = lists:mapfoldl(fun(V, Acc) ->
                    case is_map(V) andalso (account_id(V) =:= AccountId orelse maps:get(<<"email">>, V, <<>>) =:= AccountId)
                         andalso maps:is_key(<<"limitedUntil">>, V) of
                        true ->
                            Until = maps:get(<<"limitedUntil">>, V),
                            CleanV = maps:remove(<<"limitedUntil">>, V),
                            Matched = [Id || {Id, ResetsAt} <- LimitPairs, ResetsAt =:= Until],
                            NewV = case Matched of
                                [_ | _] ->
                                    Meters = maps:get(<<"limitedMeters">>, CleanV, #{}),
                                    Live = maps:filter(fun(_, U) -> is_integer(U) andalso U > Now end, Meters),
                                    Added = lists:foldl(fun(MeterId, AccM) -> AccM#{MeterId => Until} end, Live, Matched),
                                    CleanV#{<<"limitedMeters">> => Added};
                                [] ->
                                    CleanV
                            end,
                            {NewV, true};
                        false ->
                            {V, Acc}
                    end
                end, false, Values),
                case Changed of
                    true ->
                        Kept = case Stored of L2 when is_list(L2) -> Updated; _ -> hd(Updated) end,
                        albedo_credentials:put_accounts(Path, Data#{?KEY => Kept});
                    false -> ok
                end;
            _ -> ok
        end
    end, fun() -> ok end),
    nil.

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


%% The backend gates newer models on this client version; os and arch are
%% pinned to the reference darwin/arm64 build regardless of the host.
user_agent(Home) ->
    user_agent_for(effective_version(cached_version(Home))).

sign_in_user_agent() ->
    user_agent_for(effective_version(?DEFAULT_VERSION)).

effective_version(Fallback) ->
    case os:getenv("ALBEDO_ANTIGRAVITY_VERSION") of
        Pinned when is_list(Pinned), Pinned =/= "" -> unicode:characters_to_binary(Pinned);
        _ -> Fallback
    end.

cached_version(Home) ->
    case albedo_credentials:read_json(catalog_path(Home)) of
        {ok, #{<<"version">> := <<_, _/binary>> = Version}} -> Version;
        _ -> ?DEFAULT_VERSION
    end.

%% ---- model discovery ----------------------------------------------------

%% Model ids and their model_enum labels change server-side, so the
%% catalog is whatever fetchAvailableModels last reported.
discovered(Home) -> file:read_file(catalog_path(Home)).

catalog_path(Home) -> filename:join(unicode:characters_to_list(Home), ?CATALOG).

refresh(Home) ->
    Path = catalog_path(Home),
    case albedo_credentials:stale(Path, ?CATALOG_MAX_AGE_MS) of
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
            {ok, {access, Token, _, _}} ->
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
    Headers = [{"user-agent", "electron-builder"}, {"cache-control", "no-cache"}],
    try
        {ok, {200, _, Body}} = albedo_http:get(?MANIFEST_URL, Headers, 5000, 5000),
        {match, [Version]} = re:run(Body, <<"^\\s*version\\s*:\\s*['\"]?(\\d+\\.\\d+\\.\\d+)">>,
                                    [multiline, {capture, all_but_first, binary}]),
        Version
    catch _:_ -> ?DEFAULT_VERSION end.

fetch_models(Token, Version) ->
    Headers = [{"authorization", "Bearer " ++ binary_to_list(Token)},
               {"user-agent", binary_to_list(user_agent_for(Version))}],
    case albedo_http:post(?ENDPOINT "/v1internal:fetchAvailableModels", Headers,
                          "application/json", <<"{}">>, 15000, 10000) of
        {ok, {200, _, Body}} ->
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
        {ok, {Status, _, _}} ->
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
            Output = case maps:get(<<"maxOutputTokens">>, Model, 64000) of
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
    case albedo_credentials:write(Path, Data) of
        ok -> {ok, nil};
        {error, {rename, _}} -> {error, <<"Antigravity model cache could not be replaced">>};
        _ -> {error, <<"Antigravity model cache could not be written">>}
    end.
