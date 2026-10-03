-module(albedo_credentials).
%% creds.json, the one file holding every secret albedo keeps, and the storage
%% helpers around it: atomic 0600 writes and account credential helpers.
%% Mutations use the shared per-home settings lock. Sections:
%% "accounts" holds OAuth accounts and keys by provider store key, one object
%% or a list; "providers" holds a profile's apiKey by profile name; "mcp" holds
%% an MCP server's bearerToken, headers and env by server name.

-include_lib("kernel/include/file.hrl").

-export([read/1, read_json/1, read_json/2, write/2, write/3,
         creds_path/1, accounts/1, put_accounts/2, provider_keys/1,
         mcp/1, patch_mcp_settings/3, config/1,
         migrate/2, migrated/0,
         values/2, bound_values/3, oauth/2, put_values/3, expire_access/3, stale/2, fresh/2]).

creds_path(Home) ->
    filename:join(unicode:characters_to_list(Home), "creds.json").

%% The accounts by store key. A creds.json not yet written reads as enoent.
accounts(Path) -> section(Path, <<"accounts">>).

%% Replaces the accounts; the caller holds the lock.
put_accounts(Path, Accounts) -> put_section(Path, <<"accounts">>, Accounts).

%% Every profile's saved apiKey, by profile name.
provider_keys(Home) ->
    case section(creds_path(Home), <<"providers">>) of
        {ok, Profiles} -> keys(Profiles);
        _ -> #{}
    end.

keys(Profiles) ->
    maps:from_list([{Name, Key} || {Name, #{<<"apiKey">> := <<_, _/binary>> = Key}}
                                       <- maps:to_list(Profiles)]).

%% Every MCP server's secrets, by server name.
mcp(Home) ->
    case section(creds_path(Home), <<"mcp">>) of
        {ok, Servers} -> {ok, maps:filter(fun(_, Secret) -> is_map(Secret) end, Servers)};
        {error, enoent} -> {ok, #{}};
        Error -> Error
    end.

%% Settings transactions capture and restore the affected entry themselves.
patch_mcp_settings(Home, Name, Patch) ->
    update_section(Home, <<"mcp">>, fun(Servers) ->
        with_secret(Servers, Name, patched(maps:get(Name, Servers, #{}), Patch))
    end).

with_secret(Servers, Name, Secret) when map_size(Secret) =:= 0 -> maps:remove(Name, Servers);
with_secret(Servers, Name, Secret) -> Servers#{Name => Secret}.

patched(Secret, Patch) ->
    lists:foldl(fun({Field, Change}, Acc) ->
        case {Change, maps:get(Field, Acc, #{})} of
            {Gone, _} when Gone =:= null; Gone =:= <<>> -> maps:remove(Field, Acc);
            {Value, _} when Field =:= <<"bearerToken">>, is_binary(Value) -> Acc#{Field => Value};
            {Changes, Current} when is_map(Changes), is_map(Current) ->
                Next = maps:fold(fun(Key, null, M) -> maps:remove(Key, M);
                                    (Key, Value, M) when is_binary(Value) -> M#{Key => Value};
                                    (_, _, M) -> M
                                 end, Current, Changes),
                case map_size(Next) of
                    0 -> maps:remove(Field, Acc);
                    _ -> Acc#{Field => Next}
                end;
            _ -> Acc
        end
    end, Secret, [{F, maps:get(F, Patch)} || F <- [<<"bearerToken">>, <<"headers">>, <<"env">>],
                                            maps:is_key(F, Patch)]).

%% config.json with each profile's saved apiKey filled in. A key still written
%% in config.json is a hand edit newer than the saved one, so it wins until the
%% next boot moves it.
config(Home) ->
    albedo_settings_lock:with_lock(Home, fun() -> config_locked(Home) end,
        fun() -> {error, busy} end).

config_locked(Home) ->
    case read(config_path(Home)) of
        {ok, #{<<"providers">> := Profiles} = Config} when is_map(Profiles) ->
            Keys = provider_keys(Home),
            {ok, Config#{<<"providers">> := maps:map(fun(Name, Profile) ->
                with_key(Profile, maps:get(Name, Keys, <<>>))
            end, Profiles)}};
        {ok, Flat} -> {ok, with_key(Flat, maps:get(<<"default">>, provider_keys(Home), <<>>))};
        Error -> Error
    end.

with_key(#{<<"apiKey">> := <<_, _/binary>>} = Profile, _) -> Profile;
with_key(Profile, <<>>) -> Profile;
with_key(Profile, Key) when is_map(Profile) -> Profile#{<<"apiKey">> => Key};
with_key(Profile, _) -> Profile.

config_path(Home) ->
    filename:join(unicode:characters_to_list(Home), "config.json").

section(Path, Name) ->
    case read(Path) of
        {ok, Document} ->
            case maps:get(Name, Document, #{}) of
                Section when is_map(Section) -> {ok, Section};
                _ -> {error, invalid}
            end;
        Error -> Error
    end.

%% Rewrites one section, keeping the others as they stand; an empty section
%% is dropped. An unreadable file is left alone rather than replaced.
put_section(Path, Name, Section) ->
    Current = case read(Path) of
        {ok, Document} -> {ok, Document};
        {error, enoent} -> {ok, #{}};
        Error -> Error
    end,
    case Current of
        {ok, Found} when map_size(Section) =:= 0 -> write(Path, maps:remove(Name, Found));
        {ok, Found} -> write(Path, Found#{Name => Section});
        {error, _} -> {error, invalid}
    end.

update_section(Home, Name, Change) ->
    Path = creds_path(Home),
    albedo_settings_lock:with_lock(filename:dirname(Path), fun() ->
        Written = case section(Path, Name) of
            {ok, Section} -> put_section(Path, Name, Change(Section));
            {error, enoent} -> put_section(Path, Name, Change(#{}));
            {error, _} -> {error, invalid}
        end,
        case Written of
            ok -> {ok, nil};
            {error, invalid} -> {error, <<"creds.json is unreadable; repair it first">>};
            {error, _} -> {error, <<"could not write creds.json">>}
        end
    end, fun() -> {error, <<"credential store is busy">>} end).

%% Moves every secret still kept elsewhere into creds.json: auth.json's
%% accounts, mcp-credentials.json's servers, and each config.json profile's
%% apiKey. creds.json is written before anything is removed, and the old files
%% go to backups/ with Stamp in their names, so an interrupted run loses
%% nothing and the next boot finishes it. Returns the files it moved from.
migrate(Home, Stamp0) ->
    Stamp = unicode:characters_to_list(Stamp0),
    Path = creds_path(Home),
    albedo_settings_lock:with_lock(filename:dirname(Path), fun() ->
        case read(Path) of
            {error, enoent} -> migrate(Home, Stamp, #{});
            {ok, Document} -> migrate(Home, Stamp, Document);
            {error, _} -> {error, <<"creds.json is unreadable; repair it first">>}
        end
    end, fun() -> {error, <<"credential store is busy">>} end).

migrate(Home, Stamp, Document) ->
    Dir = unicode:characters_to_list(Home),
    Legacy = [{File, Section, Found}
              || {Name, Section} <- [{"auth.json", <<"accounts">>},
                                     {"mcp-credentials.json", <<"mcp">>}],
                 File <- [filename:join(Dir, Name)],
                 {ok, Found} <- [read(File)]],
    Config = case read(config_path(Home)) of
        {ok, Found} -> Found;
        _ -> #{}
    end,
    Keys = config_keys(Config),
    case Legacy =:= [] andalso map_size(Keys) =:= 0 of
        true -> {ok, []};
        false ->
            Sections = [{Section, legacy_section(Section, Found)} || {_, Section, Found} <- Legacy]
                ++ [{<<"providers">>, maps:map(fun(_, Key) -> #{<<"apiKey">> => Key} end, Keys)}],
            case write(creds_path(Home), lists:foldl(fun merge_section/2, Document, Sections)) of
                ok -> retire(Home, Stamp, [File || {File, _, _} <- Legacy], Config, Keys);
                {error, _} -> {error, <<"could not write creds.json">>}
            end
    end.

legacy_section(<<"mcp">>, Found) -> maps:get(<<"servers">>, Found, #{});
legacy_section(_, Found) -> Found.

%% What the old file held wins over creds.json: it can only be newer.
merge_section({Name, Found}, Document) when map_size(Found) > 0 ->
    Current = case maps:get(Name, Document, #{}) of
        Section when is_map(Section) -> Section;
        _ -> #{}
    end,
    Document#{Name => maps:merge(Current, Found)};
merge_section(_, Document) -> Document.

%% Startup owns the home and holds its mutation lock while moving secrets.
retire(Home, Stamp, Files, Config, Keys) ->
    _ = filelib:ensure_path(filename:join(unicode:characters_to_list(Home), "backups")),
    Backup = fun(File) -> backup(Home, filename:basename(File), Stamp) end,
    Moved = [unicode:characters_to_binary(filename:basename(File))
             || File <- Files, move(File, Backup(File))],
    Stripped = map_size(Keys) > 0 andalso strip_keys(Home, Config, Backup("config.json")),
    Retired = Moved ++ [<<"config.json">> || Stripped],
    persistent_term:put({?MODULE, migrated}, Retired),
    {ok, Retired}.

%% Each client can observe this daemon's migration. Dismissal is a saved UI
%% preference and does not destroy the native observation for other clients.
migrated() -> persistent_term:get({?MODULE, migrated}, []).

move(File, To) ->
    case file:rename(File, To) of
        ok -> seal(To);
        {error, _} -> false
    end.

%% Clears every mode bit on a backup: even its owner must chmod it before
%% reading, so tools and agents running as the user never read the secrets by
%% accident. Deleting it needs only the folder, so rm -f still works.
seal(Backup) ->
    _ = file:change_mode(Backup, 0),
    true.

%% Where a migration keeps File's old copy: backups/<File>-before-creds-<Stamp>.
backup(Home, File, Stamp) ->
    filename:join([unicode:characters_to_list(Home), "backups", File ++ "-before-creds-" ++ Stamp]).

strip_keys(Home, Config, Backup) ->
    case file:copy(config_path(Home), Backup) of
        {ok, _} -> seal(Backup) andalso write(config_path(Home), without_keys(Config)) =:= ok;
        {error, _} -> false
    end.

config_keys(#{<<"providers">> := Profiles}) when is_map(Profiles) -> keys(Profiles);
config_keys(#{<<"apiKey">> := <<_, _/binary>> = Key}) -> #{<<"default">> => Key};
config_keys(_) -> #{}.

without_keys(#{<<"providers">> := Profiles} = Config) when is_map(Profiles) ->
    Config#{<<"providers">> := maps:map(fun(_, Profile) when is_map(Profile) ->
                                                 maps:remove(<<"apiKey">>, Profile);
                                             (_, Profile) -> Profile
                                         end, Profiles)};
without_keys(Config) -> maps:remove(<<"apiKey">>, Config).

read(Path) ->
    case read_json(Path) of
        {ok, Data} when is_map(Data) -> {ok, Data};
        {ok, _} -> {error, invalid};
        Error -> Error
    end.

read_json(Path) ->
    case lists:member(unicode:characters_to_binary(filename:basename(Path)),
            [<<"config.json">>, <<"creds.json">>, <<"extensions.json">>, <<"capabilities.json">>, <<"picker.json">>]) of
        true -> albedo_settings_lock:with_lock(filename:dirname(Path), fun() -> read_json_locked(Path) end,
            fun() -> {error, busy} end);
        false -> read_json_locked(Path)
    end.

read_json_locked(Path) ->
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
    case file:open(Temporary, [write, binary, exclusive]) of
        {ok, Device} ->
            try
                Sealed = case proplists:get_value(mode, Options) of
                    undefined -> ok;
                    Mode -> file:change_mode(Temporary, Mode)
                end,
                case Sealed of
                    ok ->
                        case file:write(Device, Bytes) of
                            ok ->
                                Synced = case lists:member(sync, Options) of true -> file:sync(Device); false -> ok end,
                                case Synced of
                                    ok -> file:rename(Temporary, PathList);
                                    Error -> Error
                                end;
                            Error -> Error
                        end;
                    Error -> Error
                end
            after file:close(Device), file:delete(Temporary) end;
        Error -> Error
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
    albedo_settings_lock:with_lock(filename:dirname(Path), fun() ->
        case accounts(Path) of
            {ok, #{Key := Stored} = Data} ->
                Expire = fun(#{<<"access">> := A} = V) when A =:= Access -> V#{<<"expires">> => 0};
                            (V) -> V
                         end,
                Updated = case Stored of
                    List when is_list(List) -> lists:map(Expire, List);
                    One -> Expire(One)
                end,
                (Updated =/= Stored) andalso put_accounts(Path, Data#{Key => Updated}),
                nil;
            _ -> nil
        end
    end, fun() -> nil end).


%% A profile's explicit public account identity confines this transport to that
%% account. No matching credential is an error rather than a silent fallback.
bound_values(_, <<>>, Values) -> {ok, Values};
bound_values(Home, Profile, Values) ->
    albedo_settings_lock:with_lock(Home, fun() ->
        case config_locked(Home) of
            {ok, Config} ->
                Saved = case maps:find(<<"providers">>, Config) of
                    {ok, Profiles} -> maps:get(Profile, Profiles, #{});
                    error when Profile =:= <<"default">> -> Config;
                    error -> #{}
                end,
                case maps:get(<<"accountId">>, Saved, null) of
                    null -> {ok, Values};
                    Id when is_binary(Id), byte_size(Id) > 0 ->
                        case [V || V <- Values, maps:get(<<"_albedo_account_id">>, V, null) =:= Id] of
                            [] -> {error, <<"Profile's selected account is unavailable">>};
                            Selected -> {ok, Selected}
                        end;
                    _ -> {error, <<"Profile's selected account is invalid">>}
                end;
            _ -> {error, <<"Provider profile is unavailable">>}
        end
    end, fun() -> {error, <<"Credential store is busy">>} end).
