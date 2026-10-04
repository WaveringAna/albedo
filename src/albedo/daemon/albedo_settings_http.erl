-module(albedo_settings_http).
-export([composition_revision/1, mcp_definitions/1, observe/2, patch/8, json_null/0]).
-import(albedo_settings_store, [with_lock/2, object/2, check/1, commit_group/2]).

%% These are HTTP boundary projections. Persisted names remain owned by the
%% harness, including callers from trusted model tools.
observe(Home, Group) -> with_lock(Home, fun() -> guarded(fun() ->
    Groups = case Group of
        <<"ui">> -> #{<<"ui">> => projection('albedo@daemon@settings_projection':ui_group(albedo_settings_store:read(Home, <<"picker.json">>)))};
        _ -> projection('albedo@daemon@settings_projection':groups(documents(Home)))
    end,
    Revisions = albedo_settings_store:read(Home, <<"settings-revisions.json">>),
    Value = case Group of
        <<>> -> Groups#{<<"group_resources">> => maps:map(fun(Name, V) -> validator(Name, V, Revisions) end, Groups)};
        _ -> group(Group, Groups)
    end,
    Tag = case Group of <<>> -> none; _ -> {some, group_etag(Group, Value, Revisions)} end,
    {ok, {group_snapshot, encode(Value), Tag}}
end) end).

patch(Home, Group, Match, PatchJSON, Providers, Logins, Resolve, Defaults) ->
    Captured = with_lock(Home, fun() -> guarded(fun() ->
        Docs = documents(Home), Groups = projection('albedo@daemon@settings_projection':groups(Docs)), Prior = group(Group, Groups),
        Revisions = albedo_settings_store:read(Home, <<"settings-revisions.json">>),
        match_group(Group, Match, Prior, Revisions),
        {ok, Patch} = albedo_http_api:parse(PatchJSON),
        {Next, Validation} = candidate(Home, Group, Patch, Docs, Resolve, Defaults),
        case Group of <<"providers">> -> validate_provider_accounts(Next, Providers, Logins); _ -> ok end,
        case Group =:= <<"mcp">> andalso maps:get(<<"validate_connection">>, Patch, true) of
            true -> {ok, {probe, Patch, checked_candidates(Patch, Next)}};
            false -> {ok, {complete, publish(Home, Group, Docs, Next, Validation, Revisions)}}
        end
    end) end),
    case Captured of
        {error, _} = Error -> Error;
        {ok, {complete, Result}} -> {ok, Result};
        {ok, {probe, Patch, Checked}} -> guarded(fun() ->
            %% Candidate clients are closed by check_candidate before publication.
            %% Initialization must not hold the mutex used by unrelated readers.
            lists:foreach(fun({Name, Definition, Secret}) ->
                check(albedo_mcp:check_candidate(Name, Definition, Secret))
            end, Checked),
            with_lock(Home, fun() -> guarded(fun() ->
                Docs = documents(Home), Prior = group(Group, projection('albedo@daemon@settings_projection':groups(Docs))),
                Revisions = albedo_settings_store:read(Home, <<"settings-revisions.json">>),
                match_group(Group, Match, Prior, Revisions),
                {Next, Validation} = candidate(Home, Group, Patch, Docs, Resolve, Defaults),
                %% Redacted validators alone cannot detect direct secret changes.
                ensure(checked_candidates(Patch, Next) =:= Checked, 412,
                    <<"precondition_failed">>, <<"MCP candidate inputs changed during validation">>),
                {ok, publish(Home, Group, Docs, Next, Validation, Revisions)}
            end) end)
        end)
    end.

match_group(Group, Match, Prior, Revisions) ->
    case Match of
        <<>> -> refusal(428, <<"precondition_required">>, <<"If-Match is required">>);
        _ -> ensure(Match =:= group_etag(Group, Prior, Revisions), 412,
            <<"precondition_failed">>, <<"settings changed">>)
    end.

checked_candidates(Patch, Docs) ->
    Definitions = object(<<"servers">>, object(<<"mcp">>, maps:get(<<"extensions.json">>, Docs))),
    Secrets = object(<<"mcp">>, maps:get(<<"creds.json">>, Docs)),
    [{Name, maps:get(Name, Definitions), maps:get(Name, Secrets, #{})}
        || {Name, Change} <- lists:sort(maps:to_list(object(<<"definitions">>, Patch))), Change =/= null].

publish(Home, Group, Docs, Next, Validation, Revisions) ->
    Value = group(Group, projection('albedo@daemon@settings_projection':groups(Next))),
    Changed = maps:filter(fun(File, V) -> V =/= maps:get(File, Docs) end, Next),
    NextRevisions = case map_size(Changed) of
        0 -> Revisions;
        _ ->
            Updated = Revisions#{Group => maps:get(Group, Revisions, 0) + 1},
            commit_group(Home, Changed#{<<"settings-revisions.json">> => Updated}),
            Updated
    end,
    Resource = (validator(Group, Value, NextRevisions))#{<<"value">> => Value},
    encode(#{<<"group">> => Group, <<"resource">> => Resource, <<"validation">> => Validation}).

documents(Home) -> maps:from_list([{File, albedo_settings_store:read(Home, File)} || File <-
    [<<"config.json">>, <<"creds.json">>, <<"extensions.json">>, <<"capabilities.json">>, <<"picker.json">>]]).

group(Name, Groups) -> case maps:find(Name, Groups) of {ok, Value} -> Value; error -> refusal(400, <<"invalid_request">>, <<"unknown settings group">>) end.
validator(Name, Value, Revisions) -> #{<<"url">> => <<"/settings?group=", Name/binary>>, <<"etag">> => group_etag(Name, Value, Revisions)}.
group_etag(Name, Value, Revisions) ->
    Counter = maps:get(Name, Revisions, 0), true = is_integer(Counter) andalso Counter >= 0,
    albedo_http_api:etag(encode(#{<<"value">> => Value, <<"revision">> => Counter})).
encode(Value) -> iolist_to_binary(json:encode(Value)).
nonempty(<<>>) -> null; nonempty(Value) -> Value.

candidate(_, <<"providers">>, Patch, Docs, _, _) ->
    fields(Patch, [<<"profiles">>, <<"default_profile">>]),
    Config = saved_config(maps:get(<<"config.json">>, Docs)), Creds = maps:get(<<"creds.json">>, Docs),
    Changes = object(<<"profiles">>, Patch),
    {SavedProfiles, SavedKeys} = maps:fold(fun(Name, Profile, {Profiles0, Keys0}) ->
        Keys = case maps:find(<<"apiKey">>, Profile) of
            {ok, <<_, _/binary>> = Key} -> Keys0#{Name => #{<<"apiKey">> => Key}};
            _ -> Keys0
        end,
        {Profiles0#{Name => maps:remove(<<"apiKey">>, Profile)}, Keys}
    end, {#{}, object(<<"providers">>, Creds)}, object(<<"providers">>, Config)),
    {Profiles, Keys} = maps:fold(fun(Name, Change, {Profiles0, Keys0}) ->
        text(Name, 1, 64),
        case Change of
            null -> {maps:remove(Name, Profiles0), maps:remove(Name, Keys0)};
            _ ->
                fields(Change, [<<"extension">>, <<"endpoint">>, <<"protocol">>, <<"model">>, <<"effort">>, <<"image_edge">>, <<"account_id">>, <<"api_key">>]),
                Old = maps:get(Name, Profiles0, #{}),
                Public = translate(maps:remove(<<"api_key">>, Change), provider_fields()),
                Complete = maps:merge(Old, Public),
                Standard = Complete#{<<"baseUrl">> => case maps:get(<<"baseUrl">>, Complete, <<>>) of null -> <<>>; Endpoint -> Endpoint end, <<"protocol">> => maps:get(<<"protocol">>, Complete, <<"responses">>)},
                {ok, Validated} = 'albedo@daemon@configuration':normalize_profile(Name, Standard),
                Valid = maps:merge(maps:remove(<<"apiKey">>, Standard), maps:remove(<<"apiKey">>, Validated)),
                nullable_text(maps:get(<<"effort">>, Valid, null), 100), nullable_text(maps:get(<<"accountId">>, Valid, null), 512),
                case maps:get(<<"imageEdge">>, Valid, null) of null -> ok; Edge -> counter(Edge, 1, 65536) end,
                NewKeys = case maps:find(<<"api_key">>, Change) of
                    error -> case maps:find(<<"apiKey">>, Standard) of
                        {ok, <<_, _/binary>> = Key} -> Keys0#{Name => #{<<"apiKey">> => Key}};
                        _ -> Keys0
                    end;
                    {ok, null} -> maps:remove(Name, Keys0);
                    {ok, Key} -> text(Key, 1, 16384), {ok, _} = 'albedo@daemon@configuration':normalize_profile(Name, Standard#{<<"apiKey">> => Key}), Keys0#{Name => #{<<"apiKey">> => Key}}
                end,
                {Profiles0#{Name => Valid}, NewKeys}
        end
    end, {SavedProfiles, SavedKeys}, Changes),
    Default = maps:get(<<"default_profile">>, Patch, nonempty(maps:get(<<"active">>, Config, null))),
    ensure(Default =:= null orelse maps:is_key(Default, Profiles), 409, <<"invalid_default_profile">>, <<"replace or clear the selected profile">>),
    {Docs#{<<"config.json">> => Config#{<<"providers">> => Profiles, <<"active">> => case Default of null -> <<>>; _ -> Default end},
           <<"creds.json">> => Creds#{<<"providers">> => Keys}}, <<"not_applicable">>};
candidate(_, <<"extensions">>, Patch, Docs, _, Defaults) ->
    fields(Patch, [<<"defaults">>]), Ext = maps:get(<<"extensions.json">>, Docs),
    Current = object(<<"enabled">>, Ext), Changes = object(<<"defaults">>, Patch),
    _ = boolean_choices(Current, Changes),
    NativeChanges = [{Name, case Value of null -> none; _ -> {some, Value} end}
        || {Name, Value} <- lists:sort(maps:to_list(Changes))],
    Next = case Defaults(lists:sort(maps:to_list(Current)), NativeChanges) of
        {ok, Choices} -> maps:from_list(Choices);
        {error, {Status, Code, Detail}} -> refusal(Status, Code, Detail)
    end,
    {Docs#{<<"extensions.json">> => Ext#{<<"enabled">> => Next}}, <<"not_applicable">>};
candidate(_, <<"models">>, Patch, Docs, _, _) ->
    fields(Patch, [<<"raised_caps">>]), Ext = maps:get(<<"extensions.json">>, Docs),
    Next = boolean_choices(object(<<"raisedCaps">>, Ext), object(<<"raised_caps">>, Patch)),
    {Docs#{<<"extensions.json">> => Ext#{<<"raisedCaps">> => Next}}, <<"not_applicable">>};
candidate(_, <<"ui">>, Patch, Docs, _, _) ->
    fields(Patch, [<<"thinking">>, <<"tools">>, <<"dismissed_notices">>]),
    maps:foreach(fun(<<"dismissed_notices">>, Value) -> strings(Value, 1000, 512); (_, Value) -> true = is_boolean(Value) end, Patch),
    Picker = maps:get(<<"picker.json">>, Docs),
    {Docs#{<<"picker.json">> => maps:merge(Picker, Patch)}, <<"not_applicable">>};
candidate(_, <<"capabilities">>, Patch, Docs, Resolve, _) ->
    fields(Patch, [<<"catalog_session_id">>, <<"catalog_revision">>, <<"choices">>]),
    ResolvedJSON = case Resolve(encode(Patch)) of
        {ok, Value} -> Value;
        {error, Detail} -> refusal(409, <<"catalog_changed">>, Detail)
    end,
    Resolved = json:decode(ResolvedJSON),
    Caps = maps:get(<<"capabilities.json">>, Docs), Global = object(<<"global">>, Caps),
    Next = maps:fold(fun(Kind, Changes, Acc) ->
        case map_size(Changes) of
            0 -> Acc;
            _ -> Acc#{Kind => boolean_choices(object(Kind, Acc), Changes)}
        end
    end, Global, Resolved),
    Updated = Caps#{<<"global">> => Next}, albedo_settings_store:validate_caps(Updated),
    ensure(byte_size(encode(Updated)) =< albedo_capabilities:max_bytes(), 409,
        <<"settings_capacity">>, <<"capability preferences exceed their saved byte limit">>),
    {Docs#{<<"capabilities.json">> => Updated}, <<"not_applicable">>};
candidate(_, <<"mcp">>, Patch, Docs, _, _) ->
    fields(Patch, [<<"definitions">>, <<"validate_connection">>]),
    Probe = maps:get(<<"validate_connection">>, Patch, true), true = is_boolean(Probe),
    Ext = maps:get(<<"extensions.json">>, Docs), MCP = object(<<"mcp">>, Ext), Creds = maps:get(<<"creds.json">>, Docs),
    {Definitions, Secrets} = maps:fold(fun(Name, Change, {Definitions0, Secrets0}) ->
        case Change of
            null -> {maps:remove(Name, Definitions0), maps:remove(Name, Secrets0)};
            _ ->
                {Definition, Secret} = mcp_candidate(Change, maps:get(Name, Definitions0, #{}), maps:get(Name, Secrets0, #{})),
                {ok, nil} = albedo_mcp:validate_settings(Name, {some, encode(Definition)}, encode(Secret)),
                {Definitions0#{Name => Definition}, Secrets0#{Name => Secret}}
        end
    end, {object(<<"servers">>, MCP), object(<<"mcp">>, Creds)}, object(<<"definitions">>, Patch)),
    {Docs#{<<"extensions.json">> => Ext#{<<"mcp">> => MCP#{<<"servers">> => Definitions}}, <<"creds.json">> => Creds#{<<"mcp">> => Secrets}},
     case Probe of true -> <<"passed">>; false -> <<"skipped">> end}.

provider_fields() -> [{<<"extension">>, <<"extension">>}, {<<"endpoint">>, <<"baseUrl">>}, {<<"protocol">>, <<"protocol">>},
    {<<"model">>, <<"model">>}, {<<"effort">>, <<"effort">>}, {<<"image_edge">>, <<"imageEdge">>}, {<<"account_id">>, <<"accountId">>}].
translate(Map, Names) -> maps:from_list([{Stored, maps:get(Wire, Map)} || {Wire, Stored} <- Names, maps:is_key(Wire, Map)]).

mcp_candidate(Patch, Prior, Secrets0) ->
    fields(Patch, [Wire || {Wire, _} <- 'albedo@daemon@settings_projection':mcp_fields()] ++ [<<"environment">>, <<"headers">>, <<"secrets">>]),
    Public0 = maps:merge(Prior, translate(Patch, 'albedo@daemon@settings_projection':mcp_fields())),
    SecretPatch = object(<<"secrets">>, Patch), fields(SecretPatch, [<<"bearer_token">>, <<"environment">>, <<"headers">>]),
    {Public1, Secrets1} = lists:foldl(fun({Wire, Stored}, {Public, Secrets}) ->
        PublicChanges = maps:get(Wire, Patch, #{}), SecretChanges = maps:get(Wire, SecretPatch, #{}),
        Sources = source_choices(object(Stored, Public), PublicChanges),
        Saved = secret_choices(object(Stored, Secrets), SecretChanges),
        PNames = case PublicChanges of null -> []; _ -> [K || {K,V} <- maps:to_list(PublicChanges), V =/= null] end,
        SNames = case SecretChanges of null -> []; _ -> [K || {K,V} <- maps:to_list(SecretChanges), V =/= null] end,
        true = lists:all(fun(K) -> not lists:member(K, SNames) end, PNames),
        {Public#{Stored => maps:without(SNames, Sources)}, Secrets#{Stored => maps:without(PNames, Saved)}}
    end, {Public0, Secrets0}, [{<<"environment">>, <<"env">>}, {<<"headers">>, <<"headers">>}]),
    {Public, Secrets} = case maps:find(<<"bearer_token">>, SecretPatch) of
        error -> {Public1, Secrets1};
        {ok, null} -> {Public1, maps:remove(<<"bearerToken">>, Secrets1)};
        {ok, Token} -> text(Token, 1, 16384), {maps:remove(<<"bearerTokenEnvVar">>, Public1), Secrets1#{<<"bearerToken">> => Token}}
    end,
    Secrets2 = case maps:find(<<"bearer_token_env_var">>, Patch) of
        {ok, Name} when is_binary(Name) -> true = not maps:is_key(<<"bearer_token">>, SecretPatch) orelse maps:get(<<"bearer_token">>, SecretPatch) =:= null, maps:remove(<<"bearerToken">>, Secrets);
        _ -> Secrets
    end,
    Type = maps:get(<<"type">>, Public),
    case Type of
        <<"http">> -> true = maps:get(<<"command">>, Public, null) =:= null, true = maps:get(<<"cwd">>, Public, null) =:= null, true = maps:get(<<"args">>, Public, []) =:= [], true = map_size(object(<<"env">>, Public)) =:= 0;
        <<"stdio">> -> true = maps:get(<<"url">>, Public, null) =:= null, true = maps:get(<<"bearerTokenEnvVar">>, Public, null) =:= null, true = map_size(object(<<"headers">>, Public)) =:= 0, true = map_size(object(<<"headers">>, Secrets2)) =:= 0, true = maps:get(<<"bearerToken">>, Secrets2, null) =:= null
    end,
    case maps:find(<<"startupTimeoutMs">>, Public) of {ok, Millis} -> counter(Millis, 1, 300000); error -> ok end,
    {Public, Secrets2}.

source_choices(_, null) -> #{};
source_choices(Prior, Changes) -> maps:fold(fun
    (K, null, Acc) -> maps:remove(K, Acc);
    (K, Value, Acc) -> fields(Value, [<<"source">>, <<"value">>]), Text = maps:get(<<"value">>, Value), text(Text, 0, 16384),
        Source = case maps:get(<<"source">>, Value) of <<"literal">> -> Text; <<"env">> -> #{<<"env">> => Text} end,
        Acc#{K => Source}
end, Prior, Changes).
secret_choices(_, null) -> #{};
secret_choices(Prior, Changes) -> maps:fold(fun(K, null, Acc) -> maps:remove(K, Acc); (K, V, Acc) -> text(V, 0, 16384), Acc#{K => V} end, Prior, Changes).
boolean_choices(Prior, Changes) -> maps:fold(fun(K, null, Acc) -> maps:remove(K, Acc); (K, V, Acc) when is_boolean(V) -> text(K, 1, 512), Acc#{K => V} end, Prior, Changes).

fields(Map, Allowed) when is_map(Map) -> true = lists:all(fun(K) -> lists:member(K, Allowed) end, maps:keys(Map));
fields(_, _) -> erlang:error(invalid_object).
text(Value, Min, Max) -> true = is_binary(Value) andalso byte_size(Value) >= Min andalso byte_size(Value) =< Max.
nullable_text(null, _) -> ok; nullable_text(Text, Max) -> text(Text, 1, Max).
counter(Value, Min, Max) -> true = is_integer(Value) andalso Value >= Min andalso Value =< Max.
strings(Values, Max, Width) -> true = is_list(Values) andalso length(Values) =< Max, lists:foreach(fun(V) -> text(V, 1, Width) end, Values).
ensure(true, _, _, _) -> ok; ensure(false, Status, Code, Detail) -> refusal(Status, Code, Detail).
refusal(Status, Code, Detail) -> throw({http_settings, {Status, Code, Detail}}).
guarded(Run) -> try Run() catch
    throw:{http_settings, Failure} -> {error, Failure};
    throw:{settings, _} -> {error, {503, <<"settings_unavailable">>, <<"settings could not be published">>}};
    _:_ -> {error, {400, <<"invalid_request">>, <<"invalid settings candidate">>}}
end.

mcp_definitions(Home) -> with_lock(Home, fun() -> guarded(fun() ->
    Ext = albedo_settings_store:read(Home, <<"extensions.json">>),
    Servers = object(<<"servers">>, object(<<"mcp">>, Ext)),
    {ok, lists:sort([{Name, maps:get(<<"enabled">>, Definition, true)} || {Name, Definition} <- maps:to_list(Servers)])}
end) end).

%% Composition depends on these saved groups. Counters retain changes to
%% write-only secrets without exposing secret values or hashes of them.
composition_revision(Home) -> with_lock(Home, fun() -> guarded(fun() ->
    Documents = maps:from_list([{File, albedo_settings_store:read(Home, File)} || File <-
        [<<"extensions.json">>, <<"capabilities.json">>, <<"creds.json">>]]),
    Groups = projection('albedo@daemon@settings_projection':composition_groups(Documents)),
    Revisions = albedo_settings_store:read(Home, <<"settings-revisions.json">>),
    Selected = [{Name, group_etag(Name, group(Name, Groups), Revisions)} ||
        Name <- [<<"extensions">>, <<"mcp">>, <<"capabilities">>]],
    {ok, binary:encode_hex(crypto:hash(sha256, term_to_binary(Selected)), lowercase)}
end) end).


validate_provider_accounts(Docs, Providers, Logins) ->
    Config = saved_config(maps:get(<<"config.json">>, Docs)), Creds = maps:get(<<"creds.json">>, Docs),
    Accounts = object(<<"accounts">>, Creds), Keys = object(<<"providers">>, Creds),
    maps:foreach(fun(Name, Profile) ->
        {ok, Normalized} = 'albedo@daemon@configuration':normalize_profile(Name, Profile),
        Extension = maps:get(<<"extension">>, Normalized),
        ensure(lists:member(Extension, Providers), 400, <<"provider_unknown">>, <<"Provider extension is not installed">>),
        case maps:get(<<"accountId">>, Profile, null) of
            null -> ok;
            Id ->
                Matches = [Login || Login <- Logins, element(2, Login) =:= Extension],
                ensure(lists:any(fun(Login) -> lists:any(fun(Credential) ->
                    maps:get(<<"_albedo_account_id">>, Credential, null) =:= Id
                end, albedo_credentials:values(Accounts, element(6, Login))) end, Matches),
                    400, <<"account_unknown">>, <<"Account does not belong to this provider">>),
                ensure(not maps:is_key(Name, Keys), 400, <<"credential_conflict">>, <<"Clear the API key before selecting an OAuth account">>)
        end
    end, object(<<"providers">>, Config)).

%% Gleam returns native JSON maps so validators retain the existing encoding.
json_null() -> null.

projection({ok, Value}) -> Value;
projection({error, invalid_section}) -> throw({settings, <<"invalid settings section">>});
projection({error, invalid_value}) -> erlang:error(invalid_settings_value).

saved_config(Document) ->
    case 'albedo@daemon@configuration':named_config(Document) of
        {ok, Value} -> Value;
        {error, Reason} -> throw({settings, Reason})
    end.
