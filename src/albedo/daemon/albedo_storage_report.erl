%% Filesystem accounting only. Never open SQLite or follow storage symlinks.
-module(albedo_storage_report).
-export([inspect/2]).
-include_lib("kernel/include/file.hrl").

inspect(Home, Sessions) ->
    try
        directory(Home),
        Database = filename:join(Home, <<"albedo.sqlite">>),
        DbBytes = regular_size(Database),
        Wal = regular_size(<<Database/binary, "-wal">>) + regular_size(<<Database/binary, "-shm">>),
        %% Native mtimes have second precision. Strict comparison conservatively
        %% delays eligibility by less than a second instead of marking a newer file old.
        Cutoff = erlang:system_time(second) - 30 * 24 * 60 * 60,
        Known = sets:from_list(Sessions),
        {Kernels, OldKernels, _, _} = storage_files(filename:join(Home, <<"kernels">>), kernel, Known, Cutoff),
        {Backups, OldBackups, RecentBytes, RecentCount} = storage_files(filename:join(Home, <<"backups">>), backup, Known, Cutoff),
        Excluded = [<<"kernels">>, <<"backups">>, <<"albedo.sqlite">>, <<"albedo.sqlite-wal">>, <<"albedo.sqlite-shm">>],
        Other = lists:sum([size_if_regular(filename:join(Home, Name)) || Name <- names(Home), not lists:member(Name, Excluded)]),
        {ok, {filesystem, OldKernels, OldBackups, DbBytes, Wal, Kernels, Backups, Other, RecentBytes, RecentCount}}
    catch
        throw:{storage_error, Reason} -> {error, Reason}
    end.

directory(Path) ->
    case info(Path) of
        missing -> missing;
        #file_info{type = directory} -> ok;
        _ -> fail(Path, <<"expected a directory for storage">>)
    end.

regular_size(Path) ->
    case info(Path) of
        missing -> 0;
        #file_info{type = regular, size = Size} -> Size;
        _ -> fail(Path, <<"expected a regular file for storage">>)
    end.

size_if_regular(Path) ->
    case entry_info(Path) of
        #file_info{type = regular, size = Size} -> Size;
        _ -> 0
    end.

info(Path) ->
    case file:read_link_info(Path, [{time, posix}]) of
        {ok, Info} -> Info;
        {error, enoent} -> missing;
        {error, Reason} -> fail(Path, atom_to_binary(Reason))
    end.

entry_info(Path) ->
    case info(Path) of
        missing -> fail(Path, <<"entry disappeared during storage inspection">>);
        Info -> Info
    end.

has_suffix(Name, Suffix) ->
    byte_size(Name) >= byte_size(Suffix) andalso
        binary:part(Name, byte_size(Name) - byte_size(Suffix), byte_size(Suffix)) =:= Suffix.

names(Path) ->
    case file:list_dir(Path) of
        {ok, Names} -> lists:sort([unicode:characters_to_binary(Name) || Name <- Names]);
        {error, Reason} -> fail(Path, atom_to_binary(Reason))
    end.

storage_files(Dir, Kind, Known, Cutoff) ->
    case directory(Dir) of
        missing -> {0, [], 0, 0};
        ok ->
            {Total, Old, Recent, Count} = lists:foldl(fun(Name, {Bytes, Candidates, RecentBytes, RecentCount}) ->
                Path = filename:join(Dir, Name),
                case entry_info(Path) of
                    #file_info{type = regular, size = Size, mtime = Mtime} ->
                        Eligible = eligible(Kind, Name, Known),
                        case {Eligible, Mtime < Cutoff, Kind} of
                            {true, true, _} -> {Bytes + Size, [{file_bytes, Path, Size} | Candidates], RecentBytes, RecentCount};
                            {true, false, backup} -> {Bytes + Size, Candidates, RecentBytes + Size, RecentCount + 1};
                            _ -> {Bytes + Size, Candidates, RecentBytes, RecentCount}
                        end;
                    _ -> {Bytes, Candidates, RecentBytes, RecentCount}
                end
            end, {0, [], 0, 0}, names(Dir)),
            {Total, lists:reverse(Old), Recent, Count}
    end.

eligible(kernel, Name, Known) ->
    case has_suffix(Name, <<".state">>) of
        true -> not sets:is_element(binary:part(Name, 0, byte_size(Name) - 6), Known);
        false -> false
    end;
eligible(backup, Name, _) ->
    string:prefix(Name, <<"albedo-before-image-store-">>) =/= nomatch andalso has_suffix(Name, <<".sqlite">>).

fail(Path, Reason) -> throw({storage_error, <<Reason/binary, ": ", Path/binary>>}).
