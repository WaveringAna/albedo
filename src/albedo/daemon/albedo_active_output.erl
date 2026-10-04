-module(albedo_active_output).
-export([create/2, append/4, lease/3, release/2, read/6, maintenance/1, revoke/2]).
-include_lib("kernel/include/file.hrl").

-define(DISK, 1073741824).
-define(LEASE, 900000).

create(Home, Session) -> guarded(fun() -> locked(Home, fun() ->
    case file:make_dir(directory(Home)) of
        ok -> ok = file:change_mode(directory(Home), 8#700);
        {error, eexist} -> true = filelib:is_dir(directory(Home));
        Error0 -> error(Error0)
    end,
    {ok, Files} = file:list_dir(directory(Home)),
    Count = length([Name || Name <- Files, filename:extension(Name) =:= ".meta"]),
    case Count < 4096 of
        true -> ok;
        false ->
            cleanup(Home), {ok, AfterCleanup} = file:list_dir(directory(Home)),
            true = length([Name || Name <- AfterCleanup, filename:extension(Name) =:= ".meta"]) < 4096
    end,
    ID = binary:encode_hex(crypto:strong_rand_bytes(16), lowercase),
    save(meta_path(Home, ID), #{session => Session, owner => self(), instance => instance(), expires => 0}),
    case file:write_file(data_path(Home, ID), <<>>, [exclusive]) of
        ok -> ok = file:change_mode(data_path(Home, ID), 8#600);
        Error -> file:delete(meta_path(Home, ID)), error(Error)
    end,
    {ok, ID}
end) end).

%% Only append bytes beyond the already stored immutable prefix. A capture can
%% flush its pending buffer without returning replacement actor state.
append(_, _, _, <<>>) -> {ok, nil};
append(Home, ID, Offset, Text) -> guarded(fun() -> locked(Home, fun() ->
    true = valid_id(ID),
    {ok, Info} = file:read_file_info(data_path(Home, ID)),
    Existing = Info#file_info.size, true = Existing >= Offset,
    Skip = erlang:max(0, Existing - Offset),
    case Skip >= byte_size(Text) of
        true -> {ok, nil};
        false ->
            Suffix = binary:part(Text, Skip, byte_size(Text) - Skip),
            Current = usage(Home),
            Usage = case Current + byte_size(Suffix) =< ?DISK of
                true -> Current;
                false -> cleanup(Home), usage(Home)
            end,
            Reserved = Usage + byte_size(Suffix), true = Reserved =< ?DISK,
            save(usage_path(Home), Reserved),
            case file:write_file(data_path(Home, ID), Suffix, [append, binary]) of
                ok -> {ok, nil};
                Error ->
                    {ok, After} = file:read_file_info(data_path(Home, ID)),
                    save(usage_path(Home), Usage + After#file_info.size - Existing),
                    error(Error)
            end
    end
end) end).

lease(Home, Session, ID) -> guarded(fun() -> locked(Home, fun() ->
    Meta = metadata(Home, ID), true = maps:get(session, Meta) =:= Session,
    save(meta_path(Home, ID), Meta#{expires => now_ms() + ?LEASE}),
    {ok, nil}
end) end).

release(Home, ID) ->
    try locked(Home, fun() ->
        Meta = metadata(Home, ID),
        case maps:get(expires, Meta) > now_ms() of
            true -> save(meta_path(Home, ID), Meta#{owner => none});
            false -> delete_content(Home, ID)
        end
    end) catch _:_ -> ok end, nil.

read(Home, Session, ID, Offset, Limit, Cutoff) ->
    try
        true = valid_id(ID), true = Offset >= 0 andalso Offset =< Cutoff,
        true = Limit > 0 andalso Limit =< 262144,
        File = locked(Home, fun() ->
            Meta = read_metadata(Home, ID),
            case maps:get(session, Meta) =:= Session andalso maps:get(expires, Meta) > now_ms() of
                true -> ok; false -> throw(active_output_expired)
            end,
            {ok, Info} = file:read_file_info(data_path(Home, ID)), true = Cutoff =< Info#file_info.size,
            {ok, Handle} = file:open(data_path(Home, ID), [read, binary, raw]),
            Handle
        end),
            try
                Amount = erlang:min(Limit + 4, Cutoff - Offset),
                Bytes = case file:pread(File, Offset, Amount) of eof -> <<>>; {ok, Data} -> Data end,
                {ok, Result} = albedo_http_api:content_slice(Bytes, 0, erlang:min(Limit, byte_size(Bytes))),
                %% content_slice's native tuple is returned inside Gleam Result.
                {Text, Next, _} = Result,
                {ok, {Text, Offset + Next, Offset + Next =:= Cutoff}}
            after file:close(File) end
    catch throw:active_output_expired -> {error, <<"active_output_expired">>};
        _:_ -> {error, <<"active output content is unavailable">>} end.

maintenance(Home) ->
    try
        case persistent_term:get({?MODULE, recovered, Home}, false) of
            false -> locked(Home, fun() ->
                cleanup(Home),
                case filelib:is_dir(directory(Home)) of
                    true -> save(usage_path(Home), disk_bytes(Home));
                    false -> ok
                end,
                persistent_term:put({?MODULE, recovered, Home}, true)
            end);
            true ->
                %% Discovery is outside the writer mutex. Every candidate is
                %% rechecked while deleting, so a renewed lease wins the race.
                case file:list_dir(directory(Home)) of
                    {ok, Files} -> lists:foreach(fun(Name) ->
                        try case removable(Home, Name) of
                            true -> locked(Home, fun() -> cleanup_file(Home, Name) end);
                            false -> ok
                        end catch _:_ -> ok end
                    end, Files);
                    _ -> ok
                end
        end
    catch _:_ -> ok end, nil.

cleanup(Home) ->
    case file:list_dir(directory(Home)) of
        {ok, Files} -> lists:foreach(fun(Name) ->
            try cleanup_file(Home, Name) catch _:_ -> ok end
        end, Files);
        _ -> ok
    end.

removable(Home, Name) ->
    case filename:extension(Name) of
        ".meta" ->
            ID = list_to_binary(filename:rootname(Name)), Meta = metadata(Home, ID),
            Owner = maps:get(owner, Meta),
            Alive = maps:get(instance, Meta, none) =:= instance()
                andalso is_pid(Owner) andalso is_process_alive(Owner),
            not Alive andalso maps:get(expires, Meta) =< now_ms();
        ".data" ->
            ID = list_to_binary(filename:rootname(Name)), true = valid_id(ID),
            not filelib:is_file(meta_path(Home, ID));
        ".tmp" -> true;
        _ -> false
    end.

cleanup_file(Home, Name) ->
    case removable(Home, Name) of
        false -> ok;
        true -> case filename:extension(Name) of
            ".meta" -> delete_content(Home, list_to_binary(filename:rootname(Name)));
            ".data" -> delete_content(Home, list_to_binary(filename:rootname(Name)));
            ".tmp" -> file:delete(filename:join(directory(Home), Name))
        end
    end.

revoke(Home, Session) ->
    try locked(Home, fun() ->
        {ok, Files} = file:list_dir(directory(Home)),
        lists:foreach(fun(Name) -> case filename:extension(Name) of
            ".meta" ->
                ID = list_to_binary(filename:rootname(Name)),
                case maps:get(session, metadata(Home, ID)) =:= Session of
                    true -> delete_content(Home, ID);
                    false -> ok
                end;
            _ -> ok
        end end, Files)
    end) catch _:_ -> ok end, nil.

read_metadata(Home, ID) ->
    case file:read_file(meta_path(Home, ID)) of
        {ok, Bytes} -> binary_to_term(Bytes, [safe]);
        {error, enoent} -> throw(active_output_expired);
        _ -> error(content_unavailable)
    end.

usage(Home) -> case file:read_file(usage_path(Home)) of
    {ok, Bytes} -> binary_to_term(Bytes, [safe]); {error, enoent} -> disk_bytes(Home) end.
metadata(Home, ID) -> true = valid_id(ID), {ok, Bytes} = file:read_file(meta_path(Home, ID)), binary_to_term(Bytes, [safe]).
save(Path, Value) ->
    Temporary = <<Path/binary, ".tmp">>,
    ok = file:write_file(Temporary, <<>>), ok = file:change_mode(Temporary, 8#600),
    ok = file:write_file(Temporary, term_to_binary(Value)), ok = file:rename(Temporary, Path).
locked(Home, Run) -> global:trans({{?MODULE, Home}, self()}, Run).
directory(Home) -> filename:join(Home, <<"active-output">>).
data_path(Home, ID) -> filename:join(directory(Home), <<ID/binary, ".data">>).
meta_path(Home, ID) -> filename:join(directory(Home), <<ID/binary, ".meta">>).
usage_path(Home) -> filename:join(directory(Home), <<"usage.etf">>).
now_ms() -> erlang:system_time(millisecond).
valid_id(ID) -> is_binary(ID) andalso byte_size(ID) =:= 32 andalso lists:all(fun(C) -> C >= $0 andalso C =< $9 orelse C >= $a andalso C =< $f end, binary_to_list(ID)).

guarded(Run) -> try Run() catch _:_ -> {error, <<"active output storage is unavailable">>} end.

delete_content(Home, ID) ->
    Bytes = case file:read_file_info(data_path(Home, ID)) of {ok, Info} -> Info#file_info.size; _ -> 0 end,
    Total = usage(Home),
    case file:delete(data_path(Home, ID)) of
        ok -> save(usage_path(Home), erlang:max(0, Total - Bytes));
        {error, enoent} -> ok;
        Error -> error(Error)
    end,
    case file:delete(meta_path(Home, ID)) of ok -> ok; {error, enoent} -> ok; Error2 -> error(Error2) end.

disk_bytes(Home) ->
    case file:list_dir(directory(Home)) of
        {ok, Files} -> lists:sum([case file:read_file_info(filename:join(directory(Home), Name)) of
            {ok, Info} -> Info#file_info.size; _ -> 0 end || Name <- Files, filename:extension(Name) =:= ".data"]);
        {error, enoent} -> 0
    end.

%% One rarely installed immutable token distinguishes owner PIDs across VMs.
instance() ->
    case persistent_term:get({?MODULE, instance}, none) of
        none -> global:trans({{?MODULE, instance}, self()}, fun() ->
            case persistent_term:get({?MODULE, instance}, none) of
                none -> ID = crypto:strong_rand_bytes(16), persistent_term:put({?MODULE, instance}, ID), ID;
                ID -> ID
            end
        end);
        ID -> ID
    end.
