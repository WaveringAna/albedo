-module(albedo_session_preferences).
-export([migrate/2]).

migrate(Home, Apply) ->
    albedo_settings_store:with_lock(Home, fun() ->
        albedo_settings_store:guarded(fun() ->
            Picker = albedo_settings_store:read(Home, <<"picker.json">>),
            Caps = albedo_settings_store:read(Home, <<"capabilities.json">>),
            Pins = identifiers(maps:get(<<"pinned">>, Picker, [])),
            Archived = identifiers(maps:get(<<"archived">>, Picker, [])),
            Opens = maps:to_list(albedo_settings_store:object(<<"opens">>, Picker)),
            lists:foreach(fun({ID, Count}) -> identifier(ID), true = is_integer(Count) andalso Count >= 0 end, Opens),
            Choices = choices(albedo_settings_store:object(<<"sessions">>, Caps)),
            case Apply({preferences_import, Pins, Archived, Opens, Choices}) of
                {ok, nil} ->
                    Changed = maps:is_key(<<"pinned">>, Picker) orelse maps:is_key(<<"archived">>, Picker)
                        orelse maps:is_key(<<"opens">>, Picker) orelse maps:is_key(<<"sessions">>, Caps),
                    case Changed of
                        true -> albedo_settings_store:commit_group(Home, #{
                            <<"picker.json">> => maps:without([<<"pinned">>, <<"archived">>, <<"opens">>], Picker),
                            <<"capabilities.json">> => maps:remove(<<"sessions">>, Caps)});
                        false -> ok
                    end,
                    {ok, nil};
                Error -> Error
            end
        end)
    end).

identifiers(IDs) when is_list(IDs) ->
    lists:foreach(fun identifier/1, IDs),
    true = length(IDs) =:= length(lists:usort(IDs)),
    IDs.
identifier(ID) -> true = is_binary(ID) andalso byte_size(ID) > 0 andalso byte_size(ID) =< 512.

choices(Sessions) ->
    maps:fold(fun(Session, Scope, Acc) ->
        identifier(Session), true = is_map(Scope),
        lists:foldl(fun(Kind, Choices) ->
            Group = albedo_settings_store:object(Kind, Scope),
            maps:fold(fun(Key, Enabled, Rows) ->
                identifier(Key), true = is_boolean(Enabled),
                [{Session, Kind, Key, Enabled} | Rows]
            end, Choices, Group)
        end, Acc, [<<"skills">>, <<"instructions">>, <<"mcp">>])
    end, [], Sessions).
