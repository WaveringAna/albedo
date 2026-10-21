-module(albedo_settings_store).
-include_lib("kernel/include/file.hrl").
-export([with_lock/2, read/2, object/2, guarded/1, check/1, validate_caps/1,
         recover/1, commit_group/2]).

%% Publication is one durable recovery record. Readers hold the same home
%% lock and finish any committed publication before reading a destination.
%% The record contains replacement bytes, so recovery does not depend on a
%% temporary file surviving a rename or process failure.
recover(Home) ->
    Journal = filename:join(Home, <<".settings-recovery">>),
    case file:read_link_info(Journal) of
        {error, enoent} -> {ok, nil};
        {ok, #file_info{type=regular, size=Size, mode=Mode}} when Size =< 12582912, Mode band 8#077 =:= 0 ->
            try
                Bytes = posix(<<"read the recovery record">>, file:read_file(Journal)),
                {settings_group, 1, Documents} = binary_to_term(Bytes, [safe]),
                validate_documents(Documents),
                publish(Home, Documents),
                posix(<<"delete the recovery record">>, file:delete(Journal)),
                sync_directory(Home),
                {ok, nil}
            catch
                %% Only steps and POSIX reasons reach the message; a
                %% recovery record can hold credentials.
                throw:{settings, Step} -> {error, <<"settings recovery could not complete: ", Step/binary>>};
                _:_ -> {error, <<"settings recovery could not complete: the record is invalid">>}
            end;
        _ -> {error, <<"settings recovery record is unsafe or unreadable">>}
    end.

commit_group(Home, Documents0) ->
    Documents = maps:map(fun(_, Value) -> iolist_to_binary(json:encode(Value)) end, Documents0),
    validate_documents(Documents),
    Journal = filename:join(Home, <<".settings-recovery">>),
    %% Destination replacement is forbidden until this record and its name
    %% are durable. Once committed, failures are completed by recover/1.
    check(recover(Home)),
    check_write(albedo_credentials:write(Journal, term_to_binary({settings_group, 1, Documents}))),
    sync_directory(Home),
    check(recover(Home)),
    ok.

validate_documents(Documents) when is_map(Documents), map_size(Documents) > 0, map_size(Documents) =< 6 ->
    maps:foreach(fun(File, Bytes) ->
        true = lists:member(File, [<<"config.json">>, <<"creds.json">>, <<"extensions.json">>, <<"capabilities.json">>, <<"picker.json">>, <<"models.json">>, <<"oauth-logins.json">>, <<"settings-revisions.json">>]),
        Limit = case File of
            <<"capabilities.json">> -> albedo_capabilities:max_bytes();
            _ -> 2097152
        end,
        true = is_binary(Bytes) andalso byte_size(Bytes) =< Limit,
        true = is_map(json:decode(Bytes))
    end, Documents);
validate_documents(_) -> throw({settings, <<"invalid settings replacement">>}).

publish(Home, Documents) ->
    lists:foreach(fun({File, Bytes}) ->
        posix(<<"write ", File/binary>>, albedo_credentials:write(filename:join(Home, File), Bytes))
    end, lists:sort(maps:to_list(Documents))),
    sync_directory(Home).

check_write(ok) -> ok;
check_write(_) -> throw({settings, <<"could not publish settings">>}).

sync_directory(Home) ->
    Device = posix(<<"open the settings directory">>, file:open(Home, [read, raw, directory])),
    try posix(<<"sync the settings directory">>, file:sync(Device)) after file:close(Device) end.

%% A file operation's result, or a settings failure naming the step and reason.
posix(_, ok) -> ok;
posix(_, {ok, Value}) -> Value;
posix(Step, {error, Reason}) when is_atom(Reason) ->
    throw({settings, <<Step/binary, " failed (", (atom_to_binary(Reason))/binary, ")">>});
posix(Step, _) -> throw({settings, <<Step/binary, " failed">>}).

%% Every persisted settings and credential mutation shares the home lock.
with_lock(Home, Run) ->
    albedo_settings_lock:with_lock(Home, Run,
        fun() -> {error, <<"settings store is busy">>} end).

read(Home, <<"capabilities.json">>) ->
    case albedo_capabilities:read(Home) of
        {ok, Bytes} ->
            try json:decode(Bytes) of
                Value when is_map(Value) -> Value;
                _ -> throw({settings, <<"capabilities.json is not a readable JSON object">>})
            catch _:_ -> throw({settings, <<"capabilities.json is not a readable JSON object">>}) end;
        {error, Reason} -> throw({settings, Reason})
    end;
read(Home, File) ->
    Path = filename:join(Home, File),
    case file:read_file_info(Path) of
        {error, enoent} -> #{};
        {ok, #file_info{type = regular, size = Size}} when Size =< 2097152 ->
            case albedo_credentials:read(Path) of
                {ok, Value} -> Value;
                _ -> throw({settings, <<File/binary, " is not a readable JSON object">>})
            end;
        _ -> throw({settings, <<File/binary, " is not a readable settings file">>})
    end.

object(Key, Map) ->
    case maps:get(Key, Map, #{}) of
        Value when is_map(Value) -> Value;
        _ -> throw({settings, <<"invalid settings section">>})
    end.

guarded(Run) ->
    try Run() catch
        throw:{settings, Error} -> {error, Error};
        _:_ -> {error, <<"invalid settings">>}
    end.

check({ok, _}) -> ok;
check({error, Error}) -> throw({settings, Error}).

validate_caps(Config) ->
    check('albedo@harness@capabilities':validate(Config)).
