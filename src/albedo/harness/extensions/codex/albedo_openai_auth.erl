-module(albedo_openai_auth).
%% Codex sign-in, multi-account credential selection, and refresh.

-export([codex_access/2, codex_revoke/2, codex_limited/3, codex_exchange/3, codex_account/1, accounts/1]).

-define(SCOPE, <<"codex">>).
-define(STORE, <<"openai-codex">>).
-define(CLIENT_ID, <<"app_EMoamEEZ73f0CkXaXp7hrann">>).
-define(TOKEN_URL, "https://auth.openai.com/api/accounts/oauth/token").
-define(AUTH_CLAIM, <<"https://api.openai.com/auth">>).
-define(REFRESH_SKEW_MS, 60000).
-define(HTTP_TIMEOUT_MS, 15000).
%% Used when a usage-limit response names no reset time.
-define(DEFAULT_LIMIT_MS, 900000).
%% Used when a short-term rate limit names no reset time.
-define(RATE_LIMIT_MS, 30000).

%% Trades an authorization code for the credential /login stores.
codex_exchange(Code, Verifier, Redirect) ->
    Body = uri_string:compose_query([
        {<<"grant_type">>, <<"authorization_code">>},
        {<<"client_id">>, ?CLIENT_ID},
        {<<"code">>, Code},
        {<<"code_verifier">>, Verifier},
        {<<"redirect_uri">>, Redirect}
    ]),
    case post_token(Body) of
        {ok, Response} ->
            try json:decode(Response) of
                #{<<"access_token">> := <<_, _/binary>> = Access,
                  <<"refresh_token">> := <<_, _/binary>> = Refresh,
                  <<"expires_in">> := In} = Token when is_number(In), In > 0 ->
                    IdClaims = case maps:get(<<"id_token">>, Token, <<>>) of
                        IdToken when is_binary(IdToken) -> token_identity(IdToken);
                        _ -> #{}
                    end,
                    Claims = maps:merge(IdClaims, token_identity(Access)),
                    Credential = maps:merge(maps:with([<<"accountId">>, <<"accountUserId">>, <<"email">>], Claims), #{
                        <<"type">> => <<"oauth">>,
                        <<"access">> => Access,
                        <<"refresh">> => Refresh,
                        <<"expires">> => erlang:system_time(millisecond) + round(In * 1000)
                    }),
                    case maps:is_key(<<"accountId">>, Credential) of
                        true -> {ok, json:encode(Credential)};
                        false -> {error, <<"codex token has no ChatGPT account id">>}
                    end;
                _ -> {error, <<"codex token exchange response is incomplete">>}
            catch _:_ -> {error, <<"codex token exchange response is incomplete">>}
            end;
        {error, Status, Detail} ->
            {error, iolist_to_binary(io_lib:format("codex token exchange failed (~B)~s", [Status, Detail]))};
        {error, Reason} -> {error, Reason}
    end.

%% How /login lists a stored Codex account.
codex_account(Credential) when is_map(Credential) ->
    Name = first([email(Credential), account_id(Credential), <<"chatgpt account">>]),
    Label = case plan(Credential) of
        <<>> -> Name;
        Plan -> <<Name/binary, " · "/utf8, Plan/binary>>
    end,
    Now = erlang:system_time(millisecond),
    Detail = iolist_to_binary([
        <<"chatgpt account">>,
        case selected(Credential) of true -> <<" · selected"/utf8>>; false -> <<>> end,
        case albedo_accounts:limited(Credential, Now) of
            true -> [<<" · limited until "/utf8>>, albedo_accounts:local_time(maps:get(<<"limitedUntil">>, Credential))];
            false -> <<>>
        end
    ]),
    {account, identity(Credential), Label, Detail, selected(Credential)};
codex_account(_) -> {account, <<>>, <<"invalid chatgpt account">>, <<>>, false}.

post_token(Body) ->
    case albedo_http:post(?TOKEN_URL, [{"accept", "application/json"}],
                          "application/x-www-form-urlencoded", binary_to_list(Body),
                          ?HTTP_TIMEOUT_MS, 10000) of
        {ok, {200, _, Response}} -> {ok, Response};
        {ok, {Status, _, Response}} ->
            Detail = case string:trim(binary:part(Response, 0, min(byte_size(Response), 4096))) of
                <<>> -> <<>>;
                Text -> <<": ", Text/binary>>
            end,
            {error, Status, Detail};
        _ -> {error, <<"codex token exchange failed">>}
    end.

codex_access(Home0, Session0) ->
    Home = text(Home0),
    Session = unicode:characters_to_binary(Session0),
    Path = albedo_credentials:creds_path(Home),
    case albedo_credentials:accounts(Path) of
        {ok, Data} ->
            Credentials = credentials(Data),
            select(albedo_accounts:order(?SCOPE, Credentials, Session, fun identity/1), Path, Session);
        {error, _} -> {error, <<"Codex is not authenticated; run /login and add a ChatGPT account">>}
    end.

select([], _, _) -> {error, <<"Codex is not authenticated; run /login and add a ChatGPT account">>};
select([Credential | Rest], Path, Session) ->
    Outcome = case usable(Credential) of
        {ok, Ready} -> {ok, Ready};
        refresh -> refresh_locked(Path, identity(Credential));
        error -> {error, invalid}
    end,
    case Outcome of
        {ok, Access} ->
            remember(Session, Access),
            encode_access(Access);
        _ -> select(Rest, Path, Session)
    end.

%% Drops the account whose access token the server rejected, so the next turn
%% picks a sibling or asks for /login instead of replaying a revoked token.
%% Returns the removed account's email, or <<>> when none is recorded.
codex_revoke(Home0, Access) ->
    Path = albedo_credentials:creds_path(Home0),
    Identity = identity(#{<<"access">> => Access}),
    albedo_credentials:with_lock(Path, fun() -> remove_identity(Path, Access, Identity) end,
                                 fun() -> {error, <<"credential store is busy">>} end).

remove_identity(Path, Access, Identity) ->
    case albedo_credentials:accounts(Path) of
        {ok, Data} ->
            Values = credentials(Data),
            Revoked = fun(Value) ->
                maps:get(<<"access">>, Value, <<>>) =:= Access orelse
                (Identity =/= <<>> andalso identity(Value) =:= Identity)
            end,
            case lists:partition(Revoked, Values) of
                {[], _} -> {ok, <<>>};
                {[Removed | _], Kept} ->
                    case albedo_credentials:put_accounts(Path, albedo_credentials:put_values(Data, ?STORE, Kept)) of
                        ok -> {ok, email(Removed)};
                        {error, _} -> {error, <<"could not remove revoked Codex credential">>}
                    end
            end;
        {error, enoent} -> {ok, <<>>};
        {error, _} -> {error, <<"stored Codex credentials are unreadable">>}
    end.

email(Credential) ->
    Claims = token_identity(maps:get(<<"access">>, Credential, <<>>)),
    first([maps:get(<<"email">>, Claims, undefined), lower(maps:get(<<"email">>, Credential, undefined))]).

encode_access(Credential) ->
    Access = maps:get(<<"access">>, Credential),
    AccountId = account_id(Credential),
    {ok, iolist_to_binary(json:encode(#{<<"access">> => Access, <<"accountId">> => AccountId}))}.

usable(Credential) when is_map(Credential) ->
    Access = maps:get(<<"access">>, Credential, undefined),
    Refresh = maps:get(<<"refresh">>, Credential, undefined),
    Expires = maps:get(<<"expires">>, Credential, 0),
    AccountId = account_id(Credential),
    RefreshBefore = erlang:system_time(millisecond) + ?REFRESH_SKEW_MS,
    case is_binary(Access) andalso Access =/= <<>> andalso
         is_binary(Refresh) andalso Refresh =/= <<>> andalso
         is_binary(AccountId) andalso AccountId =/= <<>> andalso is_integer(Expires) of
        true when Expires > RefreshBefore -> {ok, Credential};
        true -> refresh;
        false -> error
    end;
usable(_) -> error.

credentials(Data) when is_map(Data) -> albedo_credentials:oauth(Data, ?STORE);
credentials(_) -> [].

%% Every stored ChatGPT account for the quota poller, each refreshed the way a
%% request refreshes it: `label` is the account's non-secret identity, the rest
%% are the provide-usage credential fields. The refresh token stays home:
%% albedo refreshes, and the core never reads it. A refresh that fails keeps the
%% stored credential, so the poll records the auth failure as a reading
%% instead of silently dropping the account.
accounts(Home0) ->
    Path = albedo_credentials:creds_path(text(Home0)),
    case albedo_credentials:accounts(Path) of
        {ok, Data} ->
            [entry(V) || V <- [refreshed(Path, C) || C <- credentials(Data)], label(V) =/= <<>>];
        _ -> []
    end.

refreshed(Path, Credential) ->
    case usable(Credential) of
        {ok, Ready} -> Ready;
        refresh ->
            case refresh_locked(Path, identity(Credential)) of
                {ok, Updated} -> Updated;
                _ -> Credential
            end;
        error -> Credential
    end.

label(Credential) ->
    first([email(Credential), account_id(Credential), short_hash(maps:get(<<"refresh">>, Credential, <<>>))]).

entry(Value) ->
    maps:merge(#{<<"label">> => label(Value)}, fields(Value)).

fields(Value) ->
    maps:from_list([{K, field(Value, K)}
                    || K <- [<<"access">>, <<"accountId">>, <<"email">>]]).

field(Value, Key) ->
    case maps:get(Key, Value, <<>>) of
        Text when is_binary(Text) -> Text;
        _ -> <<>>
    end.

short_hash(Token) when is_binary(Token), byte_size(Token) > 0 ->
    binary:encode_hex(binary:part(crypto:hash(sha256, Token), 0, 8), lowercase);
short_hash(_) -> <<>>.

selected(Credential) -> maps:get(<<"selected">>, Credential, false) =:= true.

%% Records a Codex limit response against the account that received it, so
%% this and later requests move to a sibling. Returns a JSON summary for the
%% message, or {error, not_usage_limit} when the body is not a limit.
codex_limited(Home0, Access, Body) ->
    case usage_limit(Body) of
        {ok, Until, Lasting} ->
            Path = albedo_credentials:creds_path(Home0),
            Identity = identity(#{<<"access">> => Access}),
            Hit = fun(V) -> maps:get(<<"access">>, V, <<>>) =:= Access orelse
                            (Identity =/= <<>> andalso identity(V) =:= Identity) end,
            case albedo_accounts:mark(Path, ?STORE, Hit, Until) of
                {ok, Updated} -> summary(credentials(#{?STORE => Updated}), Hit, Until, Lasting);
                Error -> Error
            end;
        error -> {error, <<"not_usage_limit">>}
    end.

usage_limit(Body) ->
    try json:decode(unicode:characters_to_binary(Body)) of
        #{<<"error">> := #{<<"type">> := Type} = Error}
          when Type =:= <<"usage_limit_reached">>; Type =:= <<"usage_not_included">> ->
            Now = erlang:system_time(millisecond),
            Until = case Error of
                #{<<"resets_at">> := At} when is_integer(At), At * 1000 > Now -> At * 1000;
                #{<<"resets_in_seconds">> := In} when is_integer(In), In > 0 -> Now + In * 1000;
                _ -> Now + ?DEFAULT_LIMIT_MS
            end,
            {ok, Until, true};
        %% A short-term rate limit cools the account down briefly, so a busy
        %% swarm spreads onto siblings instead of queueing on one account.
        #{<<"error">> := #{<<"type">> := <<"rate_limit_exceeded">>} = Error} ->
            Now = erlang:system_time(millisecond),
            case Error of
                #{<<"resets_in_seconds">> := In} when is_integer(In), In > 0 -> {ok, Now + In * 1000, false};
                _ -> {ok, Now + ?RATE_LIMIT_MS, false}
            end;
        #{<<"error">> := #{<<"code">> := <<"rate_limit_exceeded">>}} ->
            {ok, erlang:system_time(millisecond) + ?RATE_LIMIT_MS, false};
        %% The Codex edge answers a burst with {"detail":"Rate limit exceeded"}.
        #{<<"detail">> := Detail} when is_binary(Detail) ->
            case string:find(string:lowercase(Detail), <<"rate limit">>) of
                nomatch -> error;
                _ -> {ok, erlang:system_time(millisecond) + ?RATE_LIMIT_MS, false}
            end;
        _ -> error
    catch
        _:_ -> error
    end.

summary(Updated, Hit, Until, Lasting) ->
    Now = erlang:system_time(millisecond),
    Limited = [V || V <- Updated, Hit(V)],
    Next = [V || V <- albedo_accounts:order(?SCOPE, Updated, <<>>, fun identity/1),
                 not Hit(V), not albedo_accounts:limited(V, Now)],
    {ok, iolist_to_binary(json:encode(#{
        <<"account">> => describe(Limited),
        <<"until">> => albedo_accounts:local_time(Until),
        <<"next">> => describe(Next),
        <<"lasting">> => Lasting
    }))}.

describe([]) -> <<>>;
describe([Credential | _]) ->
    Email = first([email(Credential), account_id(Credential), <<"another ChatGPT account">>]),
    case plan(Credential) of
        <<>> -> Email;
        Plan -> <<Email/binary, " (", Plan/binary, ")">>
    end.

plan(Credential) ->
    first([maps:get(<<"plan">>, token_identity(maps:get(<<"access">>, Credential, <<>>)), undefined)]).

remember(Session, Credential) ->
    albedo_accounts:remember(?SCOPE, Session, identity(Credential)).

refresh_locked(Path, Identity) ->
    albedo_credentials:with_lock(Path, fun() -> refresh_current(Path, Identity) end,
                                 fun() -> refreshed_after_wait(Path, Identity) end).

refreshed_after_wait(Path, Identity) ->
    case albedo_credentials:accounts(Path) of
        {ok, Data} ->
            case find_identity(credentials(Data), Identity) of
                undefined -> {error, <<"credential changed during refresh">>};
                Current ->
                    case usable(Current) of
                        {ok, Access} -> {ok, Access};
                        _ -> {error, <<"credential store is busy">>}
                    end
            end;
        _ -> {error, <<"credential store is busy">>}
    end.

refresh_current(Path, Identity) ->
    case albedo_credentials:accounts(Path) of
        {ok, Data} ->
            Values = credentials(Data),
            case find_identity(Values, Identity) of
                undefined -> {error, <<"credential changed during refresh">>};
                Current ->
                    case usable(Current) of
                        {ok, Access} -> {ok, Access};
                        refresh ->
                            case refresh_token(Current) of
                                {ok, Updated} ->
                                    UpdatedValues = replace_identity(Values, Identity, Updated),
                                    case albedo_credentials:put_accounts(Path, albedo_credentials:put_values(Data, ?STORE, UpdatedValues)) of
                                        ok -> {ok, Updated};
                                        {error, _} -> {error, <<"could not persist refreshed Codex credential">>}
                                    end;
                                Error -> Error
                            end;
                        error -> {error, <<"stored Codex credential is invalid">>}
                    end
            end;
        Error -> Error
    end.

find_identity(Values, Identity) ->
    case [C || C <- Values, identity(C) =:= Identity] of
        [Found | _] -> Found;
        [] -> undefined
    end.

replace_identity(Values, Identity, Updated) ->
    [case identity(Value) =:= Identity of true -> Updated; false -> Value end || Value <- Values].

refresh_token(Credential) ->
    Body = uri_string:compose_query([
        {<<"grant_type">>, <<"refresh_token">>},
        {<<"refresh_token">>, maps:get(<<"refresh">>, Credential)},
        {<<"client_id">>, ?CLIENT_ID}
    ]),
    case post_token(Body) of
        {ok, Response} -> parse_refresh(Response, Credential);
        {error, Status, _} ->
            {error, iolist_to_binary(io_lib:format("Codex token refresh failed (~B)", [Status]))};
        {error, _} -> {error, <<"Codex token refresh failed">>}
    end.

parse_refresh(Response, Previous) ->
    try json:decode(Response) of
        Token when is_map(Token) ->
            Access = maps:get(<<"access_token">>, Token, undefined),
            ReturnedRefresh = maps:get(<<"refresh_token">>, Token, undefined),
            Refresh = case ReturnedRefresh of
                Value when is_binary(Value), Value =/= <<>> -> Value;
                _ -> maps:get(<<"refresh">>, Previous, undefined)
            end,
            ExpiresIn = maps:get(<<"expires_in">>, Token, undefined),
            case is_binary(Access) andalso Access =/= <<>> andalso
                 is_binary(Refresh) andalso Refresh =/= <<>> andalso
                 is_integer(ExpiresIn) andalso ExpiresIn > 0 of
                true ->
                    Claims = token_identity(Access),
                    Updated0 = Previous#{
                        <<"type">> => <<"oauth">>,
                        <<"access">> => Access,
                        <<"refresh">> => Refresh,
                        <<"expires">> => erlang:system_time(millisecond) + ExpiresIn * 1000
                    },
                    Updated = preserve_identity(Updated0, Claims),
                    case account_id(Updated) of
                        <<>> -> {error, <<"refreshed Codex token has no account identity">>};
                        _ -> {ok, Updated}
                    end;
                false -> {error, <<"Codex token refresh response is incomplete">>}
            end;
        _ -> {error, <<"Codex token refresh response is invalid">>}
    catch
        _:_ -> {error, <<"Codex token refresh response is invalid">>}
    end.

preserve_identity(Credential, Claims) ->
    Valid = maps:filter(fun(_, V) -> is_binary(V) andalso V =/= <<>> end,
                        maps:with([<<"accountId">>, <<"accountUserId">>, <<"email">>], Claims)),
    maps:merge(Credential, Valid).

identity(Credential) ->
    Claims = token_identity(maps:get(<<"access">>, Credential, <<>>)),
    first([
        maps:get(<<"accountUserId">>, Claims, undefined),
        maps:get(<<"accountUserId">>, Credential, undefined),
        maps:get(<<"accountId">>, Claims, undefined),
        maps:get(<<"accountId">>, Credential, undefined),
        lower(maps:get(<<"email">>, Credential, undefined)),
        maps:get(<<"refresh">>, Credential, <<>>)
    ]).

account_id(Credential) ->
    Claims = token_identity(maps:get(<<"access">>, Credential, <<>>)),
    first([maps:get(<<"accountId">>, Claims, undefined), maps:get(<<"accountId">>, Credential, <<>>)]).

first([]) -> <<>>;
first([Value | _]) when is_binary(Value), Value =/= <<>> -> Value;
first([_ | Rest]) -> first(Rest).

lower(Value) when is_binary(Value) -> string:lowercase(Value);
lower(_) -> undefined.

token_identity(Token) when is_binary(Token) ->
    case binary:split(Token, <<".">>, [global]) of
        [_, Payload, _] -> decode_claims(Payload);
        _ -> #{}
    end;
token_identity(_) -> #{}.

decode_claims(Payload) ->
    try
        Claims = json:decode(base64:decode(Payload, #{mode => urlsafe, padding => false})),
        Auth = maps:get(<<"https://api.openai.com/auth">>, Claims, #{}),
        Profile = maps:get(<<"https://api.openai.com/profile">>, Claims, #{}),
        maps:filter(fun(_, V) -> is_binary(V) andalso V =/= <<>> end, #{
            <<"accountId">> => maps:get(<<"chatgpt_account_id">>, Auth, undefined),
            <<"accountUserId">> => maps:get(<<"chatgpt_account_user_id">>, Auth, undefined),
            <<"email">> => lower(maps:get(<<"email">>, Profile, undefined)),
            <<"plan">> => maps:get(<<"chatgpt_plan_type">>, Auth, undefined)
        })
    catch
        _:_ -> #{}
    end.

text(Value) -> unicode:characters_to_list(Value).
