-module(albedo_configuration).
-export([validate_profile/2]).

validate_profile(Name, JSON) ->
    try
        true = re:run(Name, <<"^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$">>, [{capture, none}]) =:= match,
        Profile = json:decode(JSON), true = is_map(Profile),
        Model = string:trim(maps:get(<<"model">>, Profile)),
        true = is_binary(Model) andalso byte_size(Model) > 0 andalso byte_size(Model) =< 512,
        true = re:run(Model, <<"[\\x00-\\x1f\\x7f]">>, [{capture, none}]) =:= nomatch,
        Protocol = maps:get(<<"protocol">>, Profile),
        true = Protocol =:= <<"responses">> orelse Protocol =:= <<"chat_completions">>,
        Extension = maps:get(<<"extension">>, Profile, <<"openai">>),
        true = is_binary(Extension) andalso byte_size(Extension) > 0,
        URL = string:trim(maps:get(<<"baseUrl">>, Profile, <<>>)),
        true = is_binary(URL),
        case URL of
            <<>> -> true = Extension =/= <<"openai">>;
            _ ->
                Parsed = uri_string:parse(URL),
                true = lists:member(maps:get(scheme, Parsed), [<<"http">>, <<"https">>]),
                true = maps:get(host, Parsed, <<>>) =/= <<>>,
                true = lists:all(fun(K) -> not maps:is_key(K, Parsed) end, [userinfo, query, fragment])
        end,
        Key = maps:get(<<"apiKey">>, Profile, <<>>), true = is_binary(Key),
        true = re:run(Key, <<"[\\s\\x00-\\x1f\\x7f]">>, [unicode, {capture, none}]) =:= nomatch,
        Public = maps:with([<<"extension">>, <<"baseUrl">>, <<"model">>, <<"protocol">>, <<"apiKey">>], Profile),
        {ok, iolist_to_binary(json:encode(Public#{<<"extension">> => Extension, <<"model">> => Model,
            <<"baseUrl">> => string:trim(URL, trailing, "/")}))}
    catch _:_ -> {error, <<"invalid provider name, model, protocol, endpoint, or API key">>} end.
