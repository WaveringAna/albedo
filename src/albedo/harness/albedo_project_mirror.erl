%% The disk half of albedo/harness/project_files: a remote workspace's
%% project files, mirrored under the daemon's home. A mirror is replaced
%% whole (written beside it, then renamed), so a reader never sees half of
%% one; a stamp file's mtime says how fresh it is.
-module(albedo_project_mirror).

-export([digest/1, fresh/2, replace/2]).

-include_lib("kernel/include/file.hrl").

digest(Workspace) ->
    binary:part(binary:encode_hex(crypto:hash(sha256, Workspace), lowercase), 0, 24).

fresh(Mirror, WithinMs) ->
    case file:read_file_info(filename:join(Mirror, ".albedo-mirror"), [{time, posix}]) of
        {ok, #file_info{mtime = Mtime}} ->
            erlang:system_time(second) - Mtime < max(1, WithinMs div 1000);
        {error, _} -> false
    end.

%% Files are {RelativePath, Bytes}; a path that would leave the mirror is
%% skipped.
replace(Mirror, Files) ->
    Next = <<Mirror/binary, ".next">>,
    _ = file:del_dir_r(Next),
    try
        ok = filelib:ensure_path(Next),
        [write(Next, Relative, Data) || {Relative, Data} <- Files, safe(Relative)],
        ok = file:write_file(filename:join(Next, ".albedo-mirror"), <<>>),
        _ = file:del_dir_r(Mirror),
        ok = file:rename(Next, Mirror),
        {ok, nil}
    catch _:Reason ->
        _ = file:del_dir_r(Next),
        {error, unicode:characters_to_binary(io_lib:format("mirroring project files failed: ~p", [Reason]))}
    end.

safe(Relative) ->
    Parts = filename:split(Relative),
    Relative =/= <<>> andalso filename:pathtype(Relative) =:= relative
        andalso not lists:member(<<"..">>, Parts).

write(Root, Relative, Data) ->
    Path = filename:join(Root, Relative),
    ok = filelib:ensure_dir(Path),
    ok = file:write_file(Path, Data).
