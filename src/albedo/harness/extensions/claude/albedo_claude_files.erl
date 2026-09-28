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

missing([{image, Mime, Data, _, _, _} | Rest], Cache, Seen) ->
    Key = image_key(Data),
    case maps:is_key(Key, Cache) orelse maps:is_key(Key, Seen) of
        true -> missing(Rest, Cache, Seen);
        false -> [{Key, Mime, Data} | missing(Rest, Cache, Seen#{Key => true})]
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
                || Pid <- [spawn(Loop)
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
        case binary:match(Text, [<<"file_id">>, <<"file_0">>]) =/= nomatch of
            true ->
                put({?MODULE, quarantined, Account}, true),
                save(Home, Account, #{}, true);
            false -> nil
        end
    catch _:_ -> nil
    end,
    nil.

upload(Endpoint, Access, Mime, Bytes) ->
    Url = <<(unicode:characters_to_binary(Endpoint))/binary, "/v1/files">>,
    Boundary = <<"albedo-", (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    Part = [<<"--">>, Boundary,
            <<"\r\ncontent-disposition: form-data; name=\"file\"; filename=\"">>,
            filename(Mime), <<"\"\r\ncontent-type: ">>, Mime, <<"\r\n\r\n">>,
            Bytes, <<"\r\n--">>, Boundary, <<"--\r\n">>],
    Headers = [{"authorization", "Bearer " ++ unicode:characters_to_list(Access)},
               {"anthropic-version", binary_to_list(?VERSION)},
               {"anthropic-beta", binary_to_list(?BETA)},
               {"accept", "application/json"}],
    Type = "multipart/form-data; boundary=" ++ binary_to_list(Boundary),
    case albedo_http:post(Url, Headers, Type, Part, ?TIMEOUT_MS, 10000) of
        {ok, {200, _, Response}} ->
            case metadata(Response, byte_size(Bytes)) of
                {ok, Entry} -> {ok, Entry};
                error -> {error, <<"Anthropic file upload returned invalid metadata">>}
            end;
        {ok, {Status, _, Response}} ->
            Detail = binary:part(Response, 0, min(byte_size(Response), 2048)),
            {error, iolist_to_binary(io_lib:format("Anthropic file upload failed (~B): ~s",
                                                   [Status, Detail]))};
        _ -> {error, <<"Anthropic file upload failed">>}
    end.

delete(Endpoint, Access, Id) ->
    Url = <<(unicode:characters_to_binary(Endpoint))/binary, "/v1/files/", Id/binary>>,
    Headers = [{"authorization", "Bearer " ++ unicode:characters_to_list(Access)},
               {"anthropic-version", binary_to_list(?VERSION)},
               {"anthropic-beta", binary_to_list(?BETA)}],
    _ = albedo_http:request(delete, Url, Headers, none, ?TIMEOUT_MS, 10000),
    nil.

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
    State = (reload(Home))#{Account => Cache},
    put({?MODULE, Home}, State),
    _ = albedo_credentials:write(path(Home), State),
    nil;
save(_, _, _, _) -> nil.

state(Home) ->
    case get({?MODULE, Home}) of
        undefined -> reload(Home);
        State -> State
    end.

%% Sibling sessions share the handle file, so ensure reads it fresh instead of
%% trusting this process's earlier turns.
reload(Home) ->
    State = case albedo_credentials:read_json(path(Home)) of
        {ok, Map} when is_map(Map) -> Map;
        _ -> #{}
    end,
    put({?MODULE, Home}, State),
    State.

quarantined(Account) -> get({?MODULE, quarantined, Account}) =:= true.

path(Home) ->
    filename:join(unicode:characters_to_list(Home), "claude-files.json").
