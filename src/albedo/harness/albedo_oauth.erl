-module(albedo_oauth).
%% Browser OAuth sign-ins run by the daemon for its clients. One owner process
%% tracks the flows; each flow owns its loopback callback listener and ends by
%% storing the credential in auth.json under the provider's key.

-export([start/2, status/1, input/2, cancel/1, accounts/2, select/3, remove/3,
         parse_input/1]).

-define(OWNER, albedo_oauth).
-define(FLOW_TIMEOUT_MS, 300000).
-define(FORGET_MS, 600000).
-define(CALL_MS, 5000).

%% Login is the Gleam oauth.Login record:
%% {login, Provider, Label, Detail, Protocol, Store, {callback, Host, Port, Path, Fixed}, Authorize, Exchange, Account}
start(Home, Login) -> call({start, Home, Login}).

status(Id) -> call({status, Id}).

input(Id, Text) -> call({input, Id, Text}).

cancel(Id) -> call({cancel, Id}).

call(Message) ->
    Owner = owner(),
    Ref = erlang:monitor(process, Owner),
    Owner ! {self(), Ref, Message},
    receive
        {Ref, Reply} -> erlang:demonitor(Ref, [flush]), Reply;
        {'DOWN', Ref, process, _, _} -> {error, <<"sign-in service stopped">>}
    after ?CALL_MS ->
        erlang:demonitor(Ref, [flush]),
        {error, <<"sign-in service is busy">>}
    end.

owner() ->
    case whereis(?OWNER) of
        undefined ->
            Pid = spawn(fun() -> owner_loop(#{}) end),
            try register(?OWNER, Pid) of
                true -> Pid
            catch _:_ -> exit(Pid, kill), whereis(?OWNER)
            end;
        Pid -> Pid
    end.

%% ---- owner --------------------------------------------------------------

owner_loop(Flows) ->
    receive
        {From, Ref, {start, Home, Login}} ->
            Id = token(12),
            Owner = self(),
            Pid = spawn(fun() -> flow(Owner, Id, Home, Login) end),
            erlang:monitor(process, Pid),
            receive
                {Id, ready, Url} ->
                    From ! {Ref, {ok, {Id, Url}}},
                    owner_loop(Flows#{Id => #{pid => Pid, status => {waiting, <<"waiting for browser authorization">>}}});
                {Id, failed, Reason} ->
                    From ! {Ref, {error, Reason}},
                    owner_loop(Flows)
            after ?CALL_MS ->
                exit(Pid, kill),
                From ! {Ref, {error, <<"sign-in did not start">>}},
                owner_loop(Flows)
            end;
        {From, Ref, {status, Id}} ->
            From ! {Ref, case Flows of
                #{Id := #{status := Status}} -> {ok, Status};
                _ -> {error, <<"unknown sign-in">>}
            end},
            owner_loop(Flows);
        {From, Ref, {input, Id, Text}} ->
            From ! {Ref, case Flows of
                #{Id := #{pid := Pid}} -> Pid ! {input, Text}, {ok, nil};
                _ -> {error, <<"unknown sign-in">>}
            end},
            owner_loop(Flows);
        {From, Ref, {cancel, Id}} ->
            case Flows of
                #{Id := #{pid := Pid}} -> exit(Pid, kill);
                _ -> ok
            end,
            From ! {Ref, {ok, nil}},
            owner_loop(maps:remove(Id, Flows));
        {Id, update, Status} ->
            owner_loop(update(Flows, Id, Status));
        {forget, Id} ->
            owner_loop(maps:remove(Id, Flows));
        {'DOWN', _, process, Pid, Reason} ->
            %% A flow that died without settling failed.
            owner_loop(maps:map(fun
                (_, #{pid := P, status := {S, _}} = F) when P =:= Pid, S =/= done, S =/= failed ->
                    F#{status => {failed, iolist_to_binary(io_lib:format("sign-in stopped: ~p", [Reason]))}};
                (_, F) -> F
            end, Flows));
        _ -> owner_loop(Flows)
    end.

update(Flows, Id, {State, _} = Status) ->
    case Flows of
        #{Id := Flow} ->
            (State =:= done orelse State =:= failed) andalso
                erlang:send_after(?FORGET_MS, self(), {forget, Id}),
            Flows#{Id := Flow#{status => Status}};
        _ -> Flows
    end.

%% ---- one flow -----------------------------------------------------------

flow(Owner, Id, Home, {login, Provider, _, _, _, Store, {callback, Host, Port, Path, Fixed}, Authorize, Exchange, Account}) ->
    case listen(Port, Fixed) of
        {error, Reason} ->
            Owner ! {Id, failed, iolist_to_binary(io_lib:format(
                "could not listen for the ~s sign-in callback on 127.0.0.1:~B (~p)", [Provider, Port, Reason]))};
        {ok, Socket, Bound} ->
            State = token(16),
            Verifier = base64url(crypto:strong_rand_bytes(64)),
            Challenge = base64url(crypto:hash(sha256, Verifier)),
            Redirect = iolist_to_binary(["http://", Host, ":", integer_to_binary(Bound), Path]),
            Grant = {grant, Redirect, State, Verifier, Challenge},
            Self = self(),
            spawn_link(fun() -> accept(Socket, Path, Self) end),
            Owner ! {Id, ready, Authorize(Grant)},
            erlang:send_after(?FLOW_TIMEOUT_MS, self(), timeout),
            Settle = fun(Status) -> Owner ! {Id, update, Status} end,
            Outcome = wait(State),
            gen_tcp:close(Socket),
            case Outcome of
                {ok, Code} ->
                    Settle({exchanging, <<"exchanging authorization code">>}),
                    Progress = fun(Text) -> Settle({exchanging, Text}), nil end,
                    try Exchange(Grant, Code, Progress) of
                        {ok, Credential} ->
                            case store(Home, Store, Credential, Account) of
                                {ok, Label} -> Settle({done, Label});
                                {error, Reason} -> Settle({failed, Reason})
                            end;
                        {error, Reason} -> Settle({failed, Reason})
                    catch Class:Reason ->
                        Settle({failed, iolist_to_binary(io_lib:format("sign-in failed: ~p:~p", [Class, Reason]))})
                    end;
                {error, Reason} -> Settle({failed, Reason})
            end
    end.

listen(Port, Fixed) ->
    Options = [binary, {active, false}, {ip, {127, 0, 0, 1}}, {reuseaddr, true}, {packet, http_bin}],
    case gen_tcp:listen(Port, Options) of
        {ok, Socket} -> {ok, Socket, bound(Socket)};
        {error, eaddrinuse} when not Fixed ->
            case gen_tcp:listen(0, Options) of
                {ok, Socket} -> {ok, Socket, bound(Socket)};
                Error -> Error
            end;
        Error -> Error
    end.

bound(Socket) -> {ok, {_, Port}} = inet:sockname(Socket), Port.

%% The browser callback and a pasted code race; the first valid one wins.
wait(State) ->
    receive
        {callback, #{<<"error">> := Error} = Query} ->
            case maps:get(<<"state">>, Query, State) of
                State ->
                    {error, <<"authorization failed: ",
                              (maps:get(<<"error_description">>, Query, Error))/binary>>};
                _ -> wait(State)
            end;
        {callback, #{<<"code">> := <<_, _/binary>> = Code, <<"state">> := State}} -> {ok, Code};
        {callback, _} -> wait(State);
        {input, Text} ->
            case parse_input(Text) of
                {<<>>, _} -> {error, <<"missing authorization code">>};
                {Code, <<>>} -> {ok, Code};
                {Code, State} -> {ok, Code};
                {_, _} -> {error, <<"oauth state mismatch">>}
            end;
        timeout -> {error, <<"sign-in timed out waiting for the browser">>}
    end.

accept(Listen, Path, Flow) ->
    case gen_tcp:accept(Listen) of
        {ok, Socket} ->
            _ = serve(Socket, Path, Flow),
            gen_tcp:close(Socket),
            accept(Listen, Path, Flow);
        {error, _} -> ok
    end.

serve(Socket, Path, Flow) ->
    case gen_tcp:recv(Socket, 0, 10000) of
        {ok, {http_request, 'GET', {abs_path, Target}, _}} ->
            drain_headers(Socket),
            {RequestPath, Query} = split_target(Target),
            case RequestPath =:= iolist_to_binary(Path) of
                true ->
                    Flow ! {callback, Query},
                    page(Socket, 200, case Query of
                        #{<<"code">> := _} -> <<"Authentication completed. You can close this window and return to albedo.">>;
                        _ -> <<"Authentication failed. Return to albedo for details.">>
                    end);
                false -> page(Socket, 404, <<"Not found.">>)
            end;
        _ -> page(Socket, 400, <<"Bad request.">>)
    end.

drain_headers(Socket) ->
    case gen_tcp:recv(Socket, 0, 10000) of
        {ok, http_eoh} -> ok;
        {ok, _} -> drain_headers(Socket);
        _ -> ok
    end.

split_target(Target) ->
    case binary:split(Target, <<"?">>) of
        [P, Q] -> {P, maps:from_list(uri_string:dissect_query(Q))};
        [P] -> {P, #{}}
    end.

page(Socket, Status, Text) ->
    Body = <<"<!doctype html><meta charset=utf-8><title>albedo</title><p>", Text/binary, "</p>">>,
    gen_tcp:send(Socket, [<<"HTTP/1.1 ">>, integer_to_binary(Status), <<" OK\r\ncontent-type: text/html; charset=utf-8\r\ncontent-length: ">>,
                          integer_to_binary(byte_size(Body)), <<"\r\nconnection: close\r\n\r\n">>, Body]).

%% A pasted redirect url, `code#state`, a query string, or a bare code.
parse_input(Text0) ->
    Text = string:trim(unicode:characters_to_binary(Text0)),
    Parsed = uri_string:parse(Text),
    case Parsed of
        #{scheme := _, host := _, query := Q} -> pair(maps:from_list(uri_string:dissect_query(Q)));
        _ ->
            case binary:split(Text, <<"#">>) of
                [Code, State] -> {Code, State};
                [_] ->
                    case binary:match(Text, <<"code=">>) of
                        nomatch -> {Text, <<>>};
                        _ -> pair(maps:from_list(uri_string:dissect_query(string:trim(Text, leading, "?#"))))
                    end
            end
    end.

pair(Query) -> {maps:get(<<"code">>, Query, <<>>), maps:get(<<"state">>, Query, <<>>)}.

%% ---- auth.json accounts -------------------------------------------------

path(Home) -> filename:join(unicode:characters_to_list(Home), "auth.json").

stored(Data, Store) ->
    case maps:get(Store, Data, []) of
        List when is_list(List) -> [V || V <- List, is_map(V)];
        One when is_map(One) -> [One];
        _ -> []
    end.

put(Data, Store, []) -> maps:remove(Store, Data);
put(Data, Store, [One]) -> Data#{Store => One};
put(Data, Store, Many) -> Data#{Store => Many}.

id(Account, Credential) -> element(2, Account(Credential)).

%% A sign-in replaces the stored account with the same identity.
store(Home, Store, Json, Account) ->
    Credential = json:decode(iolist_to_binary(Json)),
    Id = id(Account, Credential),
    update(Home, Store, fun(Values) ->
        case lists:any(fun(V) -> id(Account, V) =:= Id end, Values) of
            true -> [case id(Account, V) =:= Id of true -> Credential; false -> V end || V <- Values];
            false -> Values ++ [Credential]
        end
    end, fun(_) -> {ok, element(3, Account(Credential))} end).

update(Home, Store, Change, Reply) ->
    Path = path(Home),
    albedo_credentials:with_lock(Path, fun() ->
        Data = case albedo_credentials:read(Path) of
            {ok, D} -> {ok, D};
            {error, enoent} -> {ok, #{}};
            {error, _} -> {error, <<"auth.json is unreadable; repair it before signing in">>}
        end,
        case Data of
            {ok, Current} ->
                Values = Change(stored(Current, Store)),
                case albedo_credentials:write(Path, put(Current, Store, Values)) of
                    ok -> Reply(Values);
                    {error, _} -> {error, <<"could not write auth.json">>}
                end;
            Error -> Error
        end
    end, fun() -> {error, <<"credential store is busy">>} end).

accounts(Home, {login, _, _, _, _, Store, _, _, _, Account}) ->
    case albedo_credentials:read(path(Home)) of
        {ok, Data} -> [Account(V) || V <- stored(Data, Store)];
        _ -> []
    end.

select(Home, {login, _, _, _, _, Store, _, _, _, Account}, Id) ->
    update(Home, Store, fun(Values) ->
        [V#{<<"selected">> => id(Account, V) =:= Id} || V <- Values]
    end, fun(_) -> {ok, nil} end).

remove(Home, {login, _, _, _, _, Store, _, _, _, Account}, Id) ->
    update(Home, Store, fun(Values) -> [V || V <- Values, id(Account, V) =/= Id] end,
           fun(_) -> {ok, nil} end).

%% ---- helpers ------------------------------------------------------------

token(Bytes) -> binary:encode_hex(crypto:strong_rand_bytes(Bytes), lowercase).

base64url(Bytes) -> base64:encode(Bytes, #{mode => urlsafe, padding => false}).
