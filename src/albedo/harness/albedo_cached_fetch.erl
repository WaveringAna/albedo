-module(albedo_cached_fetch).
%% The one bounded fetch every url-backed cache shares: the models.dev
%% catalog and the cache-ttl table. https-or-loopback urls only, a background
%% refresh when the cache is stale (one registered process per cache, a
%% duplicate spawn killed), an explicit reload that reports failures, and the
%% rename-commit write a failed fetch never reaches.
%%
%% `What` labels every error so each caller keeps its wording. `Accept`
%% validates — and may trim — the body, enforcing its own size cap, before
%% anything is committed. `After` runs once the cache file has been replaced,
%% for the caller's own derived state (the models catalog drops its parse
%% index).

-export([safe_url/1, refresh/7, reload/5, commit/4, isolated/2]).

-define(FETCH_TIMEOUT_MS, 30000).

refresh(Cache0, Url0, MaxAgeMs, RefreshName, What, Accept, After) ->
    Cache = text(Cache0),
    Url = unicode:characters_to_binary(Url0),
    case albedo_credentials:stale(Cache, MaxAgeMs) andalso safe_url(Url) of
        false -> nil;
        true ->
            Pid = spawn(fun() -> fetch_commit(Cache, Url, What, Accept, After) end),
            try register(RefreshName, Pid) of
                true -> nil
            catch
                _:_ -> exit(Pid, kill), nil
            end
    end.

reload(Cache0, Url0, What, Accept, After) ->
    Cache = text(Cache0),
    Url = unicode:characters_to_binary(Url0),
    try
        case safe_url(Url) of
            true -> isolated(What, fun() -> fetch_commit(Cache, Url, What, Accept, After) end);
            false -> {error, <<What/binary, " URL must use https or loopback http">>}
        end
    catch
        _:_ -> {error, <<What/binary, " URL is invalid">>}
    end.

%% A partly written cache must never be readable, so the rename is the commit.
%% Exported for the models catalog's in-place retrim, which rewrites a cached
%% file the same way a fetch would.
commit(Cache0, Bytes, What, After) ->
    Cache = text(Cache0),
    case albedo_credentials:write(Cache, Bytes) of
        ok -> After(Cache), {ok, nil};
        {error, {rename, _}} -> {error, <<What/binary, " cache could not be replaced">>};
        _ -> {error, <<What/binary, " cache could not be written">>}
    end.

%% https anywhere; plain http only on loopback, which keeps tests local.
safe_url(Url) ->
    Parsed = uri_string:parse(Url),
    Scheme = maps:get(scheme, Parsed, undefined),
    Host = string:lowercase(maps:get(host, Parsed, <<>>)),
    Scheme =:= <<"https">> orelse
        (Scheme =:= <<"http">> andalso
         lists:member(Host, [<<"localhost">>, <<"127.0.0.1">>, <<"::1">>])).

fetch_commit(Cache, Url, What, Accept, After) ->
    case fetch(Url, What, Accept) of
        {ok, Bytes} -> commit(Cache, Bytes, What, After);
        Error -> Error
    end.

fetch(Url, What, Accept) ->
    Headers = [{"user-agent", "albedo"}, {"accept", "application/json"}],
    case albedo_http:get(Url, Headers, ?FETCH_TIMEOUT_MS, 10000) of
        {ok, {200, _, Body}} -> Accept(Body);
        {ok, {Status, _, _}} ->
            {error, iolist_to_binary([What, io_lib:format(" returned HTTP ~B", [Status])])};
        {error, _} -> {error, <<What/binary, " request failed">>}
    end.

%% Runs Fun in a fresh process so a large decode's garbage dies with it
%% instead of growing the caller's heap for the rest of its life. Fun's result
%% crosses back as an exit reason, so it must be small. Exported because the
%% models catalog's parse path isolates its decode the same way.
isolated(What, Fun) ->
    {Pid, Ref} = spawn_monitor(fun() -> exit({done, Fun()}) end),
    receive
        {'DOWN', Ref, process, Pid, {done, Result}} -> Result;
        {'DOWN', Ref, process, Pid, _} -> {error, <<What/binary, " could not be read">>}
    end.

text(Value) -> unicode:characters_to_list(Value).
