-module(albedo_settings).
-export([named/1, normalize_profile/2, write_default/3]).
-import(albedo_settings_store, [with_lock/2, read/2, object/2, commit_group/2, guarded/1]).

normalize_profile(Name, Profile) ->
    case 'albedo@daemon@configuration':validate_profile(Name, Profile) of
        {ok, {saved_profile, Extension, Endpoint, Model, Protocol, Key}} ->
            Fields = #{<<"extension">> => Extension, <<"baseUrl">> => Endpoint,
                <<"model">> => Model,
                <<"protocol">> => 'albedo@openai_api@types':protocol_name(Protocol)},
            {ok, case Key of none -> Fields; {some, Value} -> Fields#{<<"apiKey">> => Value} end};
        Error -> Error
    end.

named(Config) ->
    case maps:is_key(<<"providers">>, Config) of
        true -> _ = object(<<"providers">>, Config), Config;
        false when map_size(Config) =:= 0 -> #{<<"providers">> => #{}};
        false -> (maps:remove(<<"apiKey">>, Config))#{<<"active">> => <<"default">>, <<"providers">> => #{<<"default">> => Config}}
    end.

validate_config(Config) ->
    Named = named(Config),
    maps:foreach(fun(Name, Profile) ->
        case normalize_profile(Name, Profile) of
            {ok, _} -> ok;
            _ -> throw({settings, <<"invalid config.json provider profile">>})
        end
    end, object(<<"providers">>, Named)),
    Named.

write_default(Home, Provider, Model) -> with_lock(Home, fun() -> guarded(fun() ->
    Config = validate_config(read(Home, <<"config.json">>)), Profiles = object(<<"providers">>, Config),
    Selected = maps:get(Provider, Profiles),
    commit_group(Home, #{<<"config.json">> => Config#{<<"active">> => Provider,
        <<"providers">> => Profiles#{Provider => Selected#{<<"model">> => Model}}}}),
    {ok, nil}
end) end).
