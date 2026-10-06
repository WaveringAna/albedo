%% Runs the optional albedo-render binary (native/render). It is a subprocess,
%% so a crash is an error, never a daemon loss. snapcompact renders frames
%% through it, and requests fit oversized images with it.
-module(albedo_render).
-export([run/1, scratch/1, parse_image_line/1, fit/2]).

-define(RENDER_TIMEOUT_MS, 30000).

%% The image in canonical base64, scaled so neither edge passes Edge:
%% {ok, {Mime, Base64, Width, Height, DecodedBytes}} or {error, Reason}.
fit(Base64, Edge) ->
    Scratch = scratch("albedo-fit-"),
    try
        ok = file:make_dir(Scratch),
        In = filename:join(Scratch, "in"),
        ok = file:write_file(In, base64:decode(Base64)),
        case run(["--fit", integer_to_list(Edge), In, "--out", Scratch]) of
            {ok, Output} ->
                [Line | _] = binary:split(Output, <<"\n">>),
                case parse_image_line(Line) of
                    {ok, Path, W, H} ->
                        {ok, Data} = file:read_file(Path),
                        {ok, {mime(Path), base64:encode(Data), W, H, byte_size(Data)}};
                    _ -> {error, <<"unparseable renderer output">>}
                end;
            {error, Reason} -> {error, Reason}
        end
    catch _:_ ->
        {error, <<"the image could not be fitted">>}
    after
        _ = file:del_dir_r(Scratch)
    end.

mime(Path) ->
    case filename:extension(Path) of
        <<".jpg">> -> <<"image/jpeg">>;
        _ -> <<"image/png">>
    end.

%% "image PATH WxH", the line the renderer prints per image it wrote.
parse_image_line(<<"image ", Rest/binary>>) ->
    Toks = binary:split(Rest, <<" ">>, [global]),
    case lists:reverse(Toks) of
        [Dims | RevPath] when length(RevPath) > 0 ->
            Path = iolist_to_binary(lists:join(<<" ">>, lists:reverse(RevPath))),
            case binary:split(Dims, <<"x">>) of
                [W, H] ->
                    try {binary_to_integer(W), binary_to_integer(H)} of
                        {WI, HI} when WI > 0, HI > 0 -> {ok, Path, WI, HI};
                        _ -> error
                    catch error:badarg -> error
                    end;
                _ -> error
            end;
        _ -> error
    end;
parse_image_line(<<>>) -> skip;
parse_image_line(_) -> error.

%% A unique scratch dir keeps concurrent renders from colliding.
scratch(Prefix) ->
    Tmp = case os:getenv("TMPDIR") of false -> "/tmp"; T -> T end,
    filename:join(Tmp, Prefix ++ integer_to_list(erlang:unique_integer([positive]))).

%% The binary's stdout, stderr merged in so failures explain themselves.
run(Args) ->
    case renderer() of
        Bin when is_list(Bin), Bin =/= "" ->
            Port = open_port({spawn_executable, Bin},
                             [{args, Args}, exit_status, binary, hide, stderr_to_stdout]),
            drain(Port, []);
        _ ->
            {error, <<"albedo-render is not built; run native/render/install.sh">>}
    end.

renderer() ->
    Bin = case code:priv_dir(albedo) of
        {error, _} -> "";
        Priv -> filename:join(Priv, "bin/albedo-render")
    end,
    case filelib:is_file(Bin) of
        true -> Bin;
        false -> os:find_executable("albedo-render")
    end.

drain(Port, Acc) ->
    receive
        {Port, {data, Data}} -> drain(Port, [Data | Acc]);
        {Port, {exit_status, 0}} -> {ok, iolist_to_binary(lists:reverse(Acc))};
        {Port, {exit_status, _}} ->
            {error, iolist_to_binary(["renderer failed: " | lists:reverse(Acc)])};
        {Port, eof} -> drain(Port, Acc)
    after ?RENDER_TIMEOUT_MS ->
        _ = try port_close(Port) catch _:_ -> ok end,
        {error, <<"the renderer timed out">>}
    end.
