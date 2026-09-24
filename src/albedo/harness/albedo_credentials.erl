-module(albedo_credentials).
%% auth.json storage shared by OAuth provider extensions: atomic 0600 writes,
%% one cross-process lock beside the file, and verified TLS for token refresh.

-export([read/1, write/2, with_lock/3, tls_options/1]).

-define(LOCK_ATTEMPTS, 1000).
-define(LOCK_STALE_MS, 30000).

read(Path) ->
    case file:read_file(Path) of
        {ok, Bytes} ->
            try json:decode(Bytes) of
                Data when is_map(Data) -> {ok, Data};
                _ -> {error, invalid}
            catch _:_ -> {error, invalid} end;
        Error -> Error
    end.

write(Path, Data) ->
    Temporary = Path ++ ".tmp." ++ integer_to_list(erlang:unique_integer([positive])),
    _ = filelib:ensure_dir(Path),
    case file:write_file(Temporary, iolist_to_binary(json:encode(Data)), [binary, sync]) of
        ok ->
            _ = file:change_mode(Temporary, 8#600),
            case file:rename(Temporary, Path) of
                ok -> ok;
                Error -> _ = file:delete(Temporary), Error
            end;
        Error -> Error
    end.

%% Runs Run() holding auth.lock beside Path, or Busy() when the lock stays taken.
with_lock(Path, Run, Busy) ->
    Lock = filename:join(filename:dirname(Path), "auth.lock"),
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
    Now = erlang:system_time(millisecond),
    case file:read_file(Path) of
        {ok, Bytes} ->
            try binary_to_term(Bytes, [safe]) of
                {OwnerNode, Owner, Created} when is_pid(Owner), is_integer(Created) ->
                    (OwnerNode =:= node() andalso not erlang:is_process_alive(Owner)) orelse
                    Now - Created > ?LOCK_STALE_MS;
                _ -> stale_mtime(Path)
            catch _:_ -> stale_mtime(Path) end;
        _ -> stale_mtime(Path)
    end.

stale_mtime(Path) ->
    case filelib:last_modified(Path) of
        0 -> false;
        Modified ->
            Now = calendar:datetime_to_gregorian_seconds(calendar:universal_time()),
            Now - calendar:datetime_to_gregorian_seconds(Modified) > ?LOCK_STALE_MS div 1000
    end.

tls_options(Host) ->
    [{verify, verify_peer}, {cacerts, public_key:cacerts_get()}, {depth, 5},
     {server_name_indication, Host},
     {customize_hostname_check, [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}].
