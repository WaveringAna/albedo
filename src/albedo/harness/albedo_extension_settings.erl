-module(albedo_extension_settings).
-include_lib("kernel/include/file.hrl").
-export([home/0, read/1, set_enabled/3, set_entry/4, remove_entry/3]).

-define(MAX_BYTES, 1048576).

home() ->
    case os:getenv("ALBEDO_HOME") of
        false ->
            case os:getenv("HOME") of
                false -> <<".albedo">>;
                Home -> unicode:characters_to_binary(filename:join(Home, ".albedo"))
            end;
        Home -> unicode:characters_to_binary(Home)
    end.

read(Home) ->
    Path = filename:join(Home, <<"extensions.json">>),
    case file:read_file_info(Path) of
        {error, enoent} -> {ok, <<"{}">>};
        {ok, #file_info{type = regular, size = Size}} when Size =< ?MAX_BYTES ->
            bounded_read(Path);
        {ok, #file_info{type = regular}} -> {error, <<"extensions.json exceeds 1 MiB">>};
        _ -> {error, <<"extensions.json is not a readable regular file">>}
    end.

bounded_read(Path) ->
    case file:open(Path, [read, raw, binary]) of
        {ok, File} ->
            Result = file:read(File, ?MAX_BYTES + 1),
            _ = file:close(File),
            case Result of
                {ok, Bytes} when byte_size(Bytes) =< ?MAX_BYTES -> {ok, Bytes};
                {ok, _} -> {error, <<"extensions.json exceeds 1 MiB">>};
                eof -> {ok, <<>>};
                _ -> {error, <<"could not read extensions.json">>}
            end;
        _ -> {error, <<"could not read extensions.json">>}
    end.

%% Records a global extension default in the `enabled` section.
set_enabled(Home, Name, Enabled) ->
    set_entry(Home, <<"enabled">>, Name, Enabled).

remove_entry(Home, Section, Key) ->
    set_entry(Home, Section, Key, null).

%% Sets one key of one section, keeping every other section and key as
%% written; `null` removes the key. The rename is the commit, so readers never
%% see a partly written file.
set_entry(Home, Section, Key, Value) ->
    try
        {ok, Bytes} = read(Home),
        Sections = case Bytes of
            <<>> -> #{};
            _ -> json:decode(Bytes)
        end,
        true = is_map(Sections),
        Entries = case maps:get(Section, Sections, #{}) of
            Map when is_map(Map) -> Map;
            _ -> #{}
        end,
        Updated = case Value of
            null -> Sections#{Section => maps:remove(Key, Entries)};
            _ -> Sections#{Section => Entries#{Key => Value}}
        end,
        Path = filename:join(Home, <<"extensions.json">>),
        Temporary = <<Path/binary, ".tmp.", (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
        ok = filelib:ensure_dir(Path),
        ok = file:write_file(Temporary, json:encode(Updated), [binary, sync]),
        _ = file:change_mode(Temporary, 8#600),
        case file:rename(Temporary, Path) of
            ok -> {ok, nil};
            _ -> _ = file:delete(Temporary), {error, <<"could not save extensions.json">>}
        end
    catch
        _:_ -> {error, <<"extensions.json is not a valid settings object">>}
    end.
