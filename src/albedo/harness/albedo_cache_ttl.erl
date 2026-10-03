-module(albedo_cache_ttl).
%% The prompt-cache TTL table supplies the initial cache-warmth estimate:
%% a shipped default, an optional remote copy, and a local override, merged by
%% id. Each layer file is parsed once per revision (size + mtime), like
%% albedo_models; a malformed file keeps that layer's last good entries, and
%% the typed Gleam table is decoded only when a layer revision or report changes.

-include_lib("kernel/include/file.hrl").

-export([table/0, refresh/3, reload/2]).

-define(MAX_BYTES, 1048576).
-define(REFRESH_PROCESS, albedo_cache_ttl_refresh).

%% Every error this cache reports is labelled with its own name.
-define(WHAT, <<"cache-ttl">>).

%% Cache the typed Gleam table, including the current layer reports.
table() ->
    try
        Resolved = [resolve(Spec) || Spec <- specs()],
        Key = [key(L) || L <- Resolved],
        case persistent_term:get({?MODULE, merged}, undefined) of
            {Key, Table} -> {ok, Table};
            _ -> rebuild(Resolved, Key)
        end
    catch
        _:_ -> {error, <<"cache-ttl table could not be read">>}
    end.

rebuild(Resolved, Key) ->
    Entries = 'albedo@harness@cache_ttl':merge_layers(
        [{Name, Entries} || {Name, _, _, _, _, Entries} <- Resolved]),
    Table = 'albedo@harness@cache_ttl':decode_table(
        Entries, [layer_report(L) || L <- Resolved]),
    persistent_term:put({?MODULE, merged}, {Key, Table}),
    {ok, Table}.

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
                {Revision, {ok, Entries}, _} ->
                    layer(Name, Path, Revision, true, undefined, Entries);
                {Revision, {error, Reason}, Previous} ->
                    layer(Name, Path, Revision, false, Reason, Previous);
                _ -> parse(Name, Path, Revision)
            end;
        {ok, #file_info{type = regular}} ->
            layer(Name, Path, missing, false, <<"cache-ttl table exceeds 1 MiB">>, previous(Path));
        {ok, _} ->
            layer(Name, Path, missing, false, <<"cache-ttl table is not a regular file">>, previous(Path));
        {error, enoent} ->
            Error = case Name of
                <<"default">> -> <<"no shipped cache-ttl table">>;
                _ -> undefined
            end,
            layer(Name, Path, missing, false, Error, []);
        {error, _} ->
            layer(Name, Path, missing, false, <<"cache-ttl table could not be read">>, previous(Path))
    end;
resolve({Name, undefined}) ->
    layer(Name, undefined, missing, false, <<"no shipped cache-ttl table">>, []).

%% Stable parse/shape failures remember the attempted revision. IO failures
%% retain the last good entries but retry on the next read, even at that revision.
parse(Name, Path, Revision) ->
    case albedo_credentials:read_json(Path) of
        {ok, Raw} ->
            save_parse(Name, Path, Revision,
                       'albedo@harness@cache_ttl':validate_layer(Raw));
        {error, invalid} ->
            save_parse(Name, Path, Revision,
                       {error, <<"cache-ttl table is not valid JSON">>});
        {error, _} ->
            layer(Name, Path, Revision, false,
                  <<"cache-ttl table could not be read">>, previous(Path))
    end.

save_parse(Name, Path, Revision, {ok, Entries}) ->
    persistent_term:put({?MODULE, Path}, {Revision, {ok, Entries}, Entries}),
    layer(Name, Path, Revision, true, undefined, Entries);
save_parse(Name, Path, Revision, {error, Reason}) ->
    Previous = previous(Path),
    persistent_term:put({?MODULE, Path}, {Revision, {error, Reason}, Previous}),
    layer(Name, Path, Revision, false, Reason, Previous).

previous(Path) ->
    case persistent_term:get({?MODULE, Path}, undefined) of
        {_, _, Previous} -> Previous;
        _ -> []
    end.

layer(Name, Path, Revision, Loaded, Error, Entries) ->
    {Name, Path, Revision, Loaded, Error, Entries}.

key({Name, Path, Revision, Loaded, Error, _}) ->
    {Name, Path, Revision, Loaded, Error}.

layer_report({Name, Path, _, Loaded, Error, _}) ->
    Optional = case Error of undefined -> none; _ -> {some, Error} end,
    {layer, Name, to_bin(Path), Loaded, Optional}.

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
    case json_bytes(Body) of
        {ok, Raw} ->
            case 'albedo@harness@cache_ttl':validate_layer(Raw) of
                {ok, _} -> {ok, Body};
                {error, Reason} -> {error, Reason}
            end;
        {error, invalid} -> {error, <<"cache-ttl table is not valid JSON">>}
    end;
accept(_) ->
    {error, <<"cache-ttl response is too large">>}.

%% A replacement may have the same size and timestamp; invalidate both caches.
after_write(Cache) ->
    _ = persistent_term:erase({?MODULE, to_bin(Cache)}),
    _ = persistent_term:erase({?MODULE, merged}),
    nil.

json_bytes(Body) ->
    try {ok, json:decode(Body)}
    catch _:_ -> {error, invalid}
    end.
