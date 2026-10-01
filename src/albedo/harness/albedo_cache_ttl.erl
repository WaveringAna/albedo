-module(albedo_cache_ttl).
%% The prompt-cache TTL table behind /cache-ttl and phase 2's warmth prior:
%% a shipped default, an optional remote copy, and a local override, merged by
%% id. Each layer file is parsed once per revision (size + mtime), like
%% albedo_models; a malformed file keeps that layer's last good entries, and
%% the merged table is re-encoded only when a layer revision changes.

-include_lib("kernel/include/file.hrl").

-export([merged/0, refresh/3, reload/2]).

-define(MAX_BYTES, 1048576).
-define(REFRESH_PROCESS, albedo_cache_ttl_refresh).

%% Every error this cache reports is labelled with its own name.
-define(WHAT, <<"cache-ttl">>).

%% The merged table as JSON: every entry tagged with the layer it came from,
%% plus the layer report the route serves. Always well-formed, even when no
%% layer loaded: an empty table is a valid answer.
merged() ->
    try
        Resolved = [resolve(Spec) || Spec <- specs()],
        Key = [key(L) || L <- Resolved],
        case persistent_term:get({?MODULE, merged}, undefined) of
            {Key, Json} -> {ok, Json};
            _ -> rebuild(Resolved, Key)
        end
    catch
        _:_ -> {error, <<"cache-ttl table could not be read">>}
    end.

rebuild(Resolved, Key) ->
    Entries = 'albedo@harness@cache_ttl':merge_layers(
        [{Name, Entries} || {Name, _, _, _, _, Entries} <- Resolved]),
    Json = iolist_to_binary(json:encode(#{
        <<"entries">> => Entries,
        <<"layers">> => [layer_json(L) || L <- Resolved]
    })),
    persistent_term:put({?MODULE, merged}, {Key, Json}),
    {ok, Json}.

%% default, then remote, then local: later layers replace same-id entries in
%% place, and their new ids go before every earlier-layer entry, so a local
%% override can shadow a general default while specific defaults keep their
%% place ahead of general ones.
specs() ->
    Home = albedo_extension_settings:home(),
    Default = case code:priv_dir(albedo) of
        {error, _} -> undefined;
        Dir -> filename:join(Dir, <<"cache-ttl.json">>)
    end,
    [
        {<<"default">>, Default},
        {<<"remote">>, <<Home/binary, "/cache-ttl-remote.json">>},
        {<<"local">>, <<Home/binary, "/cache-ttl.json">>}
    ].

%% {Name, Path, Revision, Loaded, Error, Entries}: the entries of the last
%% good parse survive a malformed newer file.
resolve({Name, Path}) when Path =/= undefined ->
    case file:read_file_info(Path, [{time, posix}]) of
        {ok, #file_info{type = regular, size = Size, mtime = Mtime}} when Size =< ?MAX_BYTES ->
            Revision = {Size, Mtime},
            case persistent_term:get({?MODULE, Path}, undefined) of
                {Revision, {ok, Entries}} ->
                    layer(Name, Path, Revision, true, undefined, Entries);
                _ -> parse(Name, Path, Revision)
            end;
        {ok, #file_info{type = regular}} ->
            layer(Name, Path, missing, false, <<"cache-ttl table exceeds 1 MiB">>, []);
        {ok, _} ->
            layer(Name, Path, missing, false, <<"cache-ttl table is not a regular file">>, []);
        {error, enoent} ->
            Error = case Name of
                <<"default">> -> <<"no shipped cache-ttl table">>;
                _ -> undefined
            end,
            layer(Name, Path, missing, false, Error, []);
        {error, _} ->
            layer(Name, Path, missing, false, <<"cache-ttl table could not be read">>, [])
    end;
resolve({Name, undefined}) ->
    layer(Name, undefined, missing, false, <<"no shipped cache-ttl table">>, []).

parse(Name, Path, Revision) ->
    case table(albedo_credentials:read_json(Path)) of
        {ok, Entries} ->
            persistent_term:put({?MODULE, Path}, {Revision, {ok, Entries}}),
            layer(Name, Path, Revision, true, undefined, Entries);
        {error, Reason} ->
            % The last good parse stays cached under its own revision; this
            % file is only re-read once its revision changes again.
            Entries = case persistent_term:get({?MODULE, Path}, undefined) of
                {_, {ok, Previous}} -> Previous;
                _ -> []
            end,
            layer(Name, Path, Revision, false, Reason, Entries)
    end.

%% A table is an object with an entries list; each entry must be a map with a
%% binary id to be mergeable. Anything else is dropped, never fatal.
table({ok, #{<<"entries">> := Entries}}) when is_list(Entries) ->
    Usable = [E || E <- Entries, is_map(E), is_binary(maps:get(<<"id">>, E, undefined))],
    Dropped = length(Entries) - length(Usable),
    (Dropped > 0) andalso log(Dropped),
    {ok, Usable};
table({ok, _}) -> {error, <<"cache-ttl table is not an object with an entries list">>};
table({error, invalid}) -> {error, <<"cache-ttl table is not valid JSON">>};
table({error, _}) -> {error, <<"cache-ttl table could not be read">>}.

log(Dropped) ->
    _ = try logger:warning("albedo_cache_ttl: ~B entries without an id were skipped",
                           [Dropped])
         catch _:_ -> ok end,
    true.

layer(Name, Path, Revision, Loaded, Error, Entries) ->
    {Name, Path, Revision, Loaded, Error, Entries}.

key({Name, Path, Revision, _, _, _}) -> {Name, Path, Revision}.

layer_json({Name, Path, _, Loaded, Error, _}) ->
    Base = #{<<"name">> => Name, <<"path">> => to_bin(Path), <<"loaded">> => Loaded},
    case Error of
        undefined -> Base;
        _ -> Base#{<<"error">> => Error}
    end.

to_bin(undefined) -> <<>>;
to_bin(Path) -> unicode:characters_to_binary(Path).

%% The remote copy is fetched and cached the way the models catalog is: a
%% background refresh when stale, an explicit reload that reports failures,
%% and a failed fetch leaving the previous cache untouched. The machinery is
%% albedo_cached_fetch; only the table check and the merged-cache reset are
%% this table's own.
refresh(Cache, Url, MaxAgeMs) ->
    albedo_cached_fetch:refresh(Cache, Url, MaxAgeMs, ?REFRESH_PROCESS,
                                ?WHAT, fun accept/1, fun after_write/1).

reload(Cache, Url) ->
    albedo_cached_fetch:reload(Cache, Url, ?WHAT, fun accept/1, fun after_write/1).

%% A fetched table is committed as it came: no fields are trimmed, it is only
%% checked to be a table, at this cache's own size cap.
accept(Body) when byte_size(Body) =< ?MAX_BYTES ->
    case table(json_bytes(Body)) of
        {ok, _} -> {ok, Body};
        {error, Reason} -> {error, Reason}
    end;
accept(_) ->
    {error, <<"cache-ttl response is too large">>}.

%% A replaced layer file changes the revision the merged cache is keyed by,
%% but the reset makes the next read see the new copy immediately.
after_write(_Cache) ->
    _ = persistent_term:erase({?MODULE, merged}),
    nil.

json_bytes(Body) ->
    try {ok, json:decode(Body)}
    catch _:_ -> {error, invalid}
    end.
