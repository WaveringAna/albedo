-module(albedo_colab_auth).

-export([exchange/3, account/1, client_id/0, client_secret/0]).

-define(KEY, <<"google-colab">>).
-define(CLIENT_ID, <<"764086051850-6qr4p6gpi6hn506pt8ejuq83di341hur.apps.googleusercontent.com">>).
-define(CLIENT_SECRET, <<"d-FL95Q19q7MQmFpd7hHD0Ty">>).
-define(TOKEN_URL, "https://oauth2.googleapis.com/token").
-define(USERINFO_URL, "https://www.googleapis.com/oauth2/v1/userinfo?alt=json").
-define(EXPIRY_MARGIN_MS, 300000).

client_id() -> ?CLIENT_ID.
client_secret() -> ?CLIENT_SECRET.

exchange(Code, Redirect, Progress) ->
    Form = uri_string:compose_query([
        {<<"client_id">>, ?CLIENT_ID},
        {<<"client_secret">>, ?CLIENT_SECRET},
        {<<"code">>, Code},
        {<<"grant_type">>, <<"authorization_code">>},
        {<<"redirect_uri">>, Redirect}
    ]),
    case http(post, ?TOKEN_URL, [], {"application/x-www-form-urlencoded", Form}) of
        {ok, 200, Body} ->
            case json:decode(Body) of
                #{<<"access_token">> := <<_, _/binary>> = Access,
                  <<"refresh_token">> := <<_, _/binary>> = Refresh,
                  <<"expires_in">> := In} when is_integer(In), In > 0 ->
                    Progress(<<"getting user info">>),
                    Email = email(?USERINFO_URL, Access),
                    {ok, json:encode(maps:merge(Email, #{
                        <<"type">> => <<"oauth">>,
                        <<"access">> => Access,
                        <<"refresh">> => Refresh,
                        <<"expires">> => erlang:system_time(millisecond) + In * 1000 - ?EXPIRY_MARGIN_MS
                    }))};
                #{<<"access_token">> := _} ->
                    {error, <<"no refresh token received; sign in again">>};
                _ ->
                    {error, <<"Google Colab token exchange response is incomplete">>}
            end;
        {ok, Status, Body} ->
            {error, failure(<<"Google Colab token exchange">>, Status, Body)};
        {error, Reason} ->
            {error, Reason}
    end.

email(Url, Access) ->
    case http(get, Url, [{"authorization", "Bearer " ++ binary_to_list(Access)}], none) of
        {ok, 200, Body} ->
            try json:decode(Body) of
                #{<<"email">> := <<_, _/binary>> = Email} -> #{<<"email">> => Email};
                _ -> #{}
            catch _:_ -> #{} end;
        _ -> #{}
    end.

http(Method, Url0, Headers, Body) ->
    case albedo_http:request(Method, Url0, Headers, Body, 30000, 10000) of
        {ok, {Status, _, Response}} -> {ok, Status, Response};
        {error, _} ->
            Url = unicode:characters_to_list(Url0),
            Host = unicode:characters_to_binary(maps:get(host, uri_string:parse(Url), "")),
            {error, <<"could not reach ", Host/binary>>}
    end.

failure(Context, Status, Body) ->
    iolist_to_binary(io_lib:format("~s failed (~B): ~s", [Context, Status, Body])).

account(Credential) when is_map(Credential) ->
    Email = case maps:get(<<"email">>, Credential, <<>>) of
        <<_, _/binary>> = Email0 -> Email0;
        _ -> <<"google-colab account">>
    end,
    Selected = maps:get(<<"selected">>, Credential, false) =:= true,
    Detail = iolist_to_binary([
        <<"Google Colab account">>,
        case Selected of true -> <<" · selected"/utf8>>; false -> <<>> end
    ]),
    {account, Email, Email, Detail, Selected};
account(_) ->
    {account, <<"colab">>, <<"colab">>, <<"Google Colab account">>, false}.
