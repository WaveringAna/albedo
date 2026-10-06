-module(albedo_sse_bytes).
-export([newline/1, compact/1, utf8/1]).

%% Offset of the first LF or CR, or -1. Two single-byte searches: a one-byte
%% pattern is a memchr, while a two-alternative pattern is compiled on every
%% call and matched by automaton.
newline(Bytes) ->
    case binary:match(Bytes, <<10>>) of
        nomatch -> cr(Bytes, byte_size(Bytes), -1);
        {Lf, 1} -> cr(Bytes, Lf, Lf)
    end.

cr(_, 0, Default) -> Default;
cr(Bytes, Before, Default) ->
    case binary:match(Bytes, <<13>>, [{scope, {0, Before}}]) of
        nomatch -> Default;
        {Cr, 1} -> Cr
    end.

compact(Bytes) ->
    case binary:referenced_byte_size(Bytes) > max(4096, byte_size(Bytes) * 4) of
        true -> binary:copy(Bytes);
        false -> Bytes
    end.

%% bit_array.to_string's contract, checked by the runtime instead of one
%% codepoint per Gleam call. characters_to_binary returns a valid binary as
%% the same term, so nothing is copied.
utf8(Bytes) ->
    case unicode:characters_to_binary(Bytes) of
        Valid when is_binary(Valid) -> {ok, Bytes};
        _ -> {error, nil}
    end.
