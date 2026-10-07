-module(albedo_extension_settings).
-include_lib("kernel/include/file.hrl").
-export([home/0, read/1, set_enabled/3, set_enabled_many/2, set_entry/4, remove_entry/3]).

-define(MAX_BYTES, 1048576).

home() ->
    unicode:characters_to_binary(case os:getenv("ALBEDO_HOME") of
        false ->
            case os:getenv("HOME") of
                false -> ".albedo";
                Home -> filename:join(Home, ".albedo")
            end;
        Home -> Home
    end).

read(Home) ->
    albedo_settings_lock:with_lock(Home, fun() -> read_locked(Home) end,
        fun() -> {error, <<"settings store is busy">>} end).

read_locked(Home) ->
    Path = filename:join(Home, <<"extensions.json">>),
    case file:read_file_info(Path) of
        {error, enoent} -> {ok, <<"{}">>};
        {ok, #file_info{type = regular, size = Size}} when Size =< ?MAX_BYTES ->
            case file:read_file(Path) of
                {ok, Bytes} when byte_size(Bytes) =< ?MAX_BYTES -> {ok, Bytes};
                {ok, _} -> {error, <<"extensions.json exceeds 1 MiB">>};
                _ -> {error, <<"could not read extensions.json">>}
            end;
        {ok, #file_info{type = regular}} -> {error, <<"extensions.json exceeds 1 MiB">>};
        _ -> {error, <<"extensions.json is not a readable regular file">>}
    end.

%% Records a global extension default in the `enabled` section.
set_enabled(Home, Name, Enabled) ->
    set_entry(Home, <<"enabled">>, Name, Enabled).

%% A strategy selection changes all siblings in one locked rename.
set_enabled_many(Home, Choices) ->
    albedo_settings_lock:with_lock(Home, fun() ->
        try
            {ok, Bytes} = read_locked(Home),
            Sections = json:decode(Bytes),
            Enabled = maps:get(<<"enabled">>, Sections, #{}),
            Updated = Sections#{<<"enabled">> => maps:merge(Enabled, maps:from_list(Choices))},
            case albedo_credentials:write(filename:join(Home, <<"extensions.json">>), Updated) of
                ok -> {ok, nil};
                _ -> {error, <<"could not save extensions.json">>}
            end
        catch _:_ -> {error, <<"extensions.json is not a valid settings object">>}
        end
    end, fun() -> {error, <<"settings store is busy">>} end).

remove_entry(Home, Section, Key) ->
    set_entry(Home, Section, Key, null).

%% Sets one key of one section, keeping every other section and key as
%% written; `null` removes the key. The rename is the commit, so readers never
%% see a partly written file.
set_entry(Home, Section, Key, Value) ->
    albedo_settings_lock:with_lock(Home,
        fun() -> set_entry_locked(Home, Section, Key, Value) end,
        fun() -> {error, <<"settings store is busy">>} end).

set_entry_locked(Home, Section, Key, Value) ->
    try
        {ok, Bytes} = read(Home),
        Sections = case Bytes of <<>> -> #{}; _ -> json:decode(Bytes) end,
        true = is_map(Sections),
        Entries = case maps:get(Section, Sections, #{}) of Map when is_map(Map) -> Map; _ -> erlang:error(invalid_section) end,
        Updated = case Value of
            null -> Sections#{Section => maps:remove(Key, Entries)};
            _ -> Sections#{Section => Entries#{Key => Value}}
        end,
        case albedo_credentials:write(filename:join(Home, <<"extensions.json">>), Updated) of
            ok -> {ok, nil};
            _ -> {error, <<"could not save extensions.json">>}
        end
    catch
        _:_ -> {error, <<"extensions.json is not a valid settings object">>}
    end.
