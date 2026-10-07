%% OS and standard-IO bindings for the standalone storage helpers.
-module(albedo_storage_cli).
-include_lib("kernel/include/file.hrl").
-export([arguments/0, identity/1, bytes/1, copy/2, remove/1, database_uri/2,
         read_line/0, watch_owner/0, halt/1]).

arguments() -> [unicode:characters_to_binary(Arg) || Arg <- init:get_plain_arguments()].

identity(Path) ->
    case file:read_link_info(Path, [{time, posix}]) of
        {ok, #file_info{type = regular, major_device = Device, inode = Inode,
                       size = Size, mtime = Modified}} ->
            {ok, {some, {Device, Inode, Size, Modified}}};
        {ok, _} -> {error, <<"expected a regular file: ", Path/binary>>};
        {error, enoent} -> {ok, none};
        {error, Reason} -> failure(Path, Reason)
    end.

bytes({_, _, Size, _}) -> Size.

copy(Source, Destination) ->
    case file:copy(Source, Destination) of
        {ok, _} -> {ok, nil};
        {error, Reason} -> failure(Source, Reason)
    end.

remove(Path) ->
    case file:delete(Path) of
        ok -> {ok, nil};
        {error, Reason} -> failure(Path, Reason)
    end.

database_uri(Path, Mode) ->
    Absolute = filename:absname(Path),
    Encoded = uri_string:quote(Absolute, "/"),
    <<"file:", Encoded/binary, "?mode=", Mode/binary>>.

read_line() ->
    case io:get_line("") of
        eof -> {ok, none};
        {error, Reason} -> {error, atom_to_binary(Reason)};
        Line -> {ok, {some, unicode:characters_to_binary(Line)}}
    end.

%% Only started after both protocol lines have been consumed. Killing the VM
%% stops SQLite work as well as BEAM processes and releases the home lock.
watch_owner() -> spawn(fun drain_owner/0), nil.

drain_owner() ->
    case io:get_chars("", 4096) of
        eof -> erlang:halt(1);
        {error, _} -> erlang:halt(1);
        _ -> drain_owner()
    end.

halt(Code) -> erlang:halt(Code).

failure(Path, Reason) ->
    {error, <<(atom_to_binary(Reason))/binary, ": ", Path/binary>>}.
