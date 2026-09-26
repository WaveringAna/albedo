-module(albedo_models).
%% models.dev catalog cache: bounded fetch, trimmed to the fields lookup reads,
%% parsed once per file revision.

-include_lib("kernel/include/file.hrl").
-export([refresh/3, reload/2, lookup/3, lookup_provider/3, list/3]).

-define(MAX_BYTES, 33554432).
-define(FETCH_TIMEOUT_MS, 30000).
-define(REFRESH_PROCESS, albedo_models_refresh).

refresh(Catalog0, Url0, MaxAgeMs) ->
    Catalog = text(Catalog0),
    Url = unicode:characters_to_binary(Url0),
    case stale(Catalog, MaxAgeMs) andalso safe_url(Url) of
        false -> nil;
        true ->
            Pid = spawn(fun() -> fetch(Catalog, Url) end),
            try register(?REFRESH_PROCESS, Pid) of
                true -> nil
            catch
                _:_ ->
                    exit(Pid, kill),
                    nil
            end
    end.

reload(Catalog0, Url0) ->
    Catalog = text(Catalog0),
    Url = unicode:characters_to_binary(Url0),
    try
        case safe_url(Url) of
            true -> isolated(fun() -> fetch(Catalog, Url) end);
            false -> {error, <<"models catalog URL must use https or loopback http">>}
        end
    catch
        _:_ -> {error, <<"models catalog URL is invalid">>}
    end.

stale(Catalog, MaxAgeMs) ->
    case file:read_file_info(Catalog, [{time, posix}]) of
        {ok, #file_info{type = regular, mtime = Modified}} ->
            erlang:system_time(millisecond) - Modified * 1000 > MaxAgeMs;
        _ -> true
    end.

%% https anywhere; plain http only on loopback, which keeps tests local.
safe_url(Url) ->
    Parsed = uri_string:parse(Url),
    Scheme = maps:get(scheme, Parsed, undefined),
    Host = string:lowercase(maps:get(host, Parsed, <<>>)),
    Scheme =:= <<"https">> orelse
        (Scheme =:= <<"http">> andalso
         lists:member(Host, [<<"localhost">>, <<"127.0.0.1">>, <<"::1">>])).

fetch(Catalog, Url) ->
    _ = application:ensure_all_started(inets),
    _ = application:ensure_all_started(ssl),
    Request = {binary_to_list(Url), [{"user-agent", "albedo"}, {"accept", "application/json"}]},
    Options = [{timeout, ?FETCH_TIMEOUT_MS}, {connect_timeout, 10000}, {ssl, tls_options(Url)}],
    case httpc:request(get, Request, Options, [{body_format, binary}]) of
        {ok, {{_, 200, _}, _, Body}} when byte_size(Body) =< ?MAX_BYTES ->
            case compact(Body) of
                {ok, Trimmed} -> store(Catalog, Trimmed);
                error -> {error, <<"models catalog response is not valid">>}
            end;
        {ok, {{_, 200, _}, _, _}} ->
            {error, <<"models catalog response is too large">>};
        {ok, {{_, Status, _}, _, _}} ->
            {error, iolist_to_binary(io_lib:format("models catalog returned HTTP ~B", [Status]))};
        {error, _} ->
            {error, <<"models catalog request failed">>}
    end.

tls_options(Url) ->
    Host = binary_to_list(maps:get(host, uri_string:parse(Url), <<>>)),
    [{verify, verify_peer}, {cacerts, public_key:cacerts_get()}, {depth, 5},
     {server_name_indication, Host},
     {customize_hostname_check, [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}].

%% A valid catalog re-encoded with only what provider/3 and model/1 read. Every
%% provider stays: lookup falls back to matching a model id across all of them,
%% which is how endpoints outside the catalog (codex, proxies) get a capacity.
%% models.dev is about 4.9 MB; the trimmed form is about a quarter of that.
compact(Body) ->
    try json:decode(Body) of
        Providers when is_map(Providers), map_size(Providers) > 0 ->
            case lists:any(fun({_, Provider}) ->
                     is_map(Provider) andalso is_map(maps:get(<<"models">>, Provider, undefined))
                 end, maps:to_list(Providers)) of
                true -> {ok, trim(Providers)};
                false -> error
            end;
        _ -> error
    catch
        _:_ -> error
    end.

trim(Providers) -> iolist_to_binary(json:encode(maps:filtermap(fun trim_provider/2, Providers))).

%% models.dev names every provider; a trimmed catalog never does.
trimmed(Providers) ->
    not lists:any(fun(P) -> is_map(P) andalso is_map_key(<<"name">>, P) end, maps:values(Providers)).

trim_provider(_, Provider) when is_map(Provider) ->
    Models = case maps:get(<<"models">>, Provider, #{}) of
        M when is_map(M) -> maps:filtermap(fun trim_model/2, M);
        _ -> #{}
    end,
    {true, (maps:with([<<"api">>, <<"env">>], Provider))#{<<"models">> => Models}};
trim_provider(_, _) -> false.

trim_model(_, Model) when is_map(Model) ->
    Limit = maps:with([<<"context">>, <<"output">>], field(<<"limit">>, Model)),
    Inputs = maps:with([<<"input">>], field(<<"modalities">>, Model)),
    Reasoning = maps:with([<<"reasoning_options">>], Model),
    Trimmed = maps:merge(maps:with([<<"id">>], Model), Reasoning),
    {true, nonempty(<<"modalities">>, Inputs, nonempty(<<"limit">>, Limit, Trimmed))};
trim_model(_, _) -> false.

nonempty(_, Value, Map) when map_size(Value) =:= 0 -> Map;
nonempty(Key, Value, Map) -> Map#{Key => Value}.

%% Runs Fun in a fresh process so a large decode's garbage dies with it instead
%% of growing the caller's heap for the rest of its life. Fun's result crosses
%% back as an exit reason, so it must be small.
isolated(Fun) ->
    {Pid, Ref} = spawn_monitor(fun() -> exit({done, Fun()}) end),
    receive
        {'DOWN', Ref, process, Pid, {done, Result}} -> Result;
        {'DOWN', Ref, process, Pid, _} -> {error, <<"models catalog could not be read">>}
    end.

%% A partly written catalog must never be readable, so the rename is the commit.
store(Catalog, Body) ->
    Temporary = Catalog ++ ".fetch." ++ integer_to_list(erlang:unique_integer([positive])),
    _ = filelib:ensure_dir(Catalog),
    case file:write_file(Temporary, Body) of
        ok ->
            case file:rename(Temporary, Catalog) of
                ok ->
                    _ = persistent_term:erase({?MODULE, Catalog}),
                    _ = file:delete(index_path(Catalog)),
                    {ok, nil};
                _ ->
                    _ = file:delete(Temporary),
                    {error, <<"models catalog cache could not be replaced">>}
            end;
        _ -> {error, <<"models catalog cache could not be written">>}
    end.

lookup(Catalog0, Model0, Endpoint0) ->
    Catalog = text(Catalog0),
    Model = unicode:characters_to_binary(Model0),
    Endpoint = unicode:characters_to_binary(Endpoint0),
    try
        case catalog(Catalog) of
            {ok, CatalogData} -> resolve(CatalogData, Model, host(Endpoint));
            {error, Reason} -> {error, Reason}
        end
    catch
        _:_ -> {error, <<"models catalog lookup failed">>}
    end.

%% A provider-owned transport must not borrow another provider's metadata
%% when a shared model id has a different context or output limit.
lookup_provider(Catalog0, Provider0, Model0) ->
    Catalog = text(Catalog0),
    Provider = unicode:characters_to_binary(Provider0),
    Model = unicode:characters_to_binary(Model0),
    try
        case catalog(Catalog) of
            {ok, #{index := Index, providers := Providers}} ->
                case [E || {Name, _} = E <- maps:get(Model, Index, []), Name =:= Provider] of
                    [Entry | _] -> {ok, encode(Entry, Providers, <<"provider name">>)};
                    [] -> {error, <<"model is not listed by this provider">>}
                end;
            {error, Reason} -> {error, Reason}
        end
    catch
        _:_ -> {error, <<"models catalog lookup failed">>}
    end.

%% Parsing 4 MiB per request would be wasteful, so a file revision is parsed once.
catalog(Catalog) ->
    case file:read_file_info(Catalog, [{time, posix}]) of
        {ok, #file_info{type = regular, size = Size, mtime = Modified}} when Size =< ?MAX_BYTES ->
            Revision = {Size, Modified},
            case persistent_term:get({?MODULE, Catalog}, undefined) of
                {Revision, Index} -> {ok, Index};
                _ -> load(Catalog, Revision)
            end;
        {ok, _} -> {error, <<"models catalog is too large">>};
        _ -> {error, <<"no models catalog is cached">>}
    end.

%% persistent_term pins the cached value for the VM lifetime and each replacement
%% costs a global GC pass, so the decoded JSON is reduced to the fields lookup and
%% list read. Index entries name their provider instead of embedding it: embedded
%% provider maps are shared on the heap but expand to over a gigabyte when copied.
%%
%% Sessions start turns together, so a missing revision is parsed by one caller
%% while the rest wait on the lock and then read its result.
load(Catalog, Revision) ->
    global:trans({{?MODULE, Catalog}, self()}, fun() ->
        case persistent_term:get({?MODULE, Catalog}, undefined) of
            {Revision, Index} -> {ok, Index};
            _ ->
                case isolated(fun() -> from_index(Catalog, Revision) end) of
                    ok -> {ok, element(2, persistent_term:get({?MODULE, Catalog}))};
                    Error -> Error
                end
        end
    end, [node()]).

%% The reduced index of the current revision, saved beside the catalog, loads
%% straight into its final shape; decoding the JSON takes several times more
%% memory than the index it produces. A missing or stale index is rebuilt.
from_index(Catalog, Revision) ->
    case file:read_file(index_path(Catalog)) of
        {ok, Bytes} ->
            try binary_to_term(Bytes, [safe]) of
                {2, Revision, #{index := I, providers := P} = CatalogData} when is_map(I), is_map(P) ->
                    persistent_term:put({?MODULE, Catalog}, {Revision, CatalogData}),
                    ok;
                _ -> parse(Catalog, Revision)
            catch
                _:_ -> parse(Catalog, Revision)
            end;
        _ -> parse(Catalog, Revision)
    end.

index_path(Catalog) -> Catalog ++ ".index".

parse(Catalog, Revision) ->
    case file:read_file(Catalog) of
        {ok, Body} ->
            try json:decode(Body) of
                Decoded when is_map(Decoded) ->
                    {Providers, Index} = maps:fold(fun provider/3, {#{}, #{}}, Decoded),
                    CatalogData = #{index => Index, providers => Providers},
                    Current = retrim(Catalog, Decoded, Revision),
                    save_index(Catalog, Current, CatalogData),
                    persistent_term:put({?MODULE, Catalog}, {Current, CatalogData}),
                    ok;
                _ -> {error, <<"models catalog is not a provider object">>}
            catch
                _:_ -> {error, <<"models catalog is not valid JSON">>}
            end;
        _ -> {error, <<"models catalog could not be read">>}
    end.

%% Best effort: without an index the next start parses the catalog again.
save_index(Catalog, Revision, CatalogData) ->
    Path = index_path(Catalog),
    Temporary = Path ++ "." ++ integer_to_list(erlang:unique_integer([positive])),
    case file:write_file(Temporary, term_to_binary({2, Revision, CatalogData}, [{compressed, 1}])) of
        ok ->
            case file:rename(Temporary, Path) of
                ok -> ok;
                _ -> file:delete(Temporary)
            end;
        _ -> file:delete(Temporary)
    end.

%% A catalog cached before trimming existed is trimmed in place on first parse,
%% keeping its mtime so the refresh schedule is unchanged. Answers the revision
%% the cache entry must carry: the rewritten file's, or the original's when the
%% file is already trimmed or cannot be replaced.
retrim(Catalog, Decoded, {_, Modified} = Revision) ->
    case trimmed(Decoded) of
        true -> Revision;
        false ->
            case store(Catalog, trim(Decoded)) of
                {ok, nil} ->
                    _ = file:write_file_info(Catalog, #file_info{mtime = Modified}, [{time, posix}]),
                    case file:read_file_info(Catalog, [{time, posix}]) of
                        {ok, #file_info{size = Size, mtime = Mtime}} -> {Size, Mtime};
                        _ -> Revision
                    end;
                _ -> Revision
            end
    end.

%% Provider: {Host, Api, Env, SortedModelIds}. Model: {Id, Context, Output, Inputs}.
provider(Name, Provider, {Providers, Index}) when is_binary(Name), is_map(Provider) ->
    Models = case maps:get(<<"models">>, Provider, #{}) of
        M when is_map(M) -> maps:to_list(M);
        _ -> []
    end,
    Api = maps:get(<<"api">>, Provider, null),
    Ids = lists:usort([Id || {Key, Model} <- Models, Id <- [model_id(Key, Model)], Id =/= <<>>]),
    Updated = lists:foldl(fun({Key, Model}, Acc) when is_binary(Key) ->
                              add(Acc, Key, {Name, model(Model)});
                             (_, Acc) -> Acc
                          end, Index, Models),
    {Providers#{Name => {host(Api), Api, strings(maps:get(<<"env">>, Provider, [])), Ids}}, Updated};
provider(_, _, Acc) -> Acc.

model_id(_, #{<<"id">> := Id}) when is_binary(Id), Id =/= <<>> -> Id;
model_id(Key, _) when is_binary(Key) -> Key;
model_id(_, _) -> <<>>.

model(Model) when is_map(Model) ->
    Limit = field(<<"limit">>, Model),
    Id = case maps:get(<<"id">>, Model, <<>>) of I when is_binary(I) -> I; _ -> <<>> end,
    Efforts = case maps:get(<<"reasoning_options">>, Model, []) of
        Opts when is_list(Opts) ->
            lists:foldl(fun(#{<<"type">> := <<"effort">>, <<"values">> := Vals}, _) when is_list(Vals) ->
                            [V || V <- Vals, is_binary(V)];
                           (_, Acc) -> Acc
                        end, [], Opts);
        _ -> []
    end,
    {Id, maps:get(<<"context">>, Limit, null), maps:get(<<"output">>, Limit, null),
     strings(maps:get(<<"input">>, field(<<"modalities">>, Model), [])),
     Efforts};
model(_) -> {<<>>, null, null, [], []}.

field(Key, Map) ->
    case maps:get(Key, Map, #{}) of
        Value when is_map(Value) -> Value;
        _ -> #{}
    end.

%% A catalog key may be qualified ("vendor/model"), so both spellings resolve.
add(Index, Key, Entry) ->
    Keys = [Key | case binary:split(Key, <<"/">>, [global]) of
        [_] -> [];
        Parts -> [lists:last(Parts)]
    end],
    lists:foldl(fun(K, Acc) -> maps:update_with(K, fun(V) -> [Entry | V] end, [Entry], Acc) end,
                Index, Keys).

resolve(#{index := Index, providers := Providers}, Model, Host) ->
    case maps:get(Model, Index, []) of
        [] -> {error, <<"model is not in the cached catalog">>};
        Candidates ->
            case select(Candidates, Providers, Host) of
                {ok, Entry, Matched} -> {ok, encode(Entry, Providers, Matched)};
                error -> {error, <<"model id is ambiguous across catalog providers">>}
            end
    end.

%% The configured endpoint decides between providers that publish one model id.
%% Without a host match, agreeing candidates still answer and conflicting ones do not.
%% Codex subscription models use OpenAI's metadata, even though models.dev
%% does not publish the ChatGPT endpoint (or an API URL for OpenAI).
select(Candidates, _Providers, <<"chatgpt.com">>) ->
    case [E || {<<"openai">>, _} = E <- Candidates] of
        [Entry | _] -> {ok, Entry, <<"provider identity">>};
        [] -> error
    end;
select(Candidates, Providers, Host) ->
    case [E || {Name, _} = E <- Candidates, Host =/= <<>>,
               element(1, maps:get(Name, Providers)) =:= Host] of
        [Entry | _] -> {ok, Entry, <<"provider endpoint">>};
        [] ->
            case lists:usort([{Context, Output} || {_, {_, Context, Output, _, _}} <- Candidates]) of
                [_] -> {ok, hd(lists:sort(Candidates)), <<"model id">>};
                _ -> error
            end
    end.

encode({Name, {Id, Context, Output, Inputs, Efforts}}, Providers, Matched) ->
    {_, Api, Env, _} = maps:get(Name, Providers),
    iolist_to_binary(json:encode(#{
        <<"model">> => Id,
        <<"provider">> => Name,
        <<"context">> => integer_or_null(Context),
        <<"output">> => integer_or_null(Output),
        <<"input_modalities">> => Inputs,
        <<"api">> => Api,
        <<"env">> => Env,
        <<"matched">> => Matched,
        <<"efforts">> => Efforts
    })).

integer_or_null(Value) when is_integer(Value), Value > 0 -> Value;
integer_or_null(_) -> null.

strings(Values) when is_list(Values) -> [V || V <- Values, is_binary(V)];
strings(_) -> [].

host(null) -> <<>>;
host(<<>>) -> <<>>;
host(Url) when is_binary(Url) ->
    case uri_string:parse(Url) of
        #{host := Host} -> string:lowercase(Host);
        _ -> <<>>
    end;
host(_) -> <<>>.

list(Catalog0, Provider0, Endpoint0) ->
    Catalog = text(Catalog0),
    Provider = unicode:characters_to_binary(Provider0),
    Endpoint = unicode:characters_to_binary(Endpoint0),
    try
        case catalog(Catalog) of
            {ok, CatalogData} -> list_provider(maps:get(providers, CatalogData), Provider, host(Endpoint));
            {error, Reason} -> {error, Reason}
        end
    catch
        _:_ -> {error, <<"models catalog listing failed">>}
    end.

list_provider(Providers, Provider, EndpointHost) ->
    Candidate = case find_provider(maps:values(Providers), EndpointHost) of
        undefined -> maps:get(Provider, Providers, undefined);
        Found -> Found
    end,
    case Candidate of
        {_, _, _, Ids} -> {ok, iolist_to_binary(json:encode(Ids))};
        _ -> {error, <<"provider is not in the cached catalog">>}
    end.

find_provider(_, <<>>) -> undefined;
find_provider(Providers, EndpointHost) ->
    case [P || {Host, _, _, _} = P <- Providers, Host =:= EndpointHost] of
        [Provider | _] -> Provider;
        [] -> undefined
    end.

text(Value) -> unicode:characters_to_list(Value).
