-module(albedo_context_limits).
%% The context-limits table supplies default working windows for models whose
%% catalogued ceiling exceeds what a session should use by default: a shipped
%% default (`priv/context-limits.json`) and a local override
%% (`$ALBEDO_HOME/context-limits.json`), merged by id. Each layer file is
%% parsed once per revision (size + mtime); a malformed file keeps that layer's
%% last good entries, and the typed Gleam table is decoded only when a layer
%% revision or report changes.

-include_lib("kernel/include/file.hrl").

-export([table/0]).

-define(MAX_BYTES, 1048576).

table() ->
    try
        Resolved = [resolve(Spec) || Spec <- specs()],
        Key = [key(L) || L <- Resolved],
        case persistent_term:get({?MODULE, merged}, undefined) of
            {Key, Table} -> {ok, Table};
            _ -> rebuild(Resolved, Key)
        end
    catch
        _:_ -> {error, <<"context-limits table could not be read">>}
    end.

rebuild(Resolved, Key) ->
    Entries = 'albedo@harness@cache_ttl':merge_layers(
        [{Name, Entries} || {Name, _, _, _, _, Entries} <- Resolved]),
    Table = 'albedo@harness@context_limits':decode_table(
        Entries, [layer_report(L) || L <- Resolved]),
    persistent_term:put({?MODULE, merged}, {Key, Table}),
    {ok, Table}.

specs() ->
    Home = albedo_extension_settings:home(),
    Default = case code:priv_dir(albedo) of
        {error, _} -> undefined;
        Dir -> filename:join(Dir, <<"context-limits.json">>)
    end,
    [
        {<<"default">>, Default},
        {<<"local">>, <<Home/binary, "/context-limits.json">>}
    ].

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
            layer(Name, Path, missing, false, <<"context-limits table exceeds 1 MiB">>, previous(Path));
        {ok, _} ->
            layer(Name, Path, missing, false, <<"context-limits table is not a regular file">>, previous(Path));
        {error, enoent} ->
            Error = case Name of
                <<"default">> -> <<"no shipped context-limits table">>;
                _ -> undefined
            end,
            layer(Name, Path, missing, false, Error, []);
        {error, _} ->
            layer(Name, Path, missing, false, <<"context-limits table could not be read">>, previous(Path))
    end;
resolve({Name, undefined}) ->
    layer(Name, undefined, missing, false, <<"no shipped context-limits table">>, []).

parse(Name, Path, Revision) ->
    case albedo_credentials:read_json(Path) of
        {ok, Raw} ->
            save_parse(Name, Path, Revision,
                       'albedo@harness@context_limits':validate_layer(Raw));
        {error, invalid} ->
            save_parse(Name, Path, Revision,
                       {error, <<"context-limits table is not valid JSON">>});
        {error, _} ->
            layer(Name, Path, Revision, false,
                  <<"context-limits table could not be read">>, previous(Path))
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
