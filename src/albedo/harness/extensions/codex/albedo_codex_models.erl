%% The Codex model list from the ChatGPT backend itself, cached per account in
%% $ALBEDO_HOME/codex-models.json. The backend shows a model only to clients at
%% or past its minimal client version, so requests claim the latest released
%% Codex CLI version, read from npm; a model OpenAI releases to Codex reaches
%% albedo without an albedo update.
-module(albedo_codex_models).
-export([refresh/5, refresh_async/5, read/1]).

-define(MODELS_URL, "https://chatgpt.com/backend-api/codex/models").
-define(VERSION_URL, "https://registry.npmjs.org/@openai/codex/latest").
%% Used only before npm has ever answered: a released Codex CLI version.
-define(FALLBACK_VERSION, <<"0.157.1">>).
-define(VERSION_MAX_AGE_MS, 86400000).
-define(TIMEOUT_MS, 20000).
-define(MAX_BYTES, 8388608).

%% Refreshes one account's list when it is older than MaxAgeMs. The cached
%% list stays when the backend or npm cannot be reached.
refresh(Home0, Access0, Account0, MaxAgeMs, Now) ->
    Home = text(Home0),
    Access = unicode:characters_to_binary(Access0),
    Account = unicode:characters_to_binary(Account0),
    try
        Cache = load(Home),
        Accounts = maps:get(<<"accounts">>, Cache, #{}),
        Entry = maps:get(Account, Accounts, #{}),
        {Version, Cache1} = version(Cache, Now),
        Fresh = Now - maps:get(<<"fetchedAt">>, Entry, 0) < MaxAgeMs
            andalso maps:get(<<"clientVersion">>, Entry, <<>>) =:= Version,
        case Fresh of
            true -> {ok, nil};
            false ->
                case fetch_models(Access, Account, Version, Entry) of
                    {ok, Updated} ->
                        store(Home, Cache1#{<<"accounts">> => Accounts#{
                            Account => Updated#{<<"fetchedAt">> => Now,
                                                <<"clientVersion">> => Version}}});
                    {error, Reason} ->
                        _ = store(Home, Cache1),
                        {error, Reason}
                end
        end
    catch
        _:_ -> {error, <<"Codex model list could not be refreshed">>}
    end.

%% The same refresh off the caller's process, one per account at a time, for
%% paths that must not wait on the network.
refresh_async(Home, Access, Account, MaxAgeMs, Now) ->
    Name = list_to_atom("albedo_codex_models_" ++ integer_to_list(erlang:phash2(Account))),
    Pid = spawn(fun() ->
        receive go -> refresh(Home, Access, Account, MaxAgeMs, Now) end
    end),
    try register(Name, Pid) of
        true -> Pid ! go, nil
    catch
        _:_ -> exit(Pid, kill), nil
    end.

%% The cache as JSON text for the Gleam decoder.
read(Home0) ->
    case file:read_file(filename:join(text(Home0), "codex-models.json")) of
        {ok, Bytes} -> {ok, Bytes};
        _ -> {error, nil}
    end.

version(Cache, Now) ->
    Cached = maps:get(<<"clientVersion">>, Cache, <<>>),
    Checked = maps:get(<<"versionCheckedAt">>, Cache, 0),
    case Cached =/= <<>> andalso Now - Checked < ?VERSION_MAX_AGE_MS of
        true -> {Cached, Cache};
        false ->
            case fetch_version() of
                {ok, Version} ->
                    {Version, Cache#{<<"clientVersion">> => Version,
                                     <<"versionCheckedAt">> => Now}};
                error when Cached =/= <<>> -> {Cached, Cache};
                error -> {?FALLBACK_VERSION, Cache}
            end
    end.

fetch_version() ->
    case get(?VERSION_URL, [{"accept", "application/json"}]) of
        {ok, 200, _, Body} ->
            case json:decode(Body) of
                #{<<"version">> := Version} when is_binary(Version) ->
                    case re:run(Version, <<"^[0-9]+\\.[0-9]+\\.[0-9]+$">>) of
                        {match, _} -> {ok, Version};
                        nomatch -> error
                    end;
                _ -> error
            end;
        _ -> error
    end.

fetch_models(Access, Account, Version, Entry) ->
    Url = ?MODELS_URL ++ "?client_version=" ++ binary_to_list(Version),
    Etag = case maps:get(<<"clientVersion">>, Entry, <<>>) of
        Version -> maps:get(<<"etag">>, Entry, <<>>);
        _ -> <<>>
    end,
    Headers = [{"authorization", "Bearer " ++ binary_to_list(Access)},
               {"chatgpt-account-id", binary_to_list(Account)},
               {"originator", "albedo"},
               {"version", binary_to_list(Version)},
               {"accept", "application/json"}]
        ++ [{"if-none-match", binary_to_list(Etag)} || Etag =/= <<>>],
    case get(Url, Headers) of
        {ok, 304, _, _} -> {ok, Entry};
        {ok, 200, ResponseHeaders, Body} ->
            case json:decode(Body) of
                #{<<"models">> := Models} when is_list(Models) ->
                    {ok, #{<<"etag">> => header("etag", ResponseHeaders),
                           <<"models">> => [M || Raw <- Models, M <- [trim(Raw)], M =/= skip]}};
                _ -> {error, <<"Codex model list is not valid">>}
            end;
        {ok, Status, _, _} ->
            {error, iolist_to_binary(io_lib:format("Codex model list returned HTTP ~B", [Status]))};
        error -> {error, <<"Codex model list request failed">>}
    end.

%% Only what lookup and listing read.
trim(#{<<"slug">> := Slug} = Model) when is_binary(Slug), Slug =/= <<>> ->
    Levels = [E || #{<<"effort">> := E} <- list(maps:get(<<"supported_reasoning_levels">>, Model, [])),
                   is_binary(E)],
    #{<<"slug">> => Slug,
      <<"name">> => binary_or(maps:get(<<"display_name">>, Model, Slug), Slug),
      <<"context">> => positive(maps:get(<<"context_window">>, Model, null)),
      <<"maxContext">> => positive(maps:get(<<"max_context_window">>, Model, null)),
      <<"input">> => [I || I <- list(maps:get(<<"input_modalities">>, Model, [])), is_binary(I)],
      <<"efforts">> => Levels,
      <<"visible">> => maps:get(<<"visibility">>, Model, <<"list">>) =:= <<"list">>,
      <<"priority">> => case maps:get(<<"priority">>, Model, null) of
                            P when is_integer(P) -> P;
                            _ -> 1000000
                        end};
trim(_) -> skip.

get(Url, Headers) ->
    _ = application:ensure_all_started(inets),
    _ = application:ensure_all_started(ssl),
    Options = [{timeout, ?TIMEOUT_MS}, {connect_timeout, 10000}, {ssl, tls_options(Url)}],
    case httpc:request(get, {Url, [{"user-agent", "albedo"} | Headers]}, Options,
                       [{body_format, binary}]) of
        {ok, {{_, Status, _}, ResponseHeaders, Body}} when byte_size(Body) =< ?MAX_BYTES ->
            {ok, Status, ResponseHeaders, Body};
        _ -> error
    end.

tls_options(Url) ->
    Host = binary_to_list(maps:get(host, uri_string:parse(list_to_binary(Url)), <<>>)),
    [{verify, verify_peer}, {cacerts, public_key:cacerts_get()}, {depth, 5},
     {server_name_indication, Host},
     {customize_hostname_check, [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}].

header(Name, Headers) ->
    case lists:keyfind(Name, 1, Headers) of
        {_, Value} -> unicode:characters_to_binary(Value);
        false -> <<>>
    end.

load(Home) ->
    case file:read_file(filename:join(Home, "codex-models.json")) of
        {ok, Bytes} ->
            try json:decode(Bytes) of
                Map when is_map(Map) -> Map;
                _ -> #{}
            catch
                _:_ -> #{}
            end;
        _ -> #{}
    end.

store(Home, Cache) ->
    Path = filename:join(Home, "codex-models.json"),
    Temporary = Path ++ ".tmp." ++ integer_to_list(erlang:unique_integer([positive])),
    ok = filelib:ensure_dir(Path),
    case file:write_file(Temporary, json:encode(Cache)) of
        ok ->
            case file:rename(Temporary, Path) of
                ok -> {ok, nil};
                _ -> _ = file:delete(Temporary), {error, <<"Codex model cache could not be written">>}
            end;
        _ -> {error, <<"Codex model cache could not be written">>}
    end.

positive(N) when is_integer(N), N > 0 -> N;
positive(_) -> null.

list(L) when is_list(L) -> L;
list(_) -> [].

binary_or(B, _) when is_binary(B), B =/= <<>> -> B;
binary_or(_, Default) -> Default.

text(Value) when is_binary(Value) -> binary_to_list(Value);
text(Value) -> Value.
