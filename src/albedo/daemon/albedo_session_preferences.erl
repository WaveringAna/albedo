-module(albedo_session_preferences).
-export([migrate/2]).

migrate(Home, Apply) ->
    albedo_settings_store:with_lock(Home, fun() ->
        albedo_settings_store:guarded(fun() ->
            Picker = albedo_settings_store:read(Home, <<"picker.json">>),
            Caps = albedo_settings_store:read(Home, <<"capabilities.json">>),
            {ok, Saved} = 'albedo@daemon@session_preferences':decode_import(Picker, Caps),
            case Apply(Saved) of
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
