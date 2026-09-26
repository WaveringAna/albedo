-module(albedo_claude_files).
%% Anthropic Files API upload cache in <home>/claude-files.json.
%% Failures and provider rejections fall back to inline base64.
-export([ensure/5, file_source/3, reject/3, upload/4, delete/3]).

-define(VERSION, <<"2023-06-01">>).
-define(BETA, <<"files-api-2025-04-14">>).
-define(TIMEOUT_MS, 30000).
%% Bounded to stay well within Anthropic's ~500/min per-org Files API budget.
-define(CONCURRENCY, 4).

%% Upload and cache missing images in Request. Failures fall back inline.
ensure(Home, Access, Account, Endpoint, {request, _, _, Input, _, _, _}) ->
    try
        Cache = maps:filter(fun(_, Entry) -> not expired(Entry) end,
                            account_cache(Home, Account)),
        Cache1 = case quarantined(Account) orelse Access =:= <<>> of
            true -> Cache;
            false -> upload_all(Endpoint, Access, missing(Input, Cache), Cache)
        end,
        save(Home, Account, Cache1, Cache1 =/= Cache)
    catch _:_ -> nil
    end,
    nil.

missing(Input, Cache) ->
    missing([Image || Item <- Input, Image <- input_images(Item)], Cache, #{}).

missing([{image, Mime, Data, _, _, _} = Image | Rest], Cache, Seen) ->
    Key = image_key(Data),
    case maps:is_key(Key, Cache) orelse maps:is_key(Key, Seen) of
        true -> missing(Rest, Cache, Seen);
        false -> [{Key, Mime, Data} | missing(Rest, Cache, Seen#{Key => Image})]
    end;
missing([], _, _) -> [].

upload_all(_Endpoint, _Access, [], Cache) -> Cache;
upload_all(Endpoint, Access, Missing, Cache) ->
    Entries = parallel(fun({Key, Mime, Data}) ->
        case image_bytes(Data) of
            {ok, Bytes} -> {Key, upload(Endpoint, Access, Mime, Bytes)};
            error -> {Key, {error, nil}}
        end
    end, Missing),
    lists:foldl(fun
        ({Key, {ok, Entry}}, Acc) -> Acc#{Key => Entry};
        ({_, {error, _}}, Acc) -> Acc
    end, Cache, Entries).

%% Runs F over Items at most ?CONCURRENCY at once; monitored, so a worker
%% that dies mid-claim turns its items into inline fallbacks instead of a hang.
parallel(F, Items) ->
    Parent = self(),
    Ref = make_ref(),
    Count = length(Items),
    Tuple = list_to_tuple(Items),
    Claim = atomics:new(1, [{signed, false}]),
    Loop = fun Worker() ->
        case atomics:add_get(Claim, 1, 1) of
            Index when Index =< Count ->
                Parent ! {Ref, Index, safe(F, element(Index, Tuple))},
                Worker();
            _ -> stop
        end
    end,
    Monitors = [erlang:monitor(process, Pid)
                || Pid <- [spawn(fun() -> Loop() end)
                           || _ <- lists:seq(1, min(?CONCURRENCY, Count))]],
    collect(Ref, Monitors, Count, Count, []).

safe(F, Item) ->
    try F(Item) of Result -> Result catch _:_ -> {error, nil} end.

collect(_, _, _, 0, Acc) ->
    [Value || {_, Value} <- lists:sort(Acc)];
collect(Ref, Monitors, Count, Left, Acc) ->
    receive
        {Ref, Index, Value} ->
            collect(Ref, Monitors, Count, Left - 1, [{Index, Value} | Acc]);
        {'DOWN', MRef, process, _, _} ->
            case lists:delete(MRef, Monitors) of
                [] ->
                    %% A dead worker's claimed items never arrive.
                    Filled = [{Index, {error, nil}}
                              || Index <- lists:seq(1, Count),
                                 not lists:keymember(Index, 1, Acc)],
                    [Value || {_, Value} <- lists:sort(lists:append(Acc, Filled))];
                Remaining ->
                    collect(Ref, Remaining, Count, Left, Acc)
            end
    end.

input_images({user_image, _, Image}) -> [Image];
input_images({tool_output, _, _, Images}) -> Images;
input_images(_) -> [].

%% Content key is sha256 of base64 text, matching stored_data's hash.
image_key({inline_data, Base64}) ->
    binary:encode_hex(crypto:hash(sha256, Base64), lowercase);
image_key({stored_data, Hash, _, _}) -> Hash.

image_bytes({inline_data, Base64}) -> {ok, base64:decode(Base64)};
image_bytes({stored_data, _, _, Read}) ->
    case Read() of
        {ok, Payload} -> {ok, base64:decode(Payload)};
        _ -> error
    end.

%% Emits a Claude file block for a cached image, or error to fall back inline.
file_source(Home, Account, Data) ->
    try
        case quarantined(Account) of
            true -> {error, nil};
            false ->
                Key = image_key(Data),
                case account_cache(Home, Account) of
                    #{Key := #{<<"id">> := Id} = Entry} ->
                        case expired(Entry) of
                            true -> {error, nil};
                            false -> {ok, [<<"{\"type\":\"file\",\"file_id\":">>,
                                           json:encode_binary(Id), <<"}">>]}
                        end;
                    _ -> {error, nil}
                end
        end
    catch _:_ -> {error, nil}
    end.

%% Quarantines the account and purges handles on 4xx file errors so turns heal inline.
reject(Home, Account, Body) ->
    try
        Text = unicode:characters_to_binary(Body),
        Named = binary:match(Text, <<"file_id">>) =/= nomatch,
        Quoted = binary:match(Text, <<"file_0">>) =/= nomatch,
        case Named orelse Quoted of
            true ->
                put({?MODULE, quarantined, Account}, true),
                save(Home, Account, #{}, true);
            false -> nil
        end
    catch _:_ -> nil
    end,
    nil.

upload(Endpoint, Access, Mime, Bytes) ->
    _ = application:ensure_all_started(inets),
    _ = application:ensure_all_started(ssl),
    Url = <<(unicode:characters_to_binary(Endpoint))/binary, "/v1/files">>,
    Boundary = <<"albedo-", (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    Part = [<<"--">>, Boundary,
            <<"\r\ncontent-disposition: form-data; name=\"file\"; filename=\"">>,
            filename(Mime), <<"\"\r\ncontent-type: ">>, Mime, <<"\r\n\r\n">>,
            Bytes, <<"\r\n--">>, Boundary, <<"--\r\n">>],
    Request = {Url,
               [{"authorization", "Bearer " ++ unicode:characters_to_list(Access)},
                {"anthropic-version", binary_to_list(?VERSION)},
                {"anthropic-beta", binary_to_list(?BETA)},
                {"accept", "application/json"}],
               "multipart/form-data; boundary=" ++ binary_to_list(Boundary),
               iolist_to_binary(Part)},
    Options = [{timeout, ?TIMEOUT_MS}, {connect_timeout, 10000} | tls(Url)],
    case httpc:request(post, Request, Options, [{body_format, binary}]) of
        {ok, {{_, 200, _}, _, Response}} ->
            case metadata(Response, byte_size(Bytes)) of
                {ok, Entry} -> {ok, Entry};
                error -> {error, <<"Anthropic file upload returned invalid metadata">>}
            end;
        {ok, {{_, Status, _}, _, Response}} ->
            Detail = binary:part(Response, 0, min(byte_size(Response), 2048)),
            {error, iolist_to_binary(io_lib:format("Anthropic file upload failed (~B): ~s",
                                                   [Status, Detail]))};
        _ -> {error, <<"Anthropic file upload failed">>}
    end.

delete(Endpoint, Access, Id) ->
    _ = application:ensure_all_started(inets),
    _ = application:ensure_all_started(ssl),
    Url = <<(unicode:characters_to_binary(Endpoint))/binary, "/v1/files/", Id/binary>>,
    Request = {Url,
               [{"authorization", "Bearer " ++ unicode:characters_to_list(Access)},
                {"anthropic-version", binary_to_list(?VERSION)},
                {"anthropic-beta", binary_to_list(?BETA)}]},
    Options = [{timeout, ?TIMEOUT_MS}, {connect_timeout, 10000} | tls(Url)],
    _ = httpc:request(delete, Request, Options, [{body_format, binary}]),
    nil.

tls(Url) ->
    case string:prefix(unicode:characters_to_list(Url), "https") of
        nomatch -> [];
        _ -> [{ssl, albedo_credentials:tls_options(host_of(Url))}]
    end.

host_of(Url) ->
    try maps:get(host, uri_string:parse(unicode:characters_to_list(Url))) of
        Host -> Host
    catch _:_ -> "api.anthropic.com"
    end.

filename(<<"image/jpeg">>) -> <<"image.jpg">>;
filename(<<"image/webp">>) -> <<"image.webp">>;
filename(_) -> <<"image.png">>.

metadata(Response, Size) ->
    try
        case json:decode(Response) of
            #{<<"id">> := Id} = Decoded when is_binary(Id), byte_size(Id) > 0 ->
                Entry = #{<<"id">> => Id, <<"bytes">> => Size},
                {ok, case maps:get(<<"expires_at">>, Decoded, null) of
                    Stamp when is_binary(Stamp) -> Entry#{<<"expires_at">> => rfc3339_ms(Stamp)};
                    _ -> Entry
                end};
            _ -> error
        end
    catch _:_ -> error end.

rfc3339_ms(Stamp) ->
    try calendar:rfc3339_to_system_time(binary_to_list(Stamp), [{unit, millisecond}])
    catch _:_ -> 0 end.

expired(#{<<"expires_at">> := At}) -> is_integer(At) andalso At =/= 0 andalso
    At =< erlang:system_time(millisecond);
expired(_) -> false.

account_cache(Home, Account) ->
    maps:get(Account, state(Home), #{}).

save(Home, Account, Cache, true) ->
    State = maps:put(Account, Cache, reload(Home)),
    put({?MODULE, Home}, State),
    Temporary = path(Home) ++ ".write." ++ integer_to_list(erlang:unique_integer([positive])),
    _ = filelib:ensure_dir(path(Home)),
    case file:write_file(Temporary, json:encode(State)) of
        ok -> _ = file:rename(Temporary, path(Home));
        _ -> _ = file:delete(Temporary)
    end;
save(_, _, _, _) -> nil.

state(Home) ->
    case get({?MODULE, Home}) of
        undefined -> reload(Home);
        State -> State
    end.

%% Sibling sessions share the handle file, so ensure reads it fresh instead of
%% trusting this process's earlier turns.
reload(Home) ->
    State = case file:read_file(path(Home)) of
        {ok, Binary} ->
            try json:decode(Binary) of
                Map when is_map(Map) -> Map;
                _ -> #{}
            catch _:_ -> #{} end;
        _ -> #{}
    end,
    put({?MODULE, Home}, State),
    State.

quarantined(Account) -> get({?MODULE, quarantined, Account}) =:= true.

path(Home) ->
    filename:join(unicode:characters_to_list(Home), "claude-files.json").
