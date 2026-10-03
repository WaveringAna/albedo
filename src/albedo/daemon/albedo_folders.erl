%% The filesystem half of albedo/daemon/folders: directory entries and stats,
%% preserving symlink identity while following directory targets for `cd`.
-module(albedo_folders).

-export([home/0, entries/1, file_size/1]).

-include_lib("kernel/include/file.hrl").

home() ->
    case os:getenv("HOME") of
        false -> <<"/">>;
        Home -> unicode:characters_to_binary(Home)
    end.

%% Every entry of Dir as the gleam Entry record, none when it cannot be
%% read. A name that is not valid UTF-8 cannot be shown or passed back, so
%% it is left out.
entries(Dir) ->
    case file:list_dir(Dir) of
        {ok, Names} -> [entry(Dir, Name) || Name <- Names, is_list(Name)];
        {error, _} -> []
    end.

entry(Dir, Name0) ->
    Name = unicode:characters_to_binary(Name0),
    Path = filename:join(Dir, Name),
    Symlink = case file:read_link_info(Path) of
        {ok, #file_info{type = symlink}} -> true;
        _ -> false
    end,
    case file:read_file_info(Path, [{time, posix}]) of
        {ok, #file_info{type = Type, mtime = Mtime}} ->
            {entry, Name, Type =:= directory, Mtime, Symlink};
        {error, _} ->
            {entry, Name, false, 0, Symlink}
    end.

file_size(Path) ->
    case file:read_file_info(Path) of
        {ok, #file_info{type = regular, size = Size}} -> {ok, Size};
        _ -> {error, nil}
    end.
