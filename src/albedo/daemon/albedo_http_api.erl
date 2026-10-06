-module(albedo_http_api).
-export([zstd_available/0, zstd_streams/0, accepts_zstd/1, zstd_compress/1, zstd_stream/0, zstd_flush/2, zstd_end/1, zstd_decompress/2,
         stream_socket/1, scalar_prefix/2, content_slice/3, page_token/3, page_state/3, parse/1, accept/2, encode/1, timestamp/1, etag/1, instance_id/0, read_chunked/2]).

parse(Bytes) ->
    try
        Push = fun(Key, Value, Acc) ->
            case maps:is_key(Key, Acc) of
                true -> error(duplicate_key);
                false -> Acc#{Key => Value}
            end
        end,
        {Value, _, Rest} = json:decode(Bytes, nil, #{
            object_start => fun(_) -> #{} end,
            object_push => Push,
            object_finish => fun(Acc, Parent) -> {Acc, Parent} end
        }),
        case string:trim(Rest) of
            <<>> -> {ok, Value};
            _ -> {error, <<"JSON has trailing content">>}
        end
    catch
        error:duplicate_key -> {error, <<"JSON contains a duplicate key">>};
        _:_ -> {error, <<"request is not valid JSON">>}
    end.

encode(Value) -> iolist_to_binary(json:encode(Value)).

timestamp(Milliseconds) ->
    list_to_binary(calendar:system_time_to_rfc3339(max(0, Milliseconds),
        [{unit, millisecond}, {offset, "Z"}])).

etag(Encoded) ->
    Hash = binary:encode_hex(crypto:hash(sha256, Encoded), lowercase),
    <<$", Hash/binary, $">>.

%% The listener captures this identity once at daemon startup.
instance_id() ->
    Bytes = crypto:strong_rand_bytes(16),
    binary:encode_hex(Bytes, lowercase).

%% A stalled reader can occupy only its own stream owner, for at most one
%% second per write. The subscriber's owner death releases its bounded queue.
stream_socket({connection, _, Socket, Transport, _}) ->
    Options = [{send_timeout, 1000}, {send_timeout_close, true}],
    Result = case Transport of
        tcp -> inet:setopts(Socket, Options);
        ssl -> ssl:setopts(Socket, Options)
    end,
    case Result of ok -> {ok, nil}; _ -> {error, <<"socket unavailable">>} end.

%% Mist 6's whole-body chunked reader does not enforce its byte limit. Decode
%% framing here so an oversized chunk is refused before reading its payload.
read_chunked({connection, {initial, Buffered}, Socket, Transport, _}, Limit) ->
    try
        Deadline = erlang:monotonic_time(millisecond) + 15000,
        {Bytes, <<>>} = chunks(Socket, Transport, Buffered, Limit, [], Deadline),
        {ok, Bytes}
    catch
        throw:too_large -> {error, excess_body};
        _:_ -> {error, malformed_body}
    end;
read_chunked(_, _) -> {error, malformed_body}.

chunks(Socket, Transport, Buffered, Remaining, Pieces, Deadline) ->
    {Line, Rest} = line(Socket, Transport, Buffered, 8192, Deadline),
    [Digits|_] = binary:split(Line, <<";">>, [global]),
    true = byte_size(Digits) > 0 andalso byte_size(Digits) =< 16,
    true = re:run(Digits, <<"^[0-9A-Fa-f]+$">>, [{capture, none}]) =:= match,
    Size = binary_to_integer(Digits, 16),
    case Size of
        0 ->
            Trailing = trailers(Socket, Transport, Rest, 8192, Deadline),
            {iolist_to_binary(lists:reverse(Pieces)), Trailing};
        _ when Size > Remaining -> throw(too_large);
        _ ->
            {Payload, Buffered1} = exact(Socket, Transport, Rest, Size, Deadline),
            {<<13,10>>, Buffered2} = exact(Socket, Transport, Buffered1, 2, Deadline),
            chunks(Socket, Transport, Buffered2, Remaining - Size, [Payload|Pieces], Deadline)
    end.

trailers(Socket, Transport, Buffered, Remaining, Deadline) ->
    {Line, Rest} = line(Socket, Transport, Buffered, Remaining, Deadline),
    case Line of
        <<>> -> Rest;
        _ ->
            [Name, _Value] = binary:split(Line, <<":">>),
            true = re:run(Name, <<"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$">>, [{capture, none}]) =:= match,
            false = lists:member(string:lowercase(Name), [<<"authorization">>, <<"content-length">>, <<"transfer-encoding">>, <<"content-type">>, <<"origin">>, <<"host">>]),
            trailers(Socket, Transport, Rest, Remaining - byte_size(Line) - 2, Deadline)
    end.

line(Socket, Transport, Buffered, Limit, Deadline) when Limit > 0 ->
    case binary:match(Buffered, <<13,10>>) of
        {At, 2} when At =< Limit ->
            <<Line:At/binary,13,10,Rest/binary>> = Buffered, {Line, Rest};
        nomatch when byte_size(Buffered) < Limit ->
            More = receive_bytes(Socket, Transport, 1, Deadline),
            line(Socket, Transport, <<Buffered/binary,More/binary>>, Limit, Deadline);
        _ -> erlang:error(invalid_chunk_header)
    end;
line(_, _, _, _, _) -> erlang:error(invalid_chunk_header).

exact(_, _, Buffered, Size, _) when byte_size(Buffered) >= Size ->
    <<Value:Size/binary,Rest/binary>> = Buffered, {Value,Rest};
exact(Socket, Transport, Buffered, Size, Deadline) ->
    More = receive_bytes(Socket, Transport, Size - byte_size(Buffered), Deadline),
    exact(Socket, Transport, <<Buffered/binary,More/binary>>, Size, Deadline).

receive_bytes(Socket, Transport, Amount, Deadline) ->
    Timeout = Deadline - erlang:monotonic_time(millisecond), true = Timeout > 0,
    {ok, Bytes} = 'glisten@transport':receive_timeout(Transport, Socket, Amount, Timeout),
    true = byte_size(Bytes) > 0, Bytes.

%% Continuations carry only bounded projection state, authenticated against
%% their resource and query. No storage identifiers are accepted as cursors.
page_token(Secret, Binding, State) ->
    Payload = iolist_to_binary(json:encode(#{<<"binding">> => Binding, <<"state">> => State,
        <<"expires">> => erlang:system_time(millisecond) + 900000})),
    Encoded = base64:encode(Payload, #{mode => urlsafe, padding => false}),
    Mac = crypto:mac(hmac, sha256, Secret, Encoded),
    <<Encoded/binary, ".", (base64:encode(Mac, #{mode => urlsafe, padding => false}))/binary>>.

page_state(Secret, Binding, Token) ->
    try
        true = is_binary(Token) andalso byte_size(Token) =< 16384,
        [Encoded, Signature] = binary:split(Token, <<".">>, [global]),
        Mac = base64:decode(Signature, #{mode => urlsafe, padding => false}),
        true = crypto:hash_equals(crypto:mac(hmac, sha256, Secret, Encoded), Mac),
        {ok, Payload} = parse(base64:decode(Encoded, #{mode => urlsafe, padding => false})),
        #{<<"binding">> := Binding, <<"state">> := State, <<"expires">> := Expires} = Payload,
        case Expires > erlang:system_time(millisecond) of
            true -> {ok, State};
            false -> {error, <<"continuation_expired">>}
        end
    catch _:_ -> {error, <<"invalid_continuation">>} end.

content_slice(Text, Offset, Limit) ->
    Size = byte_size(Text),
    case Offset >= 0 andalso Offset =< Size of
        false -> {error, <<"invalid content offset">>};
        true ->
            End = utf8_end(Text, min(Size, Offset + Limit), Size),
            {ok, {binary:part(Text, Offset, End - Offset), End, End =:= Size}}
    end.

utf8_end(_, End, End) -> End;
utf8_end(_, 0, _) -> 0;
utf8_end(Text, End, Size) ->
    case binary:at(Text, End) band 16#c0 of
        16#80 -> utf8_end(Text, End - 1, Size);
        _ -> End
    end.

%% zstd ships with OTP 28; flushing a stream mid-frame needs OTP 29.
zstd_available() -> code:ensure_loaded(zstd) =:= {module, zstd}.

zstd_streams() -> zstd_available() andalso erlang:function_exported(zstd, flush, 1).

%% Whether an Accept-Encoding header admits zstd, by name or wildcard.
accepts_zstd(Header) ->
    try
        true = byte_size(Header) =< 8192,
        Codings = [media_range(Part) || Part0 <- binary:split(Header, <<",">>, [global]),
            Part <- [string:trim(Part0)], Part =/= <<>>],
        Named = [Quality || {<<"zstd">>, Quality} <- Codings],
        Any = [Quality || {<<"*">>, Quality} <- Codings],
        Quality = case {Named, Any} of
            {[_|_], _} -> lists:max(Named);
            {[], [_|_]} -> lists:max(Any);
            {[], []} -> 0
        end,
        Quality > 0 andalso zstd_available()
    catch _:_ -> false end.

zstd_compress(Data) -> zstd:compress(Data, #{compressionLevel => 1}).

zstd_stream() ->
    {ok, Context} = zstd:context(compress, #{compressionLevel => 1}),
    Context.

%% Everything written so far, decodable by a reader without waiting for more.
zstd_flush(Context, Data) ->
    Buffered = zstd_feed(Context, Data),
    {continue, Flushed} = zstd:flush(Context),
    [Buffered, Flushed].

zstd_feed(Context, Data) ->
    case zstd:stream(Context, Data) of
        {continue, Rest, Out} -> [Out | zstd_feed(Context, Rest)];
        {continue, Out} -> [Out]
    end.

zstd_end(Context) ->
    {done, Tail} = zstd:finish(Context, <<>>),
    Tail.

%% One frame that declares its decoded size, at most Limit bytes. Output is
%% produced in bounded steps, so a frame that lies about its size cannot
%% allocate past Limit, and a truncated frame fails the size check.
zstd_decompress(Data, Limit) ->
    try
        {ok, #{frameContentSize := Size}} = zstd:get_frame_header(Data),
        true = is_integer(Size) andalso Size =< Limit,
        {ok, Context} = zstd:context(decompress),
        try inflate(Context, Data, Size, [], 0) after zstd:close(Context) end
    catch _:_ -> {error, nil} end.

inflate(_, _, Size, _, Total) when Total > Size -> {error, nil};
inflate(Context, Data, Size, Acc, Total) ->
    case zstd:stream(Context, Data) of
        {continue, Rest, Out} -> inflate(Context, Rest, Size, [Out|Acc], Total + byte_size(Out));
        {continue, Out} when Total + byte_size(Out) =:= Size ->
            {ok, iolist_to_binary(lists:reverse(Acc, [Out]))};
        {continue, _} -> {error, nil}
    end.

%% Rank supported representations while respecting a specific q=0 exclusion
%% over a less-specific wildcard. JSON wins a tie so */* never starts a stream.
accept(Header, Live) ->
    try
        true = byte_size(Header) =< 8192,
        Ranges = [media_range(string:trim(Part)) || Part <- binary:split(Header, <<",">>, [global])],
        JSON = media_quality(<<"application/json">>, Ranges),
        SSE = case Live of true -> media_quality(<<"text/event-stream">>, Ranges); false -> 0 end,
        case {JSON, SSE} of {0,0} -> {error, <<"Unsupported response media type">>}; _ -> {ok, SSE > JSON} end
    catch _:_ -> {error, <<"Invalid Accept header">>} end.

media_range(Range) ->
    [Type|Params] = binary:split(string:lowercase(Range), <<";">>, [global]),
    Media = string:trim(Type), true = byte_size(Media) > 0,
    Qualities = [string:trim(Value) || Param <- Params,
        [Key, Value] <- [binary:split(string:trim(Param), <<"=">>)], Key =:= <<"q">>],
    Quality = case Qualities of [] -> 1000; [Value] -> quality(Value) end,
    {Media, Quality}.

quality(<<"1">>) -> 1000;
quality(<<"0">>) -> 0;
quality(<<"1.", Rest/binary>>) -> true = byte_size(Rest) =< 3,
    true = lists:all(fun(C) -> C =:= $0 end, binary_to_list(Rest)), 1000;
quality(<<"0.", Rest/binary>>) -> true = byte_size(Rest) > 0 andalso byte_size(Rest) =< 3,
    true = lists:all(fun(C) -> C >= $0 andalso C =< $9 end, binary_to_list(Rest)),
    binary_to_integer(<<Rest/binary, (binary:copy(<<"0">>, 3-byte_size(Rest)))/binary>>).

media_quality(Media, Ranges) ->
    [Type, _] = binary:split(Media, <<"/">>),
    Wildcard = <<Type/binary, "/*">>,
    Matches = [{case Range of Media -> 2; Wildcard -> 1; _ -> 0 end, Quality}
        || {Range, Quality} <- Ranges, Range =:= Media orelse Range =:= Wildcard orelse Range =:= <<"*/*">>],
    case Matches of [] -> 0; _ -> {Specificity, _} = lists:max(Matches),
        lists:max([Quality || {S, Quality} <- Matches, S =:= Specificity]) end.

scalar_prefix(Text, Limit) -> unicode:characters_to_binary(lists:sublist(unicode:characters_to_list(Text), max(0, Limit))).
