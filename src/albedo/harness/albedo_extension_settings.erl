-module(albedo_extension_settings).
-include_lib("kernel/include/file.hrl").
-export([home/0, read/1]).

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
