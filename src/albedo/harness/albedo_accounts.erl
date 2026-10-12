-module(albedo_accounts).
%% Account pools shared by providers that hold several accounts or keys: the
%% order a session tries them in, which one it sticks to, and the limits that
%% push it onto a sibling. Accounts are maps; `selected`, `limitedUntil`, and
%% `limitedMeters` are the only keys read here. Scope names the pool, e.g. <<"codex">>.

-export([order/4, order/5, remember/3, limited/2, limited/3, mark/4, mark/5,
         until_of/2, note/3, noted/2, served/2, last_served/2, local_time/1]).

%% A user-selected account comes first, then the session's sticky or hashed
%% choice. Accounts still inside a reported limit go last, soonest reset first:
%% they are only worth trying when every sibling is limited too.
order(Scope, Values, Session, Identity) ->
    order(Scope, Values, Session, Identity, undefined).

order(_, [], _, _, _) -> [];
order(Scope, Values, Session, Identity, Meter) ->
    Now = erlang:system_time(millisecond),
    Sticky = case erlang:get({?MODULE, Scope, Session}) of
        Pinned when is_binary(Pinned), Pinned =/= <<>> -> {some, Pinned};
        _ -> none
    end,
    Entries = [begin
        Until = until_of(Value, Meter),
        Id = case Sticky of
            {some, _} when Until =< Now -> Identity(Value);
            _ -> <<>>
        end,
        {entry, Value, Id, maps:get(<<"selected">>, Value, false) =:= true, Until}
    end || Value <- Values],
    'albedo@harness@accounts':order(Entries, Session, Sticky, Now).

%% Sticks the session to the account it was just given.
remember(Scope, Session, Id) ->
    erlang:put({?MODULE, Scope, Session}, Id),
    ok.

limited(V, Now) -> limited(V, Now, undefined).
limited(V, Now, Meter) -> until_of(V, Meter) > Now.

until_of(Value, undefined) ->
    until_of_any(Value);
until_of(Value, Meter) when is_binary(Meter) ->
    case maps:find(<<"limitedMeters">>, Value) of
        {ok, Meters} when is_map(Meters) ->
            case maps:find(Meter, Meters) of
                {ok, Until} when is_integer(Until) -> Until;
                _ -> 0
            end;
        _ ->
            until_of_legacy(Value)
    end;
until_of(Value, _) ->
    until_of(Value, undefined).

until_of_legacy(#{<<"limitedUntil">> := Until}) when is_integer(Until) -> Until;
until_of_legacy(_) -> 0.

until_of_any(Value) ->
    Legacy = until_of_legacy(Value),
    case maps:find(<<"limitedMeters">>, Value) of
        {ok, Meters} when is_map(Meters) andalso map_size(Meters) > 0 ->
            Vals = [U || U <- maps:values(Meters), is_integer(U)],
            case Vals of
                [] -> Legacy;
                _ -> lists:max([Legacy | Vals])
            end;
        _ ->
            Legacy
    end.

%% Records Until on the creds.json accounts under Key that Hit matches, and
%% returns every account there, updated. A single stored object stays single.
mark(Path, Key, Hit, Until) ->
    mark(Path, Key, Hit, Until, undefined).

mark(Path, Key, Hit, Until, Meter) ->
    albedo_settings_lock:with_lock(filename:dirname(Path), fun() ->
        case albedo_credentials:accounts(Path) of
            {ok, Data} ->
                Stored = maps:get(Key, Data, []),
                Values = case Stored of L when is_list(L) -> L; One -> [One] end,
                Now = erlang:system_time(millisecond),
                Updated = [case is_map(V) andalso Hit(V) of
                               true -> update_mark(V, Until, Meter, Now);
                               false -> V
                           end || V <- Values],
                Kept = case Stored of L2 when is_list(L2) -> Updated; _ -> hd(Updated) end,
                case Updated =:= Values orelse albedo_credentials:put_accounts(Path, Data#{Key => Kept}) =:= ok of
                    true -> {ok, [V || V <- Updated, is_map(V)]};
                    false -> {error, <<"could not record the account limit">>}
                end;
            {error, _} -> {error, <<"stored credentials are unreadable">>}
        end
    end, fun() -> {error, <<"credential store is busy">>} end).

update_mark(V, Until, undefined, _Now) ->
    V#{<<"limitedUntil">> => Until};
update_mark(V, Until, Meter, Now) when is_binary(Meter) ->
    Meters = maps:get(<<"limitedMeters">>, V, #{}),
    Live = maps:filter(fun(_, U) -> is_integer(U) andalso U > Now end, Meters),
    V#{<<"limitedMeters">> => Live#{Meter => Until}}.

%% Limits for accounts that do not live in creds.json's accounts, such as
%% profile API keys or the environment. They last as long as the daemon, which
%% outlives any limit short enough to wait on.
note(Scope, Id, Until) ->
    Now = erlang:system_time(millisecond),
    Live = maps:filter(fun(_, U) -> U > Now end, persistent_term:get({?MODULE, Scope}, #{})),
    persistent_term:put({?MODULE, Scope}, Live#{Id => Until}),
    ok.

noted(Scope, Id) -> maps:get(Id, persistent_term:get({?MODULE, Scope}, #{}), 0).

%% The account a rotating request last sent to, so the failure it ends with is
%% explained against that account rather than the one it started on.
served(Slot, Account) -> erlang:put({?MODULE, served, Slot}, Account), nil.

last_served(Slot, First) ->
    case erlang:get({?MODULE, served, Slot}) of
        undefined -> First;
        Account -> Account
    end.

local_time(Ms) ->
    {{Y, Mo, D} = Date, {H, M, _}} = calendar:system_time_to_local_time(Ms, millisecond),
    {Today, _} = calendar:local_time(),
    Clock = io_lib:format("~2..0B:~2..0B", [H, M]),
    iolist_to_binary(case Date =:= Today of
        true -> Clock;
        false -> io_lib:format("~4..0B-~2..0B-~2..0B ~s", [Y, Mo, D, Clock])
    end).
