-module(albedo_openai_auth).
%% Codex sign-in, multi-account credential selection, and refresh.

-export([codex_access/2, codex_revoke/2, codex_limited/3, codex_exchange/3, codex_account/1]).

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
        case limited(Credential, Now) of
            true -> [<<" · usage limit until "/utf8>>, local_time(maps:get(<<"limitedUntil">>, Credential))];
            false -> <<>>
        end
    ]),
    {account, identity(Credential), Label, Detail, selected(Credential)};
codex_account(_) -> {account, <<>>, <<"invalid chatgpt account">>, <<>>, false}.

post_token(Body) ->
    _ = application:ensure_all_started(inets),
    _ = application:ensure_all_started(ssl),
    Request = {?TOKEN_URL, [{"accept", "application/json"}],
               "application/x-www-form-urlencoded", binary_to_list(Body)},
    Options = [{timeout, ?HTTP_TIMEOUT_MS}, {connect_timeout, 10000},
               {ssl, albedo_credentials:tls_options("auth.openai.com")}],
    case httpc:request(post, Request, Options, [{body_format, binary}]) of
        {ok, {{_, 200, _}, _, Response}} -> {ok, Response};
        {ok, {{_, Status, _}, _, Response}} ->
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
    Path = filename:join(Home, "auth.json"),
    case read_auth(Path) of
        {ok, Data} ->
            Credentials = credentials(Data),
            select(order(Credentials, Session), Path, Session);
        {error, _} -> {error, <<"Codex is not authenticated; run /login and add a ChatGPT account">>}
    end.

select([], _, _) -> {error, <<"Codex is not authenticated; run /login and add a ChatGPT account">>};
select([Credential | Rest], Path, Session) ->
    case usable(Credential) of
        {ok, Access} ->
            remember(Session, Access),
            encode_access(Access);
        refresh ->
            case refresh_locked(Path, identity(Credential)) of
                {ok, Access} ->
                    remember(Session, Access),
                    encode_access(Access);
                {error, _} -> select(Rest, Path, Session)
            end;
        error -> select(Rest, Path, Session)
    end.

%% Drops the account whose access token the server rejected, so the next turn
%% picks a sibling or asks for /login instead of replaying a revoked token.
%% Returns the removed account's email, or <<>> when none is recorded.
codex_revoke(Home0, Access) ->
    Path = filename:join(text(Home0), "auth.json"),
    Identity = identity(#{<<"access">> => Access}),
    albedo_credentials:with_lock(Path, fun() -> remove_identity(Path, Access, Identity) end,
                                 fun() -> {error, <<"credential store is busy">>} end).

remove_identity(Path, Access, Identity) ->
    case read_auth(Path) of
        {ok, Data} ->
            Values = credentials(Data),
            Revoked = fun(Value) ->
                maps:get(<<"access">>, Value, <<>>) =:= Access orelse
                (Identity =/= <<>> andalso identity(Value) =:= Identity)
            end,
            case lists:partition(Revoked, Values) of
                {[], _} -> {ok, <<>>};
                {[Removed | _], Kept} ->
                    Updated = case Kept of
                        [] -> maps:remove(<<"openai-codex">>, Data);
                        _ -> set_credentials(Data, Kept)
                    end,
                    case write_auth(Path, Updated) of
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

credentials(Data) when is_map(Data) ->
    case maps:get(<<"openai-codex">>, Data, []) of
        Values when is_list(Values) -> [V || V <- Values, is_map(V), maps:get(<<"type">>, V, <<>>) =:= <<"oauth">>];
        Value when is_map(Value) ->
            case maps:get(<<"type">>, Value, <<>>) of <<"oauth">> -> [Value]; _ -> [] end;
        _ -> []
    end;
credentials(_) -> [].

%% A user-selected account comes first, then the session's sticky or hashed
%% choice. Accounts still inside a reported usage limit go last: they are only
%% worth trying when every sibling is limited too.
order([], _) -> [];
order(Values, Session) ->
    Now = erlang:system_time(millisecond),
    {Limited, Open} = lists:partition(fun(V) -> limited(V, Now) end, Values),
    {Selected, Rest} = lists:partition(fun selected/1, spread(Open, Session)),
    Selected ++ Rest ++ Limited.

spread([], _) -> [];
spread(Values, Session) ->
    case erlang:get({?MODULE, Session}) of
        Identity when is_binary(Identity), Identity =/= <<>> ->
            {Pinned, Others} = lists:partition(fun(Value) -> identity(Value) =:= Identity end, Values),
            Pinned ++ Others;
        _ ->
            N = length(Values),
            Start = fnv1a(Session) rem N,
            {Head, Tail} = lists:split(Start, Values),
            Tail ++ Head
    end.

selected(Credential) -> maps:get(<<"selected">>, Credential, false) =:= true.

limited(Credential, Now) ->
    case maps:get(<<"limitedUntil">>, Credential, 0) of
        Until when is_integer(Until) -> Until > Now;
        _ -> false
    end.

%% Records a Codex usage-limit response against the account that received it,
%% so the next turn moves to a sibling. Returns a JSON summary for the message,
%% or {error, not_usage_limit} for ordinary rate limiting.
codex_limited(Home0, Access, Body) ->
    case usage_limit(Body) of
        {ok, Until} ->
            Path = filename:join(text(Home0), "auth.json"),
            Identity = identity(#{<<"access">> => Access}),
            albedo_credentials:with_lock(Path, fun() -> mark_limited(Path, Access, Identity, Until) end,
                                         fun() -> {error, <<"credential store is busy">>} end);
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
            {ok, Until};
        %% A short-term rate limit cools the account down briefly, so a busy
        %% swarm spreads onto siblings instead of queueing on one account.
        #{<<"error">> := #{<<"type">> := <<"rate_limit_exceeded">>} = Error} ->
            Now = erlang:system_time(millisecond),
            case Error of
                #{<<"resets_in_seconds">> := In} when is_integer(In), In > 0 -> {ok, Now + In * 1000};
                _ -> {ok, Now + ?RATE_LIMIT_MS}
            end;
        _ -> error
    catch
        _:_ -> error
    end.

mark_limited(Path, Access, Identity, Until) ->
    case read_auth(Path) of
        {ok, Data} ->
            Values = credentials(Data),
            Hit = fun(V) -> maps:get(<<"access">>, V, <<>>) =:= Access orelse
                            (Identity =/= <<>> andalso identity(V) =:= Identity) end,
            Updated = [case Hit(V) of true -> V#{<<"limitedUntil">> => Until}; false -> V end || V <- Values],
            case Updated =:= Values orelse write_auth(Path, set_credentials(Data, Updated)) =:= ok of
                true -> summary(Updated, Hit, Until);
                false -> {error, <<"could not record the Codex usage limit">>}
            end;
        {error, _} -> {error, <<"stored Codex credentials are unreadable">>}
    end.

summary(Updated, Hit, Until) ->
    Now = erlang:system_time(millisecond),
    Limited = [V || V <- Updated, Hit(V)],
    Next = [V || V <- order(Updated, <<>>), not Hit(V), not limited(V, Now)],
    {ok, iolist_to_binary(json:encode(#{
        <<"account">> => describe(Limited),
        <<"until">> => local_time(Until),
        <<"next">> => describe(Next)
    }))}.

local_time(Ms) ->
    {{_, _, _} = Date, {H, M, _}} = calendar:system_time_to_local_time(Ms, millisecond),
    {Today, _} = calendar:local_time(),
    Clock = io_lib:format("~2..0B:~2..0B", [H, M]),
    iolist_to_binary(case Date =:= Today of
        true -> Clock;
        false -> {Y, Mo, D} = Date, io_lib:format("~4..0B-~2..0B-~2..0B ~s", [Y, Mo, D, Clock])
    end).

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
    erlang:put({?MODULE, Session}, identity(Credential)),
    ok.

fnv1a(Bytes) ->
    lists:foldl(fun(Byte, Hash) -> ((Hash bxor Byte) * 16777619) band 16#ffffffff end,
                16#811c9dc5, binary_to_list(Bytes)).

refresh_locked(Path, Identity) ->
    albedo_credentials:with_lock(Path, fun() -> refresh_current(Path, Identity) end,
                                 fun() -> refreshed_after_wait(Path, Identity) end).

refreshed_after_wait(Path, Identity) ->
    case read_auth(Path) of
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
    case read_auth(Path) of
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
                                    case write_auth(Path, set_credentials(Data, UpdatedValues)) of
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

find_identity([], _) -> undefined;
find_identity([Credential | Rest], Identity) ->
    case identity(Credential) =:= Identity of
        true -> Credential;
        false -> find_identity(Rest, Identity)
    end.

replace_identity(Values, Identity, Updated) ->
    [case identity(Value) =:= Identity of true -> Updated; false -> Value end || Value <- Values].

set_credentials(Data, [Only]) -> maps:put(<<"openai-codex">>, Only, Data);
set_credentials(Data, Values) -> maps:put(<<"openai-codex">>, Values, Data).

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
    lists:foldl(fun(Key, Acc) ->
        case maps:get(Key, Claims, undefined) of
            Value when is_binary(Value), Value =/= <<>> -> maps:put(Key, Value, Acc);
            _ -> Acc
        end
    end, Credential, [<<"accountId">>, <<"accountUserId">>, <<"email">>]).

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
        Padded = pad64(binary:replace(binary:replace(Payload, <<"-">>, <<"+">>, [global]),
                                      <<"_">>, <<"/">>, [global])),
        Claims = json:decode(base64:decode(Padded)),
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

pad64(Value) ->
    case byte_size(Value) rem 4 of
        0 -> Value;
        2 -> <<Value/binary, "==">>;
        3 -> <<Value/binary, "=">>;
        _ -> Value
    end.

read_auth(Path) -> albedo_credentials:read(Path).

write_auth(Path, Data) -> albedo_credentials:write(Path, Data).

text(Value) -> unicode:characters_to_list(Value).
