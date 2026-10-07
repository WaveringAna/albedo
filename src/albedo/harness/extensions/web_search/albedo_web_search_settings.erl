-module(albedo_web_search_settings).
-export([save/2]).

%% Replace visible positions while retaining hidden providers' positions and
%% exclusions. Read and publish both fields under the same settings lock.
save(Home, Selected) ->
    albedo_settings_store:with_lock(Home, fun() ->
        albedo_settings_store:guarded(fun() ->
            Documents = albedo_settings_store:read(Home, <<"extensions.json">>),
            Search = albedo_settings_store:object(<<"web-search">>, Documents),
            Prior = maps:get(<<"order">>, Search, []),
            Names = [Name || {Name, _} <- Selected],
            Order = replace_visible(Prior, Names, Names),
            Off = [Name || Name <- maps:get(<<"off">>, Search, []), not lists:member(Name, Names)]
                ++ [Name || {Name, false} <- Selected],
            Updated = Documents#{<<"web-search">> => Search#{<<"order">> => Order, <<"off">> => Off}},
            case albedo_credentials:write(filename:join(Home, <<"extensions.json">>), Updated) of
                ok -> {ok, nil};
                _ -> {error, <<"could not save web search preferences">>}
            end
        end)
    end).

replace_visible([], Remaining, _) -> Remaining;
replace_visible([Name | Rest], Remaining, Visible) ->
    case lists:member(Name, Visible) of
        false -> [Name | replace_visible(Rest, Remaining, Visible)];
        true -> case Remaining of
            [Next | Tail] -> [Next | replace_visible(Rest, Tail, Visible)];
            [] -> replace_visible(Rest, [], Visible)
        end
    end.
