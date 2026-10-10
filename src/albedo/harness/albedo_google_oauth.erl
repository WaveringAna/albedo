-module(albedo_google_oauth).
%% The Google OAuth mechanics antigravity and colab share: the authorization
%% code exchange, the account's email, and a stored account refreshed under the
%% credential lock. An app is #{name, client_id, client_secret, key, required}:
%% the label in messages, the OAuth client, the creds.json accounts key, and
%% the fields a stored account must hold to be usable; `token_url` overrides
%% Google's refresh endpoint (tests point it at a local server).

-export([exchange/4, email/2, ensure/3, identity/1]).

-define(TOKEN_URL, "https://oauth2.googleapis.com/token").
-define(REFRESH_SKEW_MS, 60000).
%% Google access tokens live an hour; store them as expiring five minutes early.
-define(EXPIRY_MARGIN_MS, 300000).
-define(HTTP_TIMEOUT_MS, 15000).

%% The tokens a sign-in code buys: #{<<"access">>, <<"refresh">>, <<"expires">>}.
exchange(#{name := Name, client_id := Id, client_secret := Secret}, TokenUrl, Code, Redirect) ->
    Form = uri_string:compose_query([
        {<<"client_id">>, Id},
        {<<"client_secret">>, Secret},
        {<<"code">>, Code},
        {<<"grant_type">>, <<"authorization_code">>},
        {<<"redirect_uri">>, Redirect}
    ]),
    case albedo_http:fetch(post, TokenUrl, [], {"application/x-www-form-urlencoded", Form}) of
        {ok, 200, Body} ->
            try json:decode(Body) of
                Token -> exchanged(Name, Token)
            catch _:_ -> {error, <<Name/binary, " token exchange response is invalid">>} end;
        {ok, Status, Body} -> {error, albedo_http:failure(<<Name/binary, " token exchange">>, Status, Body)};
        {error, _} = Error -> Error
    end.

exchanged(_, #{<<"access_token">> := <<_, _/binary>> = Access,
               <<"refresh_token">> := <<_, _/binary>> = Refresh,
               <<"expires_in">> := In}) when is_integer(In), In > 0 ->
    {ok, #{<<"access">> => Access, <<"refresh">> => Refresh, <<"expires">> => expiry(In)}};
exchanged(_, #{<<"access_token">> := _}) ->
    {error, <<"no refresh token received; sign in again">>};
exchanged(Name, _) ->
    {error, <<Name/binary, " token exchange response is incomplete">>}.

expiry(In) -> erlang:system_time(millisecond) + In * 1000 - ?EXPIRY_MARGIN_MS.

%% #{<<"email">> => Lowercased} when Google names one, else #{}.
email(Url, Access) ->
    case albedo_http:fetch(get, Url, [{"authorization", "Bearer " ++ binary_to_list(Access)}], none) of
        {ok, 200, Body} ->
            try json:decode(Body) of
                #{<<"email">> := <<_, _/binary>> = Email} -> #{<<"email">> => string:lowercase(Email)};
                _ -> #{}
            catch _:_ -> #{} end;
        _ -> #{}
    end.

%% The account's identity in the store: its email, else its refresh token.
identity(Credential) ->
    case maps:get(<<"email">>, Credential, <<>>) of
        <<_, _/binary>> = Email -> {email, string:lowercase(Email)};
        _ -> {refresh, maps:get(<<"refresh">>, Credential, <<>>)}
    end.

%% The credential as given while it has an hour left, else refreshed and saved
%% under the lock. {error, invalid} when it lacks a required field.
ensure(App, Path, Credential) ->
    case usable(App, Credential) of
        fresh -> {ok, Credential};
        stale -> albedo_settings_lock:with_lock(filename:dirname(Path),
                     fun() -> refresh_current(App, Path, identity(Credential)) end,
                     fun() -> {error, <<"credential store is busy">>} end);
        invalid -> {error, invalid}
    end.

usable(#{required := Required}, Credential) ->
    Valid = fun(Key) -> case maps:get(Key, Credential, <<>>) of <<_, _/binary>> -> true; _ -> false end end,
    Expires = maps:get(<<"expires">>, Credential, 0),
    Now = erlang:system_time(millisecond),
    case lists:all(Valid, Required) andalso is_integer(Expires) of
        false -> invalid;
        true when Expires > Now + ?REFRESH_SKEW_MS -> fresh;
        true -> stale
    end.

%% Re-read under the lock: a concurrent session may already have refreshed.
refresh_current(#{name := Name, key := Key} = App, Path, Identity) ->
    case albedo_credentials:accounts(Path) of
        {ok, Data} ->
            Values = maps:get(Key, Data, []),
            Listed = is_list(Values),
            All = case Listed of true -> Values; false -> [Values] end,
            case [V || V <- albedo_credentials:oauth(Data, Key), identity(V) =:= Identity] of
                [] -> {error, <<"credential changed during refresh">>};
                [Current | _] ->
                    case usable(App, Current) of
                        fresh -> {ok, Current};
                        invalid -> {error, <<"stored ", Name/binary, " credential is invalid">>};
                        stale ->
                            case refresh_token(App, Current) of
                                {ok, Updated} ->
                                    Replaced = [case is_map(V) andalso identity(V) =:= Identity of
                                                    true -> Updated;
                                                    false -> V
                                                end || V <- All],
                                    Stored = case Listed of true -> Replaced; false -> hd(Replaced) end,
                                    case albedo_credentials:put_accounts(Path, Data#{Key => Stored}) of
                                        ok -> {ok, Updated};
                                        {error, _} -> {error, <<"could not persist refreshed ", Name/binary, " credential">>}
                                    end;
                                Error -> Error
                            end
                    end
            end;
        Error -> Error
    end.

refresh_token(#{name := Name, client_id := Id, client_secret := Secret} = App, Credential) ->
    Body = uri_string:compose_query([
        {<<"client_id">>, Id},
        {<<"client_secret">>, Secret},
        {<<"refresh_token">>, maps:get(<<"refresh">>, Credential)},
        {<<"grant_type">>, <<"refresh_token">>}
    ]),
    case albedo_http:post(maps:get(token_url, App, ?TOKEN_URL), [{"accept", "application/json"}],
                          "application/x-www-form-urlencoded", binary_to_list(Body),
                          ?HTTP_TIMEOUT_MS, 10000) of
        {ok, {200, _, Response}} -> refreshed(Name, Response, Credential);
        {ok, {Status, _, _}} ->
            {error, iolist_to_binary(io_lib:format("~s token refresh failed (~B)", [Name, Status]))};
        _ -> {error, <<Name/binary, " token refresh failed">>}
    end.

refreshed(Name, Response, Previous) ->
    try json:decode(Response) of
        #{<<"access_token">> := <<_, _/binary>> = Access, <<"expires_in">> := In} = Token
          when is_integer(In), In > 0 ->
            Refresh = case maps:get(<<"refresh_token">>, Token, <<>>) of
                <<_, _/binary>> = Rotated -> Rotated;
                _ -> maps:get(<<"refresh">>, Previous)
            end,
            {ok, Previous#{<<"access">> => Access, <<"refresh">> => Refresh, <<"expires">> => expiry(In)}};
        _ -> {error, <<Name/binary, " token refresh response is incomplete">>}
    catch
        _:_ -> {error, <<Name/binary, " token refresh response is invalid">>}
    end.
