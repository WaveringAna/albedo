-module(albedo_openai).
%% Generic OpenAI-compatible provider: the model ids a configured endpoint
%% serves, asked from its own /models route and remembered for a while, so an
%% endpoint that never answers costs one timeout per window, not one per
%% caller (the model picker and every agent spawn list every profile).

-export([models/2]).

-define(FETCH_TIMEOUT_MS, 5000).
-define(CONNECT_TIMEOUT_MS, 2000).
-define(LISTED_TTL_MS, 300000).
-define(FAILED_TTL_MS, 60000).

%% The ids ${Endpoint}/models lists, sent with the key of the saved openai
%% profile at that endpoint (none when no profile has one). The endpoints
%% models.dev already describes keep its curated list.
models(Home0, Endpoint0) ->
    Endpoint = string:trim(unicode:characters_to_binary(Endpoint0), trailing, "/"),
    case curated(Endpoint) of
        true -> {error, <<"models.dev lists this endpoint">>};
        false -> remembered(Endpoint, key(Home0, Endpoint))
    end.

%% A changed key (a new login) is a different entry, so it is asked at once.
remembered(Endpoint, Key) ->
    Entry = {?MODULE, models, Endpoint, erlang:phash2(Key)},
    Now = erlang:monotonic_time(millisecond),
    case persistent_term:get(Entry, none) of
        {Until, Result} when Until > Now -> Result;
        _ ->
            Result = fetch(Endpoint, Key),
            Ttl = case Result of {ok, _} -> ?LISTED_TTL_MS; _ -> ?FAILED_TTL_MS end,
            persistent_term:put(Entry, {erlang:monotonic_time(millisecond) + Ttl, Result}),
            Result
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
