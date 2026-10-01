-module(albedo_state_expiry).
-export([reclaim/4]).
-include_lib("kernel/include/file.hrl").

reclaim(Home, Expired, Protected, Known) ->
    Dir = filename:join(Home, <<"kernels">>),
    Now = erlang:system_time(second),
    Names = case file:list_dir(Dir) of {ok, Ns} -> Ns; _ -> [] end,
    lists:foldl(fun(Name, Acc) -> reclaim_one(Dir, Name, Expired, Protected, Known, Now, Acc) end,
                {0, 0}, Names).

reclaim_one(Dir, Name0, Expired, Protected, Known, Now, {Count, Bytes}) ->
    Name = unicode:characters_to_binary(Name0),
    case filename:extension(Name) of
        <<".state">> ->
            Id = filename:rootname(Name, <<".state">>),
            Path = filename:join(Dir, Name),
            case file:read_file_info(Path, [{time, posix}]) of
                {ok, #file_info{type = regular, size = Size, mtime = Mtime}} ->
                    OldOrphan = not lists:member(Id, Expired) andalso
                        not lists:member(Id, Known) andalso Now - Mtime >= 86400,
                    Target = (lists:member(Id, Expired) andalso not lists:member(Id, Protected)) orelse OldOrphan,
                    case Target andalso file:delete(Path) of
                        ok -> {Count + 1, Bytes + Size};
                        _ -> {Count, Bytes}
                    end;
                _ -> {Count, Bytes}
            end;
        _ -> {Count, Bytes}
    end.
