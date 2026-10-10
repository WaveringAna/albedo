-module(albedo_colab_auth).
%% Google Colab sign-in and the account the kernel's `colab` binding asks for. The Google mechanics are albedo_google_oauth's.

-export([exchange/3, account/1, client_id/0, signed_in/1]).

-define(KEY, <<"google-colab">>).
-define(CLIENT_ID, <<"764086051850-6qr4p6gpi6hn506pt8ejuq83di341hur.apps.googleusercontent.com">>).
-define(CLIENT_SECRET, <<"d-FL95Q19q7MQmFpd7hHD0Ty">>).
-define(TOKEN_URL, "https://oauth2.googleapis.com/token").
-define(USERINFO_URL, "https://www.googleapis.com/oauth2/v1/userinfo?alt=json").
-define(SIGNED_OUT, <<"Google Colab is not authenticated; run /login and add a Google Colab account">>).

client_id() -> ?CLIENT_ID.

app() ->
    #{name => <<"Google Colab">>, client_id => ?CLIENT_ID, client_secret => ?CLIENT_SECRET,
      key => ?KEY, required => [<<"access">>, <<"refresh">>]}.

exchange(Code, Redirect, Progress) ->
    case albedo_google_oauth:exchange(app(), ?TOKEN_URL, Code, Redirect) of
        {ok, #{<<"access">> := Access} = Tokens} ->
            Progress(<<"getting user info">>),
            Email = albedo_google_oauth:email(?USERINFO_URL, Access),
            {ok, maps:merge(Email, Tokens#{<<"type">> => <<"oauth">>})};
        {error, _} = Error -> Error
    end.

%% {Access, Email} of the selected account (else the first), the token
%% refreshed and saved under the credential lock. The refresh token stays here.
signed_in(Home) ->
    Path = albedo_credentials:creds_path(Home),
    case albedo_credentials:accounts(Path) of
        {ok, Data} ->
            case albedo_credentials:oauth(Data, ?KEY) of
                [] -> {error, ?SIGNED_OUT};
                Accounts ->
                    Chosen = hd([A || A <- Accounts, maps:get(<<"selected">>, A, false) =:= true] ++ Accounts),
                    case albedo_google_oauth:ensure(app(), Path, Chosen) of
                        {ok, #{<<"access">> := Access} = Fresh} -> {ok, {Access, maps:get(<<"email">>, Fresh, <<>>)}};
                        {error, invalid} -> {error, ?SIGNED_OUT};
                        {error, _} = Error -> Error
                    end
            end;
        {error, _} -> {error, ?SIGNED_OUT}
    end.

%% How /login lists a stored Colab account.
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
