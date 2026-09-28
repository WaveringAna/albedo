-module(albedo_models).
%% models.dev catalog cache: bounded fetch, trimmed to the fields lookup reads,
%% parsed once per file revision.

-include_lib("kernel/include/file.hrl").
-export([refresh/3, reload/2, lookup/3, lookup_provider/3, list/3]).

-define(MAX_BYTES, 33554432).
-define(REFRESH_PROCESS, albedo_models_refresh).

%% Every error the shared fetch reports on this cache's behalf keeps this
%% catalog's name, so the wording stays this module's own.
-define(WHAT, <<"models catalog">>).

refresh(Catalog, Url, MaxAgeMs) ->
    albedo_cached_fetch:refresh(Catalog, Url, MaxAgeMs, ?REFRESH_PROCESS,
                                ?WHAT, fun accept/1, fun after_write/1).

reload(Catalog, Url) ->
    albedo_cached_fetch:reload(Catalog, Url, ?WHAT, fun accept/1, fun after_write/1).

accept(Body) when byte_size(Body) =< ?MAX_BYTES ->
    case compact(Body) of
        {ok, Trimmed} -> {ok, Trimmed};
        error -> {error, <<"models catalog response is not valid">>}
    end;
accept(_) ->
    {error, <<"models catalog response is too large">>}.

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

%% Once a catalog is replaced, its parse index and revision cache are stale;
%% both self-heal on the next parse, but dropping them keeps the next lookup
%% from trusting the old revision first.
after_write(Catalog) ->
    _ = persistent_term:erase({?MODULE, Catalog}),
    _ = file:delete(index_path(Catalog)),
    nil.

lookup(Catalog0, Model0, Endpoint0) ->
    Catalog = text(Catalog0),
    Model = unicode:characters_to_binary(Model0),
    Endpoint = unicode:characters_to_binary(Endpoint0),
    try
        case catalog(Catalog) of
            {ok, CatalogData} -> resolve(CatalogData, Model, host(Endpoint));
            Error -> Error
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
            Error -> Error
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
                case albedo_cached_fetch:isolated(?WHAT, fun() -> from_index(Catalog, Revision) end) of
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
    case albedo_credentials:read_json(Catalog) of
        {ok, Decoded} when is_map(Decoded) ->
            {Providers, Index} = maps:fold(fun provider/3, {#{}, #{}}, Decoded),
            CatalogData = #{index => Index, providers => Providers},
            Current = retrim(Catalog, Decoded, Revision),
            save_index(Catalog, Current, CatalogData),
            persistent_term:put({?MODULE, Catalog}, {Current, CatalogData}),
            ok;
        {ok, _} -> {error, <<"models catalog is not a provider object">>};
        {error, invalid} -> {error, <<"models catalog is not valid JSON">>};
        _ -> {error, <<"models catalog could not be read">>}
    end.

%% Best effort: without an index the next start parses the catalog again.
save_index(Catalog, Revision, CatalogData) ->
    _ = albedo_credentials:write(index_path(Catalog),
        term_to_binary({2, Revision, CatalogData}, [{compressed, 1}])),
    ok.

%% A catalog cached before trimming existed is trimmed in place on first parse,
%% keeping its mtime so the refresh schedule is unchanged. Answers the revision
%% the cache entry must carry: the rewritten file's, or the original's when the
%% file is already trimmed or cannot be replaced.
retrim(Catalog, Decoded, {_, Modified} = Revision) ->
    case trimmed(Decoded) of
        true -> Revision;
        false ->
            case albedo_cached_fetch:commit(Catalog, trim(Decoded), ?WHAT, fun after_write/1) of
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
    Efforts = hd([[V || V <- Vals, is_binary(V)]
                  || #{<<"type">> := <<"effort">>, <<"values">> := Vals} <- maps:get(<<"reasoning_options">>, Model, []),
                     is_list(Vals)] ++ [[]]),
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
        Candidates -> {ok, select(Candidates, Providers, Host)}
    end.

%% The configured endpoint decides between providers that publish one model id.
%% Codex subscription models use OpenAI's metadata, even though models.dev
%% does not publish the ChatGPT endpoint (or an API URL for OpenAI). Without a
%% match, the model id alone answers for no provider in particular.
select(Candidates, Providers, <<"chatgpt.com">>) ->
    case [E || {<<"openai">>, _} = E <- Candidates] of
        [Entry | _] -> encode(Entry, Providers, <<"provider identity">>);
        [] -> unattributed(Candidates)
    end;
select(Candidates, Providers, Host) ->
    case [E || {Name, _} = E <- Candidates, Host =/= <<>>,
               element(1, maps:get(Name, Providers)) =:= Host] of
        [Entry | _] -> encode(Entry, Providers, <<"provider endpoint">>);
        [] -> unattributed(Candidates)
    end.

%% A model id served through a gateway the catalog does not list. Its provider,
%% API, and environment would be a guess, so they stay empty. Input kinds and
%% efforts are those every candidate reports, and where candidates disagree
%% on limits the smallest stand: the cost is compacting or capping output a
%% little early, never overrunning the real window.
unattributed(Candidates) ->
    Models = [Model || {_, Model} <- lists:sort(Candidates)],
    {Id, _, _, _, _} = hd(Models),
    Limits = lists:usort([{Context, Output} || {_, Context, Output, _, _} <- Models]),
    Matched = case Limits of
        [_] -> <<"model id">>;
        _ ->
            iolist_to_binary([<<"model id; smallest limits of ">>,
                              integer_to_binary(length(Models)), <<" providers">>])
    end,
    iolist_to_binary(json:encode(#{
        <<"model">> => Id,
        <<"provider">> => <<>>,
        <<"context">> => smallest([C || {_, C, _, _, _} <- Models]),
        <<"output">> => smallest([O || {_, _, O, _, _} <- Models]),
        <<"input_modalities">> => shared([I || {_, _, _, I, _} <- Models]),
        <<"api">> => null,
        <<"env">> => [],
        <<"matched">> => Matched,
        <<"efforts">> => shared([E || {_, _, _, _, E} <- Models])
    })).

smallest(Values) ->
    case [V || V <- Values, is_integer(V), V > 0] of
        [] -> null;
        Known -> lists:min(Known)
    end.

%% What every candidate that reports a list agrees on, in the first one's order.
shared(Lists) ->
    case [L || L <- Lists, L =/= []] of
        [] -> [];
        [First | Rest] -> [V || V <- First, lists:all(fun(L) -> lists:member(V, L) end, Rest)]
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

host(Url) when is_binary(Url), Url =/= <<>> ->
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
            Error -> Error
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
