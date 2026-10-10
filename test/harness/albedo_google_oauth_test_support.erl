%% The Google account refresh and Colab account choice against a one-shot local token endpoint.
-module(albedo_google_oauth_test_support).
-export([refresh/2, signed_in/1]).

-define(APP, #{name => <<"Google Colab">>, client_id => <<"id">>, client_secret => <<"secret">>,
               key => <<"google-colab">>, required => [<<"access">>, <<"refresh">>]}).

%% Refreshes the first account of AccountsJson against a server answering Status
%% and Body: {Result, creds.json after, the form the server received}.
refresh(AccountsJson, {Status, Body}) ->
    Home = home(AccountsJson),
    {Url, Await} = serve(Status, Body),
    Path = albedo_credentials:creds_path(Home),
    {ok, #{<<"google-colab">> := [First | _]}} = albedo_credentials:accounts(Path),
    Result = case albedo_google_oauth:ensure(?APP#{token_url => Url}, Path, First) of
        {ok, #{<<"access">> := Access}} -> {ok, Access};
        {error, invalid} -> {error, <<"invalid">>};
        {error, _} = Error -> Error
    end,
    {Result, file_text(Path), Await()}.

signed_in(AccountsJson) ->
    albedo_colab_auth:signed_in(home(AccountsJson)).

home(AccountsJson) ->
    Home = filename:join(os:getenv("TMPDIR", "/tmp"), "albedo-google-" ++ integer_to_list(erlang:unique_integer([positive]))),
    ok = filelib:ensure_path(Home),
    ok = file:write_file(filename:join(Home, "creds.json"),
                         json:encode(#{<<"accounts">> => #{<<"google-colab">> => json:decode(AccountsJson)}})),
    Home.

file_text(Path) ->
    {ok, Text} = file:read_file(Path),
    Text.

serve(Status, Body) ->
    {ok, Listen} = gen_tcp:listen(0, [binary, {active, false}, {packet, http_bin}, {ip, {127, 0, 0, 1}}]),
    {ok, {_, Port}} = inet:sockname(Listen),
    Parent = self(),
    Ref = make_ref(),
    spawn(fun() ->
        {ok, Socket} = accept(Listen),
        {ok, {http_request, _, _, _}} = gen_tcp:recv(Socket, 0, 5000),
        Length = headers(Socket, 0),
        ok = inet:setopts(Socket, [{packet, raw}]),
        {ok, Form} = gen_tcp:recv(Socket, Length, 5000),
        ok = gen_tcp:send(Socket, ["HTTP/1.1 ", integer_to_list(Status), " X\r\nContent-Type: application/json\r\n",
            "Connection: close\r\nContent-Length: ", integer_to_list(byte_size(Body)), "\r\n\r\n", Body]),
        gen_tcp:close(Socket),
        Parent ! {Ref, Form}
    end),
    Url = "http://127.0.0.1:" ++ integer_to_list(Port) ++ "/token",
    {Url, fun() ->
        receive {Ref, Form} -> gen_tcp:close(Listen), Form
        after 3000 -> gen_tcp:close(Listen), <<"no request">>
        end
    end}.

%% A refresh that needs no request leaves the server waiting; it ends quietly.
accept(Listen) ->
    case gen_tcp:accept(Listen, 2000) of
        {ok, _} = Accepted -> Accepted;
        {error, _} -> exit(normal)
    end.

headers(Socket, Length) ->
    case gen_tcp:recv(Socket, 0, 5000) of
        {ok, http_eoh} -> Length;
        {ok, {http_header, _, 'Content-Length', _, Value}} -> headers(Socket, binary_to_integer(Value));
        {ok, {http_header, _, _, _, _}} -> headers(Socket, Length)
    end.
