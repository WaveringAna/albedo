-module(albedo_claude_billing).
%% Claude Code's first system block and body attestation. Hash the exact bytes
%% written to the transport, with cch=00000 still in the billing block.
-export([header/2, sign/1, hash/1]).

-define(VERSION_SALT, <<"59cf53e54c78">>).
-define(SEED, 16#4d659218e32a3268).
-define(MASK, 16#ffffffffffffffff).
-define(P1, 11400714785074694791).
-define(P2, 14029467366897019727).
-define(P3, 1609587929392839161).
-define(P4, 9650029242287828579).
-define(P5, 2870177450012600261).
-define(PLACEHOLDER, <<"cch=00000">>).
-define(MARKER, <<"\"system\":[{\"type\":\"text\",\"text\":\"x-anthropic-billing-header:">>).

header(Version, FirstUser) ->
    Text = unicode:characters_to_binary(FirstUser),
    Utf16 = unicode:characters_to_binary(Text, utf8, {utf16, little}),
    Units = [Unit || <<Unit:16/little>> <= Utf16],
    Sample = unicode:characters_to_binary([at(Units, 4), at(Units, 7), at(Units, 20)]),
    Digest = binary:encode_hex(crypto:hash(sha256, <<?VERSION_SALT/binary, Sample/binary, Version/binary>>), lowercase),
    Suffix = binary:part(Digest, 0, 3),
    <<"x-anthropic-billing-header: cc_version=", Version/binary, ".", Suffix/binary,
      "; cc_entrypoint=cli; cch=00000;">>.

at(Units, Index) ->
    case length(Units) > Index of
        true -> lists:nth(Index + 1, Units);
        false -> $0
    end.

sign(Tree) ->
    Body = iolist_to_binary(Tree),
    case binary:match(Body, ?MARKER) of
        {Start, _} ->
            Offset = Start + byte_size(?MARKER),
            Window = binary:part(Body, Offset, min(150, byte_size(Body) - Offset)),
            case binary:match(Window, ?PLACEHOLDER) of
                {Index, _} ->
                    Hash = hash(Body),
                    Begin = Offset + Index + byte_size(<<"cch=">>),
                    <<Before:Begin/binary, _:5/binary, After/binary>> = Body,
                    {ok, <<Before/binary, Hash/binary, After/binary>>};
                nomatch -> {error, <<"Claude billing block has no cch placeholder">>}
            end;
        nomatch -> {error, <<"Claude billing block is not the first system block">>}
    end.

%% XXHash64 with Claude Code's CCH seed, truncated to the low 20 bits.
hash(Data) ->
    Value = xxh64(Data, ?SEED) band 16#fffff,
    iolist_to_binary(io_lib:format("~5.16.0b", [Value])).

xxh64(Data, Seed) when byte_size(Data) >= 32 ->
    V1 = u(Seed + ?P1 + ?P2), V2 = u(Seed + ?P2),
    {A, B, C, D, Rest} = lanes(Data, V1, V2, Seed, u(Seed - ?P1)),
    H = u(rol(A, 1) + rol(B, 7) + rol(C, 12) + rol(D, 18)),
    tail(Rest, byte_size(Data), merge(D, merge(C, merge(B, merge(A, H)))));
xxh64(Data, Seed) ->
    tail(Data, byte_size(Data), u(Seed + ?P5)).

lanes(<<A:64/little, B:64/little, C:64/little, D:64/little, Rest/binary>>, V1, V2, V3, V4) ->
    lanes(Rest, round(V1, A), round(V2, B), round(V3, C), round(V4, D));
lanes(Rest, V1, V2, V3, V4) -> {V1, V2, V3, V4, Rest}.

round(Acc, Word) -> u(rol(u(Acc + u(Word * ?P2)), 31) * ?P1).
merge(Value, Acc) -> u(((Acc bxor round(0, Value)) * ?P1) + ?P4).

tail(Rest, Length, Hash) -> chunks(Rest, u(Hash + Length)).
chunks(<<Word:64/little, Rest/binary>>, Hash) ->
    chunks(Rest, u(rol(Hash bxor round(0, Word), 27) * ?P1 + ?P4));
chunks(<<Word:32/little, Rest/binary>>, Hash) ->
    chunks(Rest, u(rol(Hash bxor u(Word * ?P1), 23) * ?P2 + ?P3));
chunks(<<Byte:8, Rest/binary>>, Hash) ->
    chunks(Rest, u(rol(Hash bxor u(Byte * ?P5), 11) * ?P1));
chunks(<<>>, Hash) -> avalanche(Hash).

avalanche(Hash) ->
    H1 = u((Hash bxor (Hash bsr 33)) * ?P2),
    H2 = u((H1 bxor (H1 bsr 29)) * ?P3),
    u(H2 bxor (H2 bsr 32)).

rol(N, Bits) -> u((N bsl Bits) bor (N bsr (64 - Bits))).
u(N) -> N band ?MASK.
