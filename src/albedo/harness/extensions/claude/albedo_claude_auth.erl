-module(albedo_claude_auth).

-export([exchange/4, account/1, access/2, profile/2, expire/2, token/1]).

-define(KEY, <<"anthropic">>).
-define(CLIENT_ID, <<"9d1c250a-e61b-44d9-88ed-5944d1962f5e">>).
-define(TOKEN_URL, "https://platform.claude.com/v1/oauth/token").
-define(HTTP_TIMEOUT_MS, 30000).
-define(REFRESH_SKEW_MS, 60000).
-define(EXPIRY_MARGIN_MS, 300000).

exchange(Code, State, Verifier, Redirect) ->
    post_token(#{<<"grant_type">> => <<"authorization_code">>,
                 <<"client_id">> => ?CLIENT_ID, <<"code">> => Code,
                 <<"state">> => State, <<"redirect_uri">> => Redirect,
                 <<"code_verifier">> => Verifier}, exchange).

post_token(Params, Kind) ->
    case token_request(Params, Kind) of
        {ok, Response} -> token(Response);
        Error -> Error
    end.

post_token_map(Params, Kind) ->
    case token_request(Params, Kind) of
        {ok, Response} -> token_map(Response);
        Error -> Error
    end.

token_request(Params, Kind) ->
    Body = json:encode(Params),
    _ = application:ensure_all_started(inets),
    _ = application:ensure_all_started(ssl),
    Request = {?TOKEN_URL, [{"accept", "application/json"}], "application/json", Body},
    Options = [{timeout, ?HTTP_TIMEOUT_MS}, {connect_timeout, 10000},
               {ssl, albedo_credentials:tls_options("platform.claude.com")}],
    case httpc:request(post, Request, Options, [{body_format, binary}]) of
        {ok, {{_, 200, _}, _, Response}} -> {ok, Response};
        {ok, {{_, Status, _}, _, Response}} ->
            Detail = binary:part(Response, 0, min(byte_size(Response), 2048)),
            {error, iolist_to_binary(io_lib:format("Anthropic ~s failed (~B): ~s",
                [atom_to_list(Kind), Status, Detail]))};
        _ -> {error, <<"Anthropic token request failed">>}
    end.

token_map(Response) ->
    try json:decode(Response) of
        #{<<"access_token">> := Access, <<"refresh_token">> := Refresh,
          <<"expires_in">> := In} when is_binary(Access), byte_size(Access) > 0,
                                        is_binary(Refresh), byte_size(Refresh) > 0,
                                        is_number(In), In > 0 ->
            Credential = #{<<"type">> => <<"oauth">>, <<"access">> => Access,
                <<"refresh">> => Refresh,
                <<"expires">> => erlang:system_time(millisecond) + round(In * 1000) - ?EXPIRY_MARGIN_MS,
                <<"accountId">> => token_id(Refresh)},
            {ok, Credential};
        _ -> {error, <<"Anthropic token response is incomplete">>}
    catch _:_ -> {error, <<"Anthropic token response is invalid">>} end.

%% token/1 keeps its shape for callers: response in, storable binary out.
token(Response) ->
    case token_map(Response) of
        {ok, Credential} -> encode_credential(Credential);
        Error -> Error
    end.

%% json:encode builds each map member as `[comma, key, colon | value]', and a
%% number value encodes to a bare binary, leaving an improper tail: legal
%% iodata for iolist_to_binary, but json:decode rejects any list. Encoding is
%% centralized here so no caller ever sees the tree.
encode_credential(Credential) ->
    {ok, iolist_to_binary(json:encode(Credential))}.

account(Credential) when is_map(Credential) ->
    Id = identity(Credential),
    Selected = maps:get(<<"selected">>, Credential, false) =:= true,
    Label = <<"Claude Pro/Max">>,
    Detail = case Selected of true -> <<"Claude account · selected">>; false -> <<"Claude account">> end,
    {account, Id, Label, Detail, Selected};
account(_) -> {account, <<>>, <<"invalid Claude account">>, <<>>, false}.

identity(Credential) -> maps:get(<<"accountId">>, Credential,
    maps:get(<<"email">>, Credential, token_id(maps:get(<<"refresh">>, Credential, <<>>)))).

token_id(Token) ->
    binary:encode_hex(binary:part(crypto:hash(sha256, Token), 0, 8), lowercase).

access(Home0, Session0) ->
    Path = filename:join(unicode:characters_to_list(Home0), "auth.json"),
    Session = unicode:characters_to_binary(Session0),
    case albedo_credentials:read(Path) of
        {ok, Data} ->
            Values = credentials(Data),
            Ordered = albedo_accounts:order(<<"claude">>, Values, Session, fun identity/1),
            first_access(Ordered, Path, Session);
        _ -> {error, <<"Claude is not authenticated; run /login and add a Claude account">>}
    end.

%% A session-stable device and UUID must accompany the OAuth account identity.
%% Resolve the account from the token, never from a claimed client header.
profile(Access, Session) ->
    _ = application:ensure_all_started(inets),
    _ = application:ensure_all_started(ssl),
    Request = {"https://api.anthropic.com/api/oauth/profile",
               [{"authorization", "Bearer " ++ unicode:characters_to_list(Access)},
                {"accept", "application/json"}]},
    Options = [{timeout, ?HTTP_TIMEOUT_MS}, {connect_timeout, 10000},
               {ssl, albedo_credentials:tls_options("api.anthropic.com")}],
    case httpc:request(get, Request, Options, [{body_format, binary}]) of
        {ok, {{_, 200, _}, _, Body}} ->
            try json:decode(Body) of
                #{<<"account">> := #{<<"uuid">> := UUID}} when is_binary(UUID), byte_size(UUID) =:= 36 ->
                    Device = binary:encode_hex(crypto:hash(sha256, <<"albedo:claude-device:", UUID/binary>>), lowercase),
                    {ok, {UUID, Device, session_uuid(Session)}};
                _ -> {error, <<"Claude profile has no account UUID">>}
            catch _:_ -> {error, <<"Claude profile response is invalid">>} end;
        _ -> {error, <<"could not read Claude account profile">>}
    end.

session_uuid(Session) ->
    <<A:32, B:16, _:4, C:12, _:2, D:14, E:48, _/binary>> = crypto:hash(sha256, Session),
    iolist_to_binary(io_lib:format("~8.16.0b-~4.16.0b-4~3.16.0b-~4.16.0b-~12.16.0b",
        [A, B, C, 16#8000 bor D, E])).

credentials(Data) ->
    case maps:get(?KEY, Data, []) of
        List when is_list(List) -> [V || V <- List, is_map(V), maps:get(<<"type">>, V, <<>>) =:= <<"oauth">>];
        V when is_map(V) -> case maps:get(<<"type">>, V, <<>>) of <<"oauth">> -> [V]; _ -> [] end;
        _ -> []
    end.

first_access([], _, _) -> {error, <<"Claude is not authenticated; run /login and add a Claude account">>};
first_access([C | Rest], Path, Session) ->
    Now = erlang:system_time(millisecond),
    Access = maps:get(<<"access">>, C, <<>>),
    Refresh = maps:get(<<"refresh">>, C, <<>>),
    Expires = maps:get(<<"expires">>, C, 0),
    case is_binary(Access) andalso Access =/= <<>> andalso is_binary(Refresh) andalso Refresh =/= <<>> of
        false -> first_access(Rest, Path, Session);
        true when is_integer(Expires), Expires > Now + ?REFRESH_SKEW_MS ->
            albedo_accounts:remember(<<"claude">>, Session, identity(C)), {ok, Access};
        true ->
            case albedo_credentials:with_lock(Path, fun() -> refresh(Path, identity(C)) end,
                    fun() -> {error, <<"credential store is busy">>} end) of
                {ok, Updated} -> albedo_accounts:remember(<<"claude">>, Session, identity(Updated)),
                                 {ok, maps:get(<<"access">>, Updated)};
                _ -> first_access(Rest, Path, Session)
            end
    end.

refresh(Path, Id) ->
    case albedo_credentials:read(Path) of
        {ok, Data} ->
            Values = credentials(Data),
            case lists:partition(fun(C) -> identity(C) =:= Id end, Values) of
                {[Current | _], _} ->
                    case maps:get(<<"expires">>, Current, 0) > erlang:system_time(millisecond) + ?REFRESH_SKEW_MS of
                        true -> {ok, Current};
                        false -> refresh_current(Path, Data, Current)
                    end;
                _ -> {error, <<"Claude credential changed during refresh">>}
            end;
        _ -> {error, <<"Claude credentials are unreadable">>}
    end.

refresh_current(Path, Data, Current) ->
    case post_token_map(#{<<"grant_type">> => <<"refresh_token">>, <<"client_id">> => ?CLIENT_ID,
                          <<"refresh_token">> => maps:get(<<"refresh">>, Current)}, refresh) of
        {ok, Token} ->
            New = (maps:merge(Current, Token))#{<<"accountId">> => identity(Current)},
            Stored = maps:get(?KEY, Data),
            Values = case Stored of L when is_list(L) -> L; V -> [V] end,
            Updated = [case is_map(V) andalso identity(V) =:= identity(Current) of true -> New; false -> V end || V <- Values],
            Saved = case Stored of StoredList when is_list(StoredList) -> Updated; _ -> hd(Updated) end,
            case albedo_credentials:write(Path, Data#{?KEY => Saved}) of
                ok -> {ok, New}; _ -> {error, <<"could not save refreshed Claude credential">>}
            end;
        Error -> Error
    end.

expire(Home0, Access) ->
    Path = filename:join(unicode:characters_to_list(Home0), "auth.json"),
    albedo_credentials:with_lock(Path, fun() ->
        case albedo_credentials:read(Path) of
            {ok, #{?KEY := Stored} = Data} ->
                Expire = fun(#{<<"access">> := A} = V) when A =:= Access -> V#{<<"expires">> => 0};
                            (V) -> V
                         end,
                Updated = case Stored of L when is_list(L) -> lists:map(Expire, L); V -> Expire(V) end,
                case Updated =:= Stored of
                    true -> nil;
                    false -> _ = albedo_credentials:write(Path, Data#{?KEY => Updated}), nil
                end;
            _ -> nil
        end
    end, fun() -> nil end).
