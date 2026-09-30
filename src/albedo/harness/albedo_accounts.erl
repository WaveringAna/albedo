-module(albedo_accounts).
%% Account pools shared by providers that hold several accounts or keys: the
%% order a session tries them in, which one it sticks to, and the limits that
%% push it onto a sibling. Accounts are maps; `selected` and `limitedUntil`
%% are the only keys read here. Scope names the pool, e.g. <<"codex">>.

-export([order/4, remember/3, limited/2, mark/4, note/3, noted/2,
         served/2, last_served/2, local_time/1]).

%% A user-selected account comes first, then the session's sticky or hashed
%% choice. Accounts still inside a reported limit go last, soonest reset first:
%% they are only worth trying when every sibling is limited too.
order(_, [], _, _) -> [];
order(Scope, Values, Session, Identity) ->
    Now = erlang:system_time(millisecond),
    {Limited, Open} = lists:partition(fun(V) -> limited(V, Now) end, Values),
    {Selected, Rest} = lists:partition(fun selected/1, spread(Scope, Open, Session, Identity)),
    Selected ++ Rest ++ lists:sort(fun(A, B) -> until_of(A) =< until_of(B) end, Limited).

spread(_, [], _, _) -> [];
spread(Scope, Values, Session, Identity) ->
    case erlang:get({?MODULE, Scope, Session}) of
        Pinned when is_binary(Pinned), Pinned =/= <<>> ->
            {Hit, Others} = lists:partition(fun(V) -> Identity(V) =:= Pinned end, Values),
            Hit ++ Others;
        _ ->
            Start = fnv1a(Session) rem length(Values),
            {Head, Tail} = lists:split(Start, Values),
            Tail ++ Head
    end.

%% Sticks the session to the account it was just given.
remember(Scope, Session, Id) ->
    erlang:put({?MODULE, Scope, Session}, Id),
    ok.

selected(V) -> maps:get(<<"selected">>, V, false) =:= true.

limited(V, Now) -> until_of(V) > Now.

until_of(#{<<"limitedUntil">> := Until}) when is_integer(Until) -> Until;
until_of(_) -> 0.

%% Records Until on the creds.json accounts under Key that Hit matches, and
%% returns every account there, updated. A single stored object stays single.
mark(Path, Key, Hit, Until) ->
    albedo_settings_lock:with_lock(filename:dirname(Path), fun() ->
        case albedo_credentials:accounts(Path) of
            {ok, Data} ->
                Stored = maps:get(Key, Data, []),
                Values = case Stored of L when is_list(L) -> L; One -> [One] end,
                Updated = [case is_map(V) andalso Hit(V) of
                               true -> V#{<<"limitedUntil">> => Until};
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

fnv1a(Bytes) ->
    lists:foldl(fun(Byte, Hash) -> ((Hash bxor Byte) * 16777619) band 16#ffffffff end,
                16#811c9dc5, binary_to_list(Bytes)).
