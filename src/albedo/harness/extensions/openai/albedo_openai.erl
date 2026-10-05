-module(albedo_openai).
%% Generic OpenAI-compatible provider: the model ids a configured endpoint
%% serves, asked live from its own /models route.

-export([models/2]).

-define(FETCH_TIMEOUT_MS, 5000).
-define(CONNECT_TIMEOUT_MS, 2000).

%% The ids ${Endpoint}/models lists, sent with the key of the saved openai
%% profile at that endpoint (none when no profile has one). The endpoints
%% models.dev already describes keep its curated list.
models(Home0, Endpoint0) ->
    Endpoint = string:trim(unicode:characters_to_binary(Endpoint0), trailing, "/"),
    case curated(Endpoint) of
        true -> {error, <<"models.dev lists this endpoint">>};
        false -> fetch(Endpoint, key(Home0, Endpoint))
    end.

curated(Endpoint) ->
    case uri_string:parse(Endpoint) of
        #{host := Host} ->
            Host =:= <<"api.openai.com">> orelse Host =:= <<"chatgpt.com">>;
        _ -> false
    end.

fetch(<<>>, _Key) ->
    {error, <<"no endpoint">>};
fetch(Endpoint, Key) ->
    Auth = case Key of
        <<>> -> [];
        _ -> [{"authorization", ["Bearer ", Key]}]
    end,
    Headers = Auth ++ [{"accept", "application/json"}, {"user-agent", "albedo"}],
    case albedo_http:get(<<Endpoint/binary, "/models">>, Headers,
                         ?FETCH_TIMEOUT_MS, ?CONNECT_TIMEOUT_MS) of
        {ok, {200, _, Body}} -> ids(Body);
        {ok, {Status, _, _}} ->
            {error, iolist_to_binary(io_lib:format("endpoint returned HTTP ~B", [Status]))};
        {error, Reason} ->
            {error, iolist_to_binary(io_lib:format("could not reach endpoint: ~p", [Reason]))}
    end.

ids(Body) ->
    try json:decode(iolist_to_binary(Body)) of
        #{<<"data">> := List} when is_list(List) ->
            {ok, lists:usort([Id || #{<<"id">> := Id} <- List, is_binary(Id)])};
        _ -> {error, <<"unexpected /models response shape">>}
    catch _:_ -> {error, <<"invalid JSON from /models">>}
    end.

key(Home, Endpoint) ->
    case albedo_credentials:config(unicode:characters_to_list(Home)) of
        {ok, #{<<"providers">> := Providers}} when is_map(Providers) ->
            Keys = [Key || {_, #{<<"apiKey">> := <<_, _/binary>> = Key} = Profile}
                               <- lists:sort(maps:to_list(Providers)),
                           maps:get(<<"extension">>, Profile, <<"openai">>) =:= <<"openai">>,
                           string:trim(maps:get(<<"baseUrl">>, Profile, <<>>), trailing, "/")
                               =:= Endpoint],
            hd(Keys ++ [<<>>]);
        _ -> <<>>
    end.
