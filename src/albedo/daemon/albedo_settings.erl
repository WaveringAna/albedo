-module(albedo_settings).
-export([write_default/3]).
-import(albedo_settings_store, [with_lock/2, read/2, object/2, commit_group/2, guarded/1]).

write_default(Home, Provider, Model) -> with_lock(Home, fun() -> guarded(fun() ->
    Config = case 'albedo@daemon@configuration':validate_saved_config(read(Home, <<"config.json">>)) of
        {ok, Value} -> Value;
        {error, Reason} -> throw({settings, Reason})
    end,
    Profiles = object(<<"providers">>, Config),
    Selected = maps:get(Provider, Profiles),
    commit_group(Home, #{<<"config.json">> => Config#{<<"active">> => Provider,
        <<"providers">> => Profiles#{Provider => Selected#{<<"model">> => Model}}}}),
    {ok, nil}
end) end).
