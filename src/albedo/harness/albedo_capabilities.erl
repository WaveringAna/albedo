-module(albedo_capabilities).
-include_lib("kernel/include/file.hrl").
-export([read/1, max_bytes/0]).

max_bytes() -> 1048576.

read(Home) ->
    albedo_settings_lock:with_lock(Home, fun() -> read_locked(Home) end,
        fun() -> {error, <<"settings store is busy">>} end).

read_locked(Home) ->
    Path = filename:join(Home, <<"capabilities.json">>),
    case file:read_file_info(Path) of
        {error, enoent} -> {ok, <<"{}">>};
        {ok, #file_info{type = regular}} ->
            case file:open(Path, [read, binary, raw]) of
                {ok, File} ->
                    try
                        Limit = max_bytes(),
                        case file:read(File, Limit + 1) of
                            eof -> {ok, <<>>};
                            {ok, Bytes} when byte_size(Bytes) =< Limit -> {ok, Bytes};
                            _ -> {error, <<"could not read capabilities.json">>}
                        end
                    after file:close(File) end;
                _ -> {error, <<"could not read capabilities.json">>}
            end;
        _ -> {error, <<"could not read capabilities.json">>}
    end.
