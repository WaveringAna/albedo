-module(albedo_claude_billing).
%% Claude Code first system block and streaming body attestation.
%% The cch digits ride as an albedo_openai_transport marker spliced during write.
-export([billing_block/2, hash/1, hash_streamed/1, xxh_init/0, xx_update/2, cch_emit/1]).

-define(VERSION_SALT, <<"59cf53e54c78">>).
-define(SEED, 16#4d659218e32a3268).
-define(MASK, 16#ffffffffffffffff).
-define(P1, 11400714785074694791).
-define(P2, 14029467366897019727).
-define(P3, 1609587929392839161).
-define(P4, 9650029242287828579).
-define(P5, 2870177450012600261).
-define(DIGITS, <<"00000">>).
-define(ATTEST, {albedo_attest, fun ?MODULE:xxh_init/0, fun ?MODULE:xx_update/2, fun ?MODULE:cch_emit/1, ?DIGITS}).

billing_block(Version, FirstUser) ->
    Text = unicode:characters_to_binary(FirstUser),
    Utf16 = unicode:characters_to_binary(Text, utf8, {utf16, little}),
    Units = [Unit || <<Unit:16/little>> <= Utf16],
    Sample = unicode:characters_to_binary([at(Units, 4), at(Units, 7), at(Units, 20)]),
    Digest = binary:encode_hex(crypto:hash(sha256, <<?VERSION_SALT/binary, Sample/binary, Version/binary>>), lowercase),
    Suffix = binary:part(Digest, 0, 3),
    Pre = <<"x-anthropic-billing-header: cc_version=", Version/binary, ".", Suffix/binary,
            "; cc_entrypoint=cli; cch=">>,
    [<<"{\"type\":\"text\",\"text\":">>, $", escaped(Pre), ?ATTEST, <<";\"}">>].

escaped(Text) ->
    Encoded = iolist_to_binary(json:encode_binary(Text)),
    binary:part(Encoded, 1, byte_size(Encoded) - 2).

at(Units, Index) ->
    try lists:nth(Index + 1, Units) of
        Unit when Unit >= 16#D800, Unit =< 16#DFFF -> $0;
        Unit -> Unit
    catch _:_ -> $0
    end.

hash(Data) -> digits(xxh_final(xx_update(xxh_init(), Data))).

hash_streamed(Chunks) ->
    cch_emit(lists:foldl(fun absorb/2, xxh_init(), Chunks)).

xxh_init() ->
    {u(?SEED + ?P1 + ?P2), u(?SEED + ?P2), ?SEED, u(?SEED - ?P1), <<>>, 0}.

xx_update(State, Data) -> absorb(Data, State).

absorb([], State) -> State;
absorb([Head | Tail], State) -> absorb(Tail, absorb(Head, State));
absorb(Byte, {V1, V2, V3, V4, Buffer, Total})
        when is_integer(Byte), Byte >= 0, Byte =< 255 ->
    case byte_size(Buffer) of
        31 ->
            <<A:64/little, B:64/little, C:64/little, D:64/little>> = <<Buffer/binary, Byte>>,
            {round(V1, A), round(V2, B), round(V3, C), round(V4, D), <<>>, Total + 1};
        _ ->
            {V1, V2, V3, V4, <<Buffer/binary, Byte>>, Total + 1}
    end;
absorb(Binary, {V1, V2, V3, V4, Buffer, Total}) when is_binary(Binary) ->
    Need = 32 - byte_size(Buffer),
    case byte_size(Binary) >= Need of
        true ->
            Fill = binary:part(Binary, 0, Need),
            <<A:64/little, B:64/little, C:64/little, D:64/little>> = <<Buffer/binary, Fill/binary>>,
            Rest = binary:part(Binary, Need, byte_size(Binary) - Need),
            {V1a, V2a, V3a, V4a, Tail} = lanes(Rest, round(V1, A), round(V2, B), round(V3, C), round(V4, D)),
            {V1a, V2a, V3a, V4a, binary:copy(Tail), Total + byte_size(Binary)};
        false ->
            {V1, V2, V3, V4, <<Buffer/binary, Binary/binary>>, Total + byte_size(Binary)}
    end.

lanes(<<A:64/little, B:64/little, C:64/little, D:64/little, Rest/binary>>, V1, V2, V3, V4) ->
    lanes(Rest, round(V1, A), round(V2, B), round(V3, C), round(V4, D));
lanes(Rest, V1, V2, V3, V4) -> {V1, V2, V3, V4, Rest}.

xxh_final({V1, V2, V3, V4, Buffer, Total}) ->
    case Total >= 32 of
        true ->
            H = u(rol(V1, 1) + rol(V2, 7) + rol(V3, 12) + rol(V4, 18)),
            Acc = merge(V4, merge(V3, merge(V2, merge(V1, H)))),
            chunks(Buffer, u(Acc + Total));
        false ->
            chunks(Buffer, u(u(?SEED + ?P5) + Total))
    end.

cch_emit(State) -> digits(xxh_final(State)).

digits(Value) ->
    iolist_to_binary(io_lib:format("~5.16.0b", [Value band 16#fffff])).

round(Acc, Word) -> u(rol(u(Acc + u(Word * ?P2)), 31) * ?P1).
merge(Value, Acc) -> u(((Acc bxor round(0, Value)) * ?P1) + ?P4).

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
