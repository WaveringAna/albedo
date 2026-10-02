-module(albedo_settings).
-export([snapshot/1, provider/4, ui/3, forget/2, write_default/3, open/2, encode_dynamic/1]).
-import(albedo_settings_store, [with_lock/2, read/2, object/2, write/3,
    guarded/1, check/1, transaction/6, validate_caps/1]).

encode_dynamic(Value) -> iolist_to_binary(json:encode(Value)).

named(Config) ->
    case maps:is_key(<<"providers">>, Config) of
        true -> _ = object(<<"providers">>, Config), Config;
        false when map_size(Config) =:= 0 -> #{<<"providers">> => #{}};
        false -> (maps:remove(<<"apiKey">>, Config))#{<<"active">> => <<"default">>, <<"providers">> => #{<<"default">> => Config}}
    end.

validate_config(Config) ->
    Named = named(Config),
    maps:foreach(fun(Name, Profile) ->
        case 'albedo@daemon@configuration':validate_profile(Name, encode_dynamic(Profile)) of
            {ok, _} -> ok;
            _ -> throw({settings, <<"invalid config.json provider profile">>})
        end
    end, object(<<"providers">>, Named)),
    Named.

snapshot(Home) -> with_lock(Home, fun() -> guarded(fun() ->
    Config = validate_config(read(Home, <<"config.json">>)),
    Extensions = read(Home, <<"extensions.json">>),
    Caps = read(Home, <<"capabilities.json">>),
    Picker = read(Home, <<"picker.json">>),
    validate_caps(Caps), validate_ui(Picker),
    {ok, Summary} = albedo_credentials:summary(Home),
    {summary, Keys, Servers} = Summary,
    Profiles = maps:map(fun(Name, Profile) ->
        true = is_map(Profile),
        (maps:with([<<"extension">>, <<"baseUrl">>, <<"model">>, <<"protocol">>], Profile))#{
            <<"hasKey">> => lists:member(Name, Keys) orelse maps:get(<<"apiKey">>, Profile, <<>>) =/= <<>>}
    end, object(<<"providers">>, Config)),
    MCP = object(<<"servers">>, object(<<"mcp">>, Extensions)),
    %% Only explicit public fields are serialized, even for hand-edited files.
    PublicMCP = maps:map(fun(_, Server) -> public_mcp(Server) end, MCP),
    Secrets = maps:from_list([{Name, #{<<"bearerToken">> => Token, <<"headers">> => Headers, <<"env">> => Env}}
                             || {server, Name, Token, Headers, Env} <- Servers]),
    encode(#{<<"profiles">> => #{<<"active">> => maps:get(<<"active">>, Config, <<>>), <<"providers">> => Profiles},
             <<"mcp">> => PublicMCP,
             <<"capabilities">> => maps:with([<<"global">>, <<"sessions">>], Caps),
             <<"ui">> => public_ui(Picker),
             <<"credentials">> => #{<<"providers">> => Keys, <<"mcp">> => Secrets}})
end) end).

public_ui(Picker) ->
    maps:merge(#{<<"thinking">> => false, <<"tools">> => false,
                 <<"pinned">> => [], <<"archived">> => [], <<"opens">> => #{}},
        maps:with([<<"pinned">>, <<"archived">>, <<"opens">>, <<"thinking">>, <<"tools">>], Picker)).

public_mcp(Server) ->
    Public = maps:with([
        <<"type">>, <<"url">>, <<"command">>, <<"args">>, <<"cwd">>,
        <<"enabledTools">>, <<"disabledTools">>, <<"startupTimeoutMs">>,
        <<"callTimeoutMs">>, <<"enabled">>, <<"bearerTokenEnvVar">>, <<"headers">>, <<"env">>
    ], Server),
    lists:foldl(fun(Field, Acc) ->
        case maps:find(Field, Acc) of
            error -> Acc;
            {ok, Values} ->
                Safe = maps:map(fun(_, #{<<"env">> := Name} = Ref) when map_size(Ref) =:= 1, is_binary(Name) -> Ref end, Values),
                Acc#{Field => Safe}
        end
    end, Public, [<<"headers">>, <<"env">>]).

encode(Value) -> {ok, iolist_to_binary(json:encode(Value))}.

provider(Home, Name, ProfileJSON, Delete) ->
    transaction(Home, <<"config.json">>, {<<"providers">>, Name}, fun validate_config/1, fun(Prior) ->
        Config = validate_config(Prior),
        Profiles = object(<<"providers">>, Config),
        {Next, Active} = case Delete of
            true ->
                check(albedo_credentials:put_provider_key(Home, Name, <<>>)),
                Remaining = maps:remove(Name, Profiles),
                OldActive = maps:get(<<"active">>, Config, <<>>),
                Fallback = case lists:sort(maps:keys(Remaining)) of [] -> <<>>; [First | _] -> First end,
                {Remaining, case maps:is_key(OldActive, Remaining) of true -> OldActive; false -> Fallback end};
            false ->
                Profile = json:decode(ProfileJSON),
                case maps:find(<<"apiKey">>, Profile) of
                    {ok, Key} -> check(albedo_credentials:put_provider_key(Home, Name, Key));
                    error -> ok
                end,
                Stored = maps:remove(<<"apiKey">>, maps:merge(maps:get(Name, Profiles, #{}), Profile)),
                {Profiles#{Name => Stored}, Name}
        end,
        write(Home, <<"config.json">>, Config#{<<"providers">> => Next, <<"active">> => Active})
    end, fun() -> {ok, nil} end).

ui(Home, ID, PatchJSON) -> with_lock(Home, fun() -> guarded(fun() ->
    Prior = read(Home, <<"picker.json">>), validate_ui(Prior),
    Patch = json:decode(PatchJSON),
    Updated = case ID of
        <<>> ->
            true = lists:all(fun({K, V}) -> lists:member(K, [<<"thinking">>, <<"tools">>]) andalso is_boolean(V) end, maps:to_list(Patch)),
            maps:merge(Prior, Patch);
        _ ->
            true = lists:all(fun({K, V}) -> lists:member(K, [<<"pinned">>, <<"archived">>]) andalso is_boolean(V) end, maps:to_list(Patch)),
            maps:fold(fun(Key, Value, Acc) ->
                IDs = lists:delete(ID, maps:get(Key, Acc, [])),
                Acc#{Key => case Value of true -> IDs ++ [ID]; false -> IDs end}
            end, Prior, Patch)
    end,
    write(Home, <<"picker.json">>, Updated), encode(public_ui(Updated))
end) end).

validate_ui(Picker) ->
    lists:foreach(fun(Key) -> true = is_boolean(maps:get(Key, Picker, false)) end, [<<"thinking">>, <<"tools">>]),
    lists:foreach(fun(Key) -> true = lists:all(fun is_binary/1, maps:get(Key, Picker, [])) end, [<<"pinned">>, <<"archived">>]),
    true = lists:all(fun({K, V}) -> is_binary(K) andalso is_integer(V) andalso V >= 0 end, maps:to_list(object(<<"opens">>, Picker))).

forget(Home, ID) -> with_lock(Home, fun() -> guarded(fun() ->
    Picker = read(Home, <<"picker.json">>), validate_ui(Picker),
    Caps = read(Home, <<"capabilities.json">>), validate_caps(Caps),
    write(Home, <<"picker.json">>, Picker#{<<"pinned">> => lists:delete(ID, maps:get(<<"pinned">>, Picker, [])),
        <<"archived">> => lists:delete(ID, maps:get(<<"archived">>, Picker, [])),
        <<"opens">> => maps:remove(ID, object(<<"opens">>, Picker))}),
    write(Home, <<"capabilities.json">>, Caps#{<<"sessions">> => maps:remove(ID, object(<<"sessions">>, Caps))}),
    {ok, nil}
end) end).

write_default(Home, Provider, Model) -> with_lock(Home, fun() -> guarded(fun() ->
    Config = validate_config(read(Home, <<"config.json">>)), Profiles = object(<<"providers">>, Config),
    Selected = maps:get(Provider, Profiles),
    write(Home, <<"config.json">>, Config#{<<"active">> => Provider,
        <<"providers">> => Profiles#{Provider => Selected#{<<"model">> => Model}}}),
    {ok, nil}
end) end).

open(Home, ID) -> with_lock(Home, fun() -> guarded(fun() ->
    Picker = read(Home, <<"picker.json">>), validate_ui(Picker),
    Opens = object(<<"opens">>, Picker),
    Updated = Picker#{<<"opens">> => Opens#{ID => maps:get(ID, Opens, 0) + 1}},
    write(Home, <<"picker.json">>, Updated), encode(public_ui(Updated))
end) end).
