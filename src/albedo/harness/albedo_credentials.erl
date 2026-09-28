-module(albedo_credentials).
%% auth.json storage shared by OAuth provider extensions: atomic 0600 writes,
%% one cross-process lock beside the file, verified TLS for token refresh, and
%% account credential helpers.

-include_lib("kernel/include/file.hrl").

-export([read/1, read_json/1, read_json/2, write/2, write/3, with_lock/3,
         auth_path/1, values/2, oauth/2, put_values/3, expire_access/3,
         stale/2, fresh/2]).

-define(LOCK_ATTEMPTS, 1000).
-define(LOCK_STALE_MS, 30000).

auth_path(Home) ->
    filename:join(unicode:characters_to_list(Home), "auth.json").

read(Path) ->
    case read_json(Path) of
        {ok, Data} when is_map(Data) -> {ok, Data};
        {ok, _} -> {error, invalid};
        Error -> Error
    end.

read_json(Path) ->
    case file:read_file(Path) of
        {ok, Bytes} ->
            try json:decode(Bytes) of
                Term -> {ok, Term}
            catch _:_ -> {error, invalid}
            end;
        Error -> Error
    end.

read_json(Path, Default) ->
    case read_json(Path) of
        {ok, Term} -> Term;
        _ -> Default
    end.

write(Path, Data) ->
    write(Path, Data, [sync, {mode, 8#600}]).

write(Path, Data, Options) ->
    PathList = unicode:characters_to_list(Path),
    Temporary = PathList ++ ".tmp." ++ integer_to_list(erlang:unique_integer([positive])),
    _ = filelib:ensure_dir(PathList),
    Bytes = case Data of
        B when is_binary(B) -> B;
        L when is_list(L) -> iolist_to_binary(L);
        _ -> iolist_to_binary(json:encode(Data))
    end,
    Modes = [binary | [sync || lists:member(sync, Options)]],
    case file:write_file(Temporary, Bytes, Modes) of
        ok ->
            case proplists:get_value(mode, Options) of
                undefined -> ok;
                Mode -> _ = file:change_mode(Temporary, Mode)
            end,
            case file:rename(Temporary, PathList) of
                ok -> ok;
                Error -> _ = file:delete(Temporary), {error, {rename, Error}}
            end;
        Error -> {error, {write, Error}}
    end.

stale(Path, MaxAgeMs) -> not fresh(Path, MaxAgeMs).

fresh(Path, MaxAgeMs) ->
    case file:read_file_info(Path, [{time, posix}]) of
        {ok, #file_info{type = regular, mtime = Modified}} ->
            erlang:system_time(millisecond) - Modified * 1000 < MaxAgeMs;
        _ -> false
    end.

values(Data, Key) ->
    case maps:get(Key, Data, []) of
        List when is_list(List) -> [V || V <- List, is_map(V)];
        One when is_map(One) -> [One];
        _ -> []
    end.

oauth(Data, Key) ->
    [V || V <- values(Data, Key), maps:get(<<"type">>, V, <<>>) =:= <<"oauth">>].

put_values(Data, Key, []) -> maps:remove(Key, Data);
put_values(Data, Key, [One]) -> Data#{Key => One};
put_values(Data, Key, Many) -> Data#{Key => Many}.

expire_access(Path, Key, Access) ->
    with_lock(Path, fun() ->
        case read(Path) of
            {ok, #{Key := Stored} = Data} ->
                Expire = fun(#{<<"access">> := A} = V) when A =:= Access -> V#{<<"expires">> => 0};
                            (V) -> V
                         end,
                Updated = case Stored of
                    List when is_list(List) -> lists:map(Expire, List);
                    One -> Expire(One)
                end,
                (Updated =/= Stored) andalso write(Path, Data#{Key => Updated}),
                nil;
            _ -> nil
        end
    end, fun() -> nil end).

%% Runs Run() holding auth.lock beside Path, or Busy() when the lock stays taken.
with_lock(Path, Run, Busy) ->
    Lock = filename:join(filename:dirname(unicode:characters_to_list(Path)), "auth.lock"),
    case acquire(Lock, ?LOCK_ATTEMPTS) of
        {ok, Device} ->
            try Run()
            after
                file:close(Device),
                file:delete(Lock)
            end;
        {error, _} -> Busy()
    end.

acquire(_, 0) -> {error, timeout};
acquire(Path, Attempts) ->
    _ = filelib:ensure_dir(Path),
    case file:open(Path, [write, exclusive, raw]) of
        {ok, Device} ->
            _ = file:change_mode(Path, 8#600),
            _ = file:write(Device, term_to_binary({node(), self(), erlang:system_time(millisecond)})),
            _ = file:sync(Device),
            {ok, Device};
        {error, eexist} ->
            case stale_lock(Path) of
                true ->
                    _ = file:delete(Path),
                    acquire(Path, Attempts);
                false ->
                    timer:sleep(20),
                    acquire(Path, Attempts - 1)
            end;
        Error -> Error
    end.

stale_lock(Path) ->
    try
        {ok, Bytes} = file:read_file(Path),
        {OwnerNode, Owner, Created} = binary_to_term(Bytes, [safe]),
        true = is_pid(Owner) andalso is_integer(Created),
        (OwnerNode =:= node() andalso not erlang:is_process_alive(Owner)) orelse
            erlang:system_time(millisecond) - Created > ?LOCK_STALE_MS
    catch _:_ ->
        stale_mtime(Path)
    end.

stale_mtime(Path) ->
    case filelib:last_modified(Path) of
        0 -> false;
        Modified ->
            Now = calendar:datetime_to_gregorian_seconds(calendar:universal_time()),
            Now - calendar:datetime_to_gregorian_seconds(Modified) > ?LOCK_STALE_MS div 1000
    end.

