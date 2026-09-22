-module(albedo_openai_auth).
%% Shared OpenAI auth primitives and Codex multi-account credential selection.

-export([codex_access/2]).

-define(CLIENT_ID, <<"app_EMoamEEZ73f0CkXaXp7hrann">>).
-define(TOKEN_URL, "https://auth.openai.com/oauth/token").
-define(REFRESH_SKEW_MS, 60000).
-define(HTTP_TIMEOUT_MS, 15000).
-define(LOCK_ATTEMPTS, 1000).
-define(LOCK_STALE_MS, 30000).

codex_access(Home0, Session0) ->
    Home = text(Home0),
    Session = unicode:characters_to_binary(Session0),
    Path = filename:join(Home, "auth.json"),
    case read_auth(Path) of
        {ok, Data} ->
            Credentials = credentials(Data),
            select(order(Credentials, Session), Path, Session);
        {error, _} -> {error, <<"Codex is not authenticated; run /login and add a ChatGPT account">>}
    end.

select([], _, _) -> {error, <<"Codex is not authenticated; run /login and add a ChatGPT account">>};
select([Credential | Rest], Path, Session) ->
    case usable(Credential) of
        {ok, Access} ->
            remember(Session, Access),
            encode_access(Access);
        refresh ->
            case refresh_locked(Path, identity(Credential)) of
                {ok, Access} ->
                    remember(Session, Access),
                    encode_access(Access);
                {error, _} -> select(Rest, Path, Session)
            end;
        error -> select(Rest, Path, Session)
    end.

encode_access(Credential) ->
    Access = maps:get(<<"access">>, Credential),
    AccountId = account_id(Credential),
    {ok, iolist_to_binary(json:encode(#{<<"access">> => Access, <<"accountId">> => AccountId}))}.

usable(Credential) when is_map(Credential) ->
    Access = maps:get(<<"access">>, Credential, undefined),
    Refresh = maps:get(<<"refresh">>, Credential, undefined),
    Expires = maps:get(<<"expires">>, Credential, 0),
    AccountId = account_id(Credential),
    RefreshBefore = erlang:system_time(millisecond) + ?REFRESH_SKEW_MS,
    case is_binary(Access) andalso Access =/= <<>> andalso
         is_binary(Refresh) andalso Refresh =/= <<>> andalso
         is_binary(AccountId) andalso AccountId =/= <<>> andalso is_integer(Expires) of
        true when Expires > RefreshBefore -> {ok, Credential};
        true -> refresh;
        false -> error
    end;
usable(_) -> error.

credentials(Data) when is_map(Data) ->
    case maps:get(<<"openai-codex">>, Data, []) of
        Values when is_list(Values) -> [V || V <- Values, is_map(V), maps:get(<<"type">>, V, <<>>) =:= <<"oauth">>];
        Value when is_map(Value) ->
            case maps:get(<<"type">>, Value, <<>>) of <<"oauth">> -> [Value]; _ -> [] end;
        _ -> []
    end;
credentials(_) -> [].

order([], _) -> [];
order(Values, Session) ->
    case erlang:get({?MODULE, Session}) of
        Identity when is_binary(Identity), Identity =/= <<>> ->
            {Pinned, Others} = lists:partition(fun(Value) -> identity(Value) =:= Identity end, Values),
            Pinned ++ Others;
        _ ->
            N = length(Values),
            Start = fnv1a(Session) rem N,
            {Head, Tail} = lists:split(Start, Values),
            Tail ++ Head
    end.

remember(Session, Credential) ->
    erlang:put({?MODULE, Session}, identity(Credential)),
    ok.

fnv1a(Bytes) ->
    lists:foldl(fun(Byte, Hash) -> ((Hash bxor Byte) * 16777619) band 16#ffffffff end,
                16#811c9dc5, binary_to_list(Bytes)).

refresh_locked(Path, Identity) ->
    Lock = filename:join(filename:dirname(Path), "auth.lock"),
    case acquire(Lock, ?LOCK_ATTEMPTS) of
        {ok, Device} ->
            try refresh_current(Path, Identity)
            after
                file:close(Device),
                file:delete(Lock)
            end;
        {error, _} -> refreshed_after_wait(Path, Identity)
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

refreshed_after_wait(Path, Identity) ->
    case read_auth(Path) of
        {ok, Data} ->
            case find_identity(credentials(Data), Identity) of
                undefined -> {error, <<"credential changed during refresh">>};
                Current ->
                    case usable(Current) of
                        {ok, Access} -> {ok, Access};
                        _ -> {error, <<"credential store is busy">>}
                    end
            end;
        _ -> {error, <<"credential store is busy">>}
    end.

refresh_current(Path, Identity) ->
    case read_auth(Path) of
        {ok, Data} ->
            Values = credentials(Data),
            case find_identity(Values, Identity) of
                undefined -> {error, <<"credential changed during refresh">>};
                Current ->
                    case usable(Current) of
                        {ok, Access} -> {ok, Access};
                        refresh ->
                            case refresh_token(Current) of
                                {ok, Updated} ->
                                    UpdatedValues = replace_identity(Values, Identity, Updated),
                                    case write_auth(Path, set_credentials(Data, UpdatedValues)) of
                                        ok -> {ok, Updated};
                                        {error, _} -> {error, <<"could not persist refreshed Codex credential">>}
                                    end;
                                Error -> Error
                            end;
                        error -> {error, <<"stored Codex credential is invalid">>}
                    end
            end;
        Error -> Error
    end.

find_identity([], _) -> undefined;
find_identity([Credential | Rest], Identity) ->
    case identity(Credential) =:= Identity of
        true -> Credential;
        false -> find_identity(Rest, Identity)
    end.

replace_identity(Values, Identity, Updated) ->
    [case identity(Value) =:= Identity of true -> Updated; false -> Value end || Value <- Values].

set_credentials(Data, [Only]) -> maps:put(<<"openai-codex">>, Only, Data);
set_credentials(Data, Values) -> maps:put(<<"openai-codex">>, Values, Data).

refresh_token(Credential) ->
    Refresh = maps:get(<<"refresh">>, Credential),
    Body = uri_string:compose_query([
        {<<"grant_type">>, <<"refresh_token">>},
        {<<"refresh_token">>, Refresh},
        {<<"client_id">>, ?CLIENT_ID}
    ]),
    _ = application:ensure_all_started(inets),
    _ = application:ensure_all_started(ssl),
    Request = {?TOKEN_URL, [{"accept", "application/json"}],
               "application/x-www-form-urlencoded", binary_to_list(Body)},
    Options = [{timeout, ?HTTP_TIMEOUT_MS}, {connect_timeout, 10000},
               {ssl, tls_options("auth.openai.com")}],
    case httpc:request(post, Request, Options, [{body_format, binary}]) of
        {ok, {{_, 200, _}, _, Response}} -> parse_refresh(Response, Credential);
        {ok, {{_, Status, _}, _, _}} ->
            {error, iolist_to_binary(io_lib:format("Codex token refresh failed (~B)", [Status]))};
        _ -> {error, <<"Codex token refresh failed">>}
    end.

parse_refresh(Response, Previous) ->
    try json:decode(Response) of
        Token when is_map(Token) ->
            Access = maps:get(<<"access_token">>, Token, undefined),
            ReturnedRefresh = maps:get(<<"refresh_token">>, Token, undefined),
            Refresh = case ReturnedRefresh of
                Value when is_binary(Value), Value =/= <<>> -> Value;
                _ -> maps:get(<<"refresh">>, Previous, undefined)
            end,
            ExpiresIn = maps:get(<<"expires_in">>, Token, undefined),
            case is_binary(Access) andalso Access =/= <<>> andalso
                 is_binary(Refresh) andalso Refresh =/= <<>> andalso
                 is_integer(ExpiresIn) andalso ExpiresIn > 0 of
                true ->
                    Claims = token_identity(Access),
                    Updated0 = Previous#{
                        <<"type">> => <<"oauth">>,
                        <<"access">> => Access,
                        <<"refresh">> => Refresh,
                        <<"expires">> => erlang:system_time(millisecond) + ExpiresIn * 1000
                    },
                    Updated = preserve_identity(Updated0, Claims),
                    case account_id(Updated) of
                        <<>> -> {error, <<"refreshed Codex token has no account identity">>};
                        _ -> {ok, Updated}
                    end;
                false -> {error, <<"Codex token refresh response is incomplete">>}
            end;
        _ -> {error, <<"Codex token refresh response is invalid">>}
    catch
        _:_ -> {error, <<"Codex token refresh response is invalid">>}
    end.

preserve_identity(Credential, Claims) ->
    lists:foldl(fun(Key, Acc) ->
        case maps:get(Key, Claims, undefined) of
            Value when is_binary(Value), Value =/= <<>> -> maps:put(Key, Value, Acc);
            _ -> Acc
        end
    end, Credential, [<<"accountId">>, <<"accountUserId">>, <<"email">>]).

identity(Credential) ->
    Claims = token_identity(maps:get(<<"access">>, Credential, <<>>)),
    first([
        maps:get(<<"accountUserId">>, Claims, undefined),
        maps:get(<<"accountUserId">>, Credential, undefined),
        maps:get(<<"accountId">>, Claims, undefined),
        maps:get(<<"accountId">>, Credential, undefined),
        lower(maps:get(<<"email">>, Credential, undefined)),
        maps:get(<<"refresh">>, Credential, <<>>)
    ]).

account_id(Credential) ->
    Claims = token_identity(maps:get(<<"access">>, Credential, <<>>)),
    first([maps:get(<<"accountId">>, Claims, undefined), maps:get(<<"accountId">>, Credential, <<>>)]).

first([]) -> <<>>;
first([Value | _]) when is_binary(Value), Value =/= <<>> -> Value;
first([_ | Rest]) -> first(Rest).

lower(Value) when is_binary(Value) -> string:lowercase(Value);
lower(_) -> undefined.

token_identity(Token) when is_binary(Token) ->
    case binary:split(Token, <<".">>, [global]) of
        [_, Payload, _] -> decode_claims(Payload);
        _ -> #{}
    end;
token_identity(_) -> #{}.

decode_claims(Payload) ->
    try
        Padded = pad64(binary:replace(binary:replace(Payload, <<"-">>, <<"+">>, [global]),
                                      <<"_">>, <<"/">>, [global])),
        Claims = json:decode(base64:decode(Padded)),
        Auth = maps:get(<<"https://api.openai.com/auth">>, Claims, #{}),
        Profile = maps:get(<<"https://api.openai.com/profile">>, Claims, #{}),
        maps:filter(fun(_, V) -> is_binary(V) andalso V =/= <<>> end, #{
            <<"accountId">> => maps:get(<<"chatgpt_account_id">>, Auth, undefined),
            <<"accountUserId">> => maps:get(<<"chatgpt_account_user_id">>, Auth, undefined),
            <<"email">> => lower(maps:get(<<"email">>, Profile, undefined))
        })
    catch
        _:_ -> #{}
    end.

pad64(Value) ->
    case byte_size(Value) rem 4 of
        0 -> Value;
        2 -> <<Value/binary, "==">>;
        3 -> <<Value/binary, "=">>;
        _ -> Value
    end.

read_auth(Path) ->
    case file:read_file(Path) of
        {ok, Bytes} ->
            try json:decode(Bytes) of
                Data when is_map(Data) -> {ok, Data};
                _ -> {error, invalid}
            catch _:_ -> {error, invalid} end;
        Error -> Error
    end.

write_auth(Path, Data) ->
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

tls_options(Host) ->
    [{verify, verify_peer}, {cacerts, public_key:cacerts_get()}, {depth, 5},
     {server_name_indication, Host},
     {customize_hostname_check, [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}].

text(Value) -> unicode:characters_to_list(Value).
