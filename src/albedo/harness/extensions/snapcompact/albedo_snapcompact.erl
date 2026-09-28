%% Renders snapcompact frames through albedo-render's grid renderer and
%% normalizes archive text into the continuous cell stream the grid layout
%% needs. The renderer is a subprocess, so a crash is an error, never a
%% daemon loss.
-module(albedo_snapcompact).
-export([render_frames/4, paginate/2, now_ms/0, sha256/1, normalize/1, format_args/1]).

-define(RENDER_TIMEOUT_MS, 30000).
%% U+2588 FULL BLOCK in UTF-8: the grid layout's line marker.
-define(BLOCK, <<226, 150, 136>>).

%% Renders every chunk in one subprocess (the font is parsed once) and
%% returns, in order, {Width, Height, DecodedBytes, Base64} per frame.
%% The CLI writes OUT/snap-N.png and prints one "image PATH WxH" line per
%% frame on stdout; stderr is merged in so failures explain themselves.
render_frames(Chunks, Advance, Pitch, Width) ->
    Scratch = scratch(),
    try
        ok = file:make_dir(Scratch),
        Out = filename:join(Scratch, "out"),
        ok = file:make_dir(Out),
        _ = [file:write_file(
                filename:join(Scratch, lists:flatten(io_lib:format("~2..0B.txt", [N]))),
                Chunk)
             || {N, Chunk} <- lists:zip(lists:seq(1, length(Chunks)), Chunks)],
        Args = ["--snapcompact-dir", Scratch, "--out", Out,
                "--advance", integer_to_list(Advance),
                "--pitch", integer_to_list(Pitch),
                "--width", integer_to_list(Width)],
        case run(renderer(), Args) of
            {ok, Output} ->
                collect_frames(Output, []);
            {error, Reason} ->
                {error, Reason}
        end
    catch _:_ ->
        {error, <<"frame rendering failed">>}
    after
        _ = file:del_dir_r(Scratch)
    end.

collect_frames(<<>>, Frames) ->
    case lists:reverse(Frames) of
        [] -> {error, <<"the renderer produced no frames">>};
        Rev -> {ok, Rev}
    end;
collect_frames(Output, Frames) ->
    case binary:split(Output, <<"\n">>) of
        [Line, Rest] ->
            case parse_image_line(Line) of
                {ok, Path, W, H} -> read_frame(Path, W, H, Rest, Frames);
                error -> {error, <<"unparseable renderer output">>}
            end;
        [Line] ->
            case parse_image_line(Line) of
                {ok, Path, W, H} -> read_frame(Path, W, H, <<>>, Frames);
                skip -> collect_frames(<<>>, Frames);
                error -> {error, <<"unparseable renderer output">>}
            end
    end.

read_frame(Path, W, H, Rest, Frames) ->
    case file:read_file(Path) of
        {ok, Png} ->
            collect_frames(Rest, [{W, H, byte_size(Png), base64:encode(Png)} | Frames]);
        _ -> {error, <<"the renderer produced no frame file">>}
    end.

parse_image_line(<<"image ", Rest/binary>>) ->
    Toks = binary:split(Rest, <<" ">>, [global]),
    case lists:reverse(Toks) of
        [Dims | RevPath] when length(RevPath) > 0 ->
            Path = iolist_to_binary(lists:join(<<" ">>, lists:reverse(RevPath))),
            case binary:split(Dims, <<"x">>) of
                [W, H] ->
                    case catch {binary_to_integer(W), binary_to_integer(H)} of
                        {WI, HI} when is_integer(WI), is_integer(HI), WI > 0, HI > 0 ->
                            {ok, Path, WI, HI};
                        _ -> error
                    end;
                _ -> error
            end;
        _ -> error
    end;
parse_image_line(<<>>) -> skip;
parse_image_line(_) -> error.

sha256(Text) ->
    binary:encode_hex(crypto:hash(sha256, Text), lowercase).

now_ms() ->
    erlang:system_time(millisecond).

%% A unique scratch dir keeps concurrent renders from colliding.
scratch() ->
    Tmp = case os:getenv("TMPDIR") of false -> "/tmp"; T -> T end,
    filename:join(Tmp, "albedo-snapcompact-" ++ integer_to_list(erlang:unique_integer([positive]))).

renderer() ->
    Bin = case code:priv_dir(albedo) of
        {error, _} -> "";
        Priv -> filename:join(Priv, "bin/albedo-render")
    end,
    case filelib:is_file(Bin) of
        true -> Bin;
        false -> os:find_executable("albedo-render")
    end.

run(Bin, Args) when is_list(Bin), Bin =/= "" ->
    Port = open_port({spawn_executable, Bin},
                     [{args, Args}, exit_status, binary, hide, stderr_to_stdout]),
    drain(Port, []);
run(_, _) ->
    {error, <<"albedo-render is not built; run native/render/install.sh">>}.

drain(Port, Acc) ->
    receive
        {Port, {data, Data}} -> drain(Port, [Data | Acc]);
        {Port, {exit_status, 0}} -> {ok, iolist_to_binary(lists:reverse(Acc))};
        {Port, {exit_status, _}} ->
            {error, iolist_to_binary(["renderer failed: " | lists:reverse(Acc)])};
        {Port, eof} -> drain(Port, Acc)
    after ?RENDER_TIMEOUT_MS ->
        catch erlang:port_close(Port),
        {error, <<"the renderer timed out">>}
    end.

%% One pass: escape sequences stripped, tabs expanded to four spaces, and
%% newline runs folded into single full-block cells, so the archive is one
%% continuous character stream that wraps positionally.
normalize(Text) ->
    iolist_to_binary(norm(Text, [])).

norm(<<>>, Acc) -> lists:reverse(Acc);
norm(<<13, 10, R/binary>>, A) -> nl(R, A);
norm(<<13, R/binary>>, A) -> nl(R, A);
norm(<<10, R/binary>>, A) -> nl(R, A);
norm(<<9, R/binary>>, A) -> norm(R, [<<"    ">> | A]);
norm(<<27, R/binary>>, A) -> introducer(R, A);
norm(<<C, R/binary>>, A) -> norm(R, [C | A]).

nl(<<13, R/binary>>, A) -> nl(R, A);
nl(<<10, R/binary>>, A) -> nl(R, A);
nl(R, A) -> norm(R, [?BLOCK | A]).

%% After ESC: [ starts a CSI sequence whose final byte is @-~, ] starts an
%% OSC string ended by BEL or ST, anything else is a two-byte escape.
introducer(<<$[, R/binary>>, A) -> csi(R, A);
introducer(<<$], R/binary>>, A) -> osc(R, A);
introducer(<<_, R/binary>>, A) -> norm(R, A);
introducer(<<>>, A) -> lists:reverse(A).

csi(<<C, R/binary>>, A) when C >= $@, C =< $~ -> norm(R, A);
csi(<<_, R/binary>>, A) -> csi(R, A);
csi(<<>>, A) -> lists:reverse(A).

osc(<<7, R/binary>>, A) -> norm(R, A);
osc(<<27, _, R/binary>>, A) -> norm(R, A);
osc(<<_, R/binary>>, A) -> osc(R, A);
osc(<<>>, A) -> lists:reverse(A).

%% Chunks the text into frames of PerFrame cells each. Continuation bytes
%% (2#10xxxxxx) cost no cell and stay with their lead byte, so a frame never
%% ends inside a UTF-8 sequence.
paginate(Text, PerFrame) ->
    chunk(Text, PerFrame, PerFrame, [], []).

chunk(<<>>, _Per, _N, Cur, Chunks) ->
    case Cur of
        [] -> lists:reverse(Chunks);
        _ -> lists:reverse([flush(Cur) | Chunks])
    end;
chunk(<<C, R/binary>>, Per, 0, Cur, Chunks) when C >= 128, C < 192 ->
    chunk(R, Per, 0, [C | Cur], Chunks);
chunk(Bin, Per, 0, Cur, Chunks) ->
    chunk(Bin, Per, Per, [], [flush(Cur) | Chunks]);
chunk(<<C, R/binary>>, Per, N, Cur, Chunks) when C < 128; C >= 192 ->
    chunk(R, Per, N - 1, [C | Cur], Chunks);
chunk(<<C, R/binary>>, Per, N, Cur, Chunks) ->
    chunk(R, Per, N, [C | Cur], Chunks).

flush(Cur) ->
    iolist_to_binary(lists:reverse(Cur)).

%% A tool call's arguments, readably: pairs sorted by key so the archive is
%% deterministic, string values verbatim (their newlines become block cells),
%% other values as compact JSON. Undecodable arguments pass through raw.
format_args(Args) ->
    try
        case json:decode(Args) of
            Map when is_map(Map), map_size(Map) > 0 ->
                Pairs = [format_pair(K, V) || {K, V} <- lists:sort(maps:to_list(Map))],
                iolist_to_binary(lists:join(", ", Pairs));
            _ -> Args
        end
    catch _:_ -> Args
    end.

format_pair(K, V) when is_binary(V) ->
    <<K/binary, " = ", V/binary>>;
format_pair(K, V) ->
    %% json:encode returns iolists for compound values.
    Encoded = try iolist_to_binary(json:encode(V)) catch _:_ -> <<"{?}">> end,
    <<K/binary, " = ", Encoded/binary>>.
