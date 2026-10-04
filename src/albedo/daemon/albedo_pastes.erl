-module(albedo_pastes).
-export([write/2, prune/2]).
-include_lib("kernel/include/file.hrl").

write(Path, Text) ->
    case filelib:ensure_dir(Path) of
        ok ->
            case file:write_file(Path, Text) of
                ok -> {ok, nil};
                {error, Reason} -> {error, <<"could not save a paste: ", (atom_to_binary(Reason))/binary>>}
            end;
        {error, Reason} -> {error, <<"could not save a paste: ", (atom_to_binary(Reason))/binary>>}
    end.

%% Every file under home/pastes/<session>/ last written Retention seconds ago
%% or earlier, then each session folder left empty.
prune(Home, Retention) ->
    Root = filename:join(Home, <<"pastes">>),
    Cutoff = erlang:system_time(second) - Retention,
    Sessions = case file:list_dir(Root) of {ok, Names} -> Names; _ -> [] end,
    lists:foldl(fun(Session, Count) ->
        Dir = filename:join(Root, Session),
        Files = case file:list_dir(Dir) of {ok, Fs} -> Fs; _ -> [] end,
        Deleted = length([File || File <- Files, expired(filename:join(Dir, File), Cutoff)]),
        _ = file:del_dir(Dir),
        Count + Deleted
    end, 0, Sessions).

expired(Path, Cutoff) ->
    case file:read_file_info(Path, [{time, posix}]) of
        {ok, #file_info{type = regular, mtime = Mtime}} when Mtime =< Cutoff ->
            file:delete(Path) =:= ok;
        _ -> false
    end.
