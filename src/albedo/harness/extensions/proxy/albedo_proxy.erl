-module(albedo_proxy).
-export([conversation/1, now/0, unique/0, pack/1, unpack/1]).

-define(MAX_STATE, 4194304).

%% Names one client conversation for upstream identity without storing it.
conversation(Seed) ->
    <<"proxy-", (binary:encode_hex(binary:part(crypto:hash(sha256, Seed), 0, 12), lowercase))/binary>>.

now() -> erlang:system_time(second).

unique() -> erlang:unique_integer([positive]).

%% Provider state made safe for a tool-call id: [A-Za-z0-9_-] only.
pack(Json) -> base64:encode(zlib:compress(Json), #{mode => urlsafe, padding => false}).

unpack(Text) ->
    try
        Z = zlib:open(),
        ok = zlib:inflateInit(Z),
        Inflated = bounded(Z, zlib:safeInflate(Z, base64:decode(Text, #{mode => urlsafe, padding => false})), []),
        %% Raises unless the stream ended with a matching checksum, so a
        %% client that truncated or rewrote the id gets the portable path.
        ok = zlib:inflateEnd(Z),
        zlib:close(Z),
        Inflated
    catch _:_ -> {error, nil}
    end.

%% Refuses state that inflates past the bound instead of allocating it.
bounded(Z, {continue, Chunk}, Acc) ->
    case iolist_size([Acc, Chunk]) > ?MAX_STATE of
        true -> {error, nil};
        false -> bounded(Z, zlib:safeInflate(Z, []), [Acc, Chunk])
    end;
bounded(_, {finished, Chunk}, Acc) ->
    case iolist_size([Acc, Chunk]) > ?MAX_STATE of
        true -> {error, nil};
        false -> {ok, iolist_to_binary([Acc, Chunk])}
    end.
