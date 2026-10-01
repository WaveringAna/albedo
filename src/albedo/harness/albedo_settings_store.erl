-module(albedo_settings_store).
-include_lib("kernel/include/file.hrl").
-export([with_lock/2, read/2, object/2, write/3, guarded/1, check/1,
         transaction/6, capability/6, mcp/5, validate_caps/1]).

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

write(Home, File, Value) ->
    Bytes = iolist_to_binary(json:encode(Value)),
    case File =:= <<"capabilities.json">> andalso byte_size(Bytes) > albedo_capabilities:max_bytes() of
        true -> throw({settings, <<"capabilities.json exceeds 1 MiB">>});
        false -> ok
    end,
    case albedo_credentials:write(filename:join(Home, File), Bytes) of
        ok -> ok;
        _ -> throw({settings, <<"could not save ", File/binary>>})
    end.

guarded(Run) ->
    try Run() catch
        throw:{settings, Error} -> {error, Error};
        _:_ -> {error, <<"invalid settings">>}
    end.

%% Rollback is deliberately scoped to the settings file and credential entry
%% affected by this mutation. Other credential entries remain untouched.
transaction(Home, File, Credential, Validate, Change, After) ->
    with_lock(Home, fun() -> guarded(fun() ->
        Prior = read(Home, File),
        Validate(Prior),
        PreviousSecret = case Credential of
            none -> error;
            {Section, Name} -> maps:find(Name, object(Section, read(Home, <<"creds.json">>)))
        end,
        try
            Change(Prior),
            case After() of
                {ok, _} = Success -> Success;
                {error, Error} -> throw({settings, Error})
            end
        catch Class:Reason ->
            Error0 = case {Class, Reason} of {throw, {settings, Message}} -> Message; _ -> <<"invalid settings">> end,
            Restorations = [guarded(fun() -> write(Home, File, Prior), {ok, nil} end),
                            guarded(fun() -> restore_secret(Home, Credential, PreviousSecret), {ok, nil} end)],
            case [Message || {error, Message} <- Restorations] of
                [] -> {error, Error0};
                Errors ->
                    Detail = iolist_to_binary(lists:join(<<"; ">>, Errors)),
                    {error, <<Error0/binary, "; restoration failed: ", Detail/binary>>}
            end
        end
    end) end).

restore_secret(_, none, _) -> ok;
restore_secret(Home, {Section, Name}, Previous) ->
    Current = read(Home, <<"creds.json">>),
    Entries = object(Section, Current),
    Next = case Previous of {ok, Value} -> Entries#{Name => Value}; error -> maps:remove(Name, Entries) end,
    write(Home, <<"creds.json">>, Current#{Section => Next}).

check({ok, _}) -> ok;
check({error, Error}) -> throw({settings, Error}).

capability(Home, Session, Kind, Name, Value, After) ->
    transaction(Home, <<"capabilities.json">>, none, fun validate_caps/1, fun(Prior) ->
        {Scope, Enabled} = Value,
        Groups = case Scope of <<"global">> -> object(Scope, Prior); <<"session">> -> object(Session, object(<<"sessions">>, Prior)) end,
        Items = object(Kind, Groups),
        Next = case Enabled of none -> maps:remove(Name, Items); {some, V} -> Items#{Name => V} end,
        Updated = Groups#{Kind => Next},
        Document = case Scope of
            <<"global">> -> Prior#{<<"global">> => Updated};
            <<"session">> -> Prior#{<<"sessions">> => (object(<<"sessions">>, Prior))#{Session => Updated}}
        end,
        write(Home, <<"capabilities.json">>, Document)
    end, After).

validate_caps(Config) ->
    check('albedo@harness@capabilities':validate(Config)).

mcp(Home, Name, ServerJSON, SecretsJSON, After) ->
    transaction(Home, <<"extensions.json">>, {<<"mcp">>, Name}, fun validate_mcp/1, fun(Prior) ->
        MCP = object(<<"mcp">>, Prior), Servers = object(<<"servers">>, MCP),
        Updated = case ServerJSON of
            none -> maps:remove(Name, Servers);
            {some, JSON} ->
                Server = json:decode(JSON),
                Servers#{Name => maps:merge(maps:get(Name, Servers, #{}), Server)}
        end,
        check(albedo_credentials:patch_mcp_settings(Home, Name, json:decode(SecretsJSON))),
        write(Home, <<"extensions.json">>, Prior#{<<"mcp">> => MCP#{<<"servers">> => Updated}})
    end, After).

validate_mcp(Value) ->
    Servers = object(<<"servers">>, object(<<"mcp">>, Value)),
    maps:foreach(fun(Name, Server) -> check(albedo_mcp:validate_settings(Name, {some, iolist_to_binary(json:encode(Server))}, <<"{}">>)) end, Servers).
