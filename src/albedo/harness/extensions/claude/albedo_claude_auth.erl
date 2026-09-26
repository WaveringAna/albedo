-module(albedo_claude_auth).

-export([exchange/4, account/1, access/2, expire/2]).

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
    Body = json:encode(Params),
    _ = application:ensure_all_started(inets),
    _ = application:ensure_all_started(ssl),
    Request = {?TOKEN_URL, [{"accept", "application/json"}], "application/json", Body},
    Options = [{timeout, ?HTTP_TIMEOUT_MS}, {connect_timeout, 10000},
               {ssl, albedo_credentials:tls_options("platform.claude.com")}],
    case httpc:request(post, Request, Options, [{body_format, binary}]) of
        {ok, {{_, 200, _}, _, Response}} -> token(Response);
        {ok, {{_, Status, _}, _, Response}} ->
            Detail = binary:part(Response, 0, min(byte_size(Response), 2048)),
            {error, iolist_to_binary(io_lib:format("Anthropic ~s failed (~B): ~s",
                [atom_to_list(Kind), Status, Detail]))};
        _ -> {error, <<"Anthropic token request failed">>}
    end.

token(Response) ->
    try json:decode(Response) of
        #{<<"access_token">> := Access, <<"refresh_token">> := Refresh,
          <<"expires_in">> := In} when is_binary(Access), byte_size(Access) > 0,
                                        is_binary(Refresh), byte_size(Refresh) > 0,
                                        is_number(In), In > 0 ->
            Credential = #{<<"type">> => <<"oauth">>, <<"access">> => Access,
                <<"refresh">> => Refresh,
                <<"expires">> => erlang:system_time(millisecond) + round(In * 1000) - ?EXPIRY_MARGIN_MS,
                <<"accountId">> => token_id(Refresh)},
            {ok, json:encode(Credential)};
        _ -> {error, <<"Anthropic token response is incomplete">>}
    catch _:_ -> {error, <<"Anthropic token response is invalid">>} end.

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
    case post_token(#{<<"grant_type">> => <<"refresh_token">>, <<"client_id">> => ?CLIENT_ID,
                      <<"refresh_token">> => maps:get(<<"refresh">>, Current)}, refresh) of
        {ok, Encoded} ->
            Token = json:decode(Encoded),
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
