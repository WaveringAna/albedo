-module(albedo_models).
%% models.dev catalog cache: bounded fetch, parsed once per file revision.

-include_lib("kernel/include/file.hrl").
-export([refresh/3, reload/2, lookup/3, list/3]).

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
            true -> fetch(Catalog, Url);
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
            case valid_catalog(Body) of
                true -> store(Catalog, Body);
                false -> {error, <<"models catalog response is not valid">>}
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

valid_catalog(Body) ->
    try json:decode(Body) of
        Providers when is_map(Providers), map_size(Providers) > 0 ->
            lists:any(fun({_, Provider}) ->
                is_map(Provider) andalso is_map(maps:get(<<"models">>, Provider, undefined))
            end, maps:to_list(Providers));
        _ -> false
    catch
        _:_ -> false
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
            {ok, CatalogData} -> resolve(maps:get(index, CatalogData), Model, host(Endpoint));
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
                _ -> parse(Catalog, Revision)
            end;
        {ok, _} -> {error, <<"models catalog is too large">>};
        _ -> {error, <<"no models catalog is cached">>}
    end.

parse(Catalog, Revision) ->
    case file:read_file(Catalog) of
        {ok, Body} ->
            try json:decode(Body) of
                Providers when is_map(Providers) ->
                    CatalogData = #{index => index(maps:to_list(Providers), #{}), providers => Providers},
                    persistent_term:put({?MODULE, Catalog}, {Revision, CatalogData}),
                    {ok, CatalogData};
                _ -> {error, <<"models catalog is not a provider object">>}
            catch
                _:_ -> {error, <<"models catalog is not valid JSON">>}
            end;
        _ -> {error, <<"models catalog could not be read">>}
    end.

index([], Index) -> Index;
index([{Name, Provider} | Rest], Index) when is_binary(Name), is_map(Provider) ->
    Models = maps:get(<<"models">>, Provider, #{}),
    Updated = case is_map(Models) of
        true -> maps:fold(fun(Key, Model, Acc) ->
                    add(Acc, Key, {Name, Provider, Model})
                end, Index, Models);
        false -> Index
    end,
    index(Rest, Updated);
index([_ | Rest], Index) -> index(Rest, Index).

%% A catalog key may be qualified ("vendor/model"), so both spellings resolve.
add(Index, Key, Entry) ->
    Keys = [Key | case binary:split(Key, <<"/">>, [global]) of
        [_] -> [];
        Parts -> [lists:last(Parts)]
    end],
    lists:foldl(fun(K, Acc) -> maps:update_with(K, fun(V) -> [Entry | V] end, [Entry], Acc) end,
                Index, Keys).

resolve(Index, Model, Host) ->
    case maps:get(Model, Index, []) of
        [] -> {error, <<"model is not in the cached catalog">>};
        Candidates ->
            case select(Candidates, Host) of
                {ok, Entry, Matched} -> {ok, encode(Entry, Matched)};
                error -> {error, <<"model id is ambiguous across catalog providers">>}
            end
    end.

%% The configured endpoint decides between providers that publish one model id.
%% Without a host match, agreeing candidates still answer and conflicting ones do not.
select(Candidates, Host) ->
    case [E || {_, Provider, _} = E <- Candidates, Host =/= <<>>, host(api(Provider)) =:= Host] of
        [Entry | _] -> {ok, Entry, <<"provider endpoint">>};
        [] ->
            case lists:usort([limits(Model) || {_, _, Model} <- Candidates]) of
                [_] -> {ok, hd(lists:sort(Candidates)), <<"model id">>};
                _ -> error
            end
    end.

limits(Model) ->
    Limit = maps:get(<<"limit">>, Model, #{}),
    {maps:get(<<"context">>, Limit, null), maps:get(<<"output">>, Limit, null)}.

encode({Name, Provider, Model}, Matched) ->
    Limit = maps:get(<<"limit">>, Model, #{}),
    Modalities = maps:get(<<"modalities">>, Model, #{}),
    iolist_to_binary(json:encode(#{
        <<"model">> => maps:get(<<"id">>, Model, <<>>),
        <<"provider">> => Name,
        <<"context">> => integer_or_null(maps:get(<<"context">>, Limit, null)),
        <<"output">> => integer_or_null(maps:get(<<"output">>, Limit, null)),
        <<"input_modalities">> => strings(maps:get(<<"input">>, Modalities, [])),
        <<"api">> => api(Provider),
        <<"env">> => strings(maps:get(<<"env">>, Provider, [])),
        <<"matched">> => Matched
    })).

api(Provider) -> maps:get(<<"api">>, Provider, null).

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
        Value when is_map(Value) -> Value;
        _ -> maps:get(Provider, Providers, undefined)
    end,
    case Candidate of
        CandidateMap when is_map(CandidateMap) ->
            Models = maps:get(<<"models">>, CandidateMap, #{}),
            Names = case is_map(Models) of
                true -> maps:fold(fun(Key, Model, Acc) ->
                    Id = case Model of
                        #{<<"id">> := ModelId} when is_binary(ModelId), ModelId =/= <<>> -> ModelId;
                        _ -> Key
                    end,
                    case is_binary(Id) andalso Id =/= <<>> of true -> [Id | Acc]; false -> Acc end
                end, [], Models);
                false -> []
            end,
            {ok, iolist_to_binary(json:encode(lists:usort(Names)))};
        _ -> {error, <<"provider is not in the cached catalog">>}
    end.

find_provider(_, <<>>) -> undefined;
find_provider(Providers, EndpointHost) ->
    case [P || P <- Providers, is_map(P), host(api(P)) =:= EndpointHost] of
        [Provider | _] -> Provider;
        [] -> undefined
    end.

text(Value) -> unicode:characters_to_list(Value).
