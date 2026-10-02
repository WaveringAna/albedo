-module(albedo_file_fingerprint).

-include_lib("kernel/include/file.hrl").

-export([identity/1, fingerprint/2]).

identity(Path) ->
    case file:read_file_info(Path) of
        {ok, Info} -> file_identity(Info);
        Error -> Error
    end.

fingerprint(Path, MaximumBytes) ->
    case file:read_file_info(Path) of
        {ok, #file_info{type = regular} = Info} ->
            {file_identity(Info), hash_contents(Path, MaximumBytes)};
        Other -> Other
    end.

%% Reading a catalog must not change its revision through access time.
file_identity(#file_info{type = Type, size = Size, mtime = Modified,
                         ctime = Changed, inode = Inode, mode = Mode}) ->
    {Type, Size, Modified, Changed, Inode, Mode}.

hash_contents(Path, MaximumBytes) ->
    case file:open(Path, [read, binary, raw]) of
        {ok, Io} ->
            try
                Contents = file:pread(Io, 0, MaximumBytes + 1),
                crypto:hash(sha256, term_to_binary(Contents))
            after
                file:close(Io)
            end;
        Error -> Error
    end.
