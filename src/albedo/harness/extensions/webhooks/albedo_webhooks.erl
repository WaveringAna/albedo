-module(albedo_webhooks).
-export([new_id/0, new_secret/0, verify/4, fingerprint/1]).

new_id() -> binary:encode_hex(crypto:strong_rand_bytes(16), lowercase).
new_secret() -> base64:encode(crypto:strong_rand_bytes(32), #{mode => urlsafe, padding => false}).

fingerprint(Body) -> binary:encode_hex(crypto:hash(sha256, Body), lowercase).

verify(Body, Header, Secret, Prefix) when is_binary(Header) ->
    try
        <<Prefix:(byte_size(Prefix))/binary, Hex/binary>> = Header,
        64 = byte_size(Hex),
        Supplied = binary:decode_hex(Hex),
        Expected = crypto:mac(hmac, sha256, Secret, Body),
        crypto:hash_equals(Supplied, Expected)
    catch _:_ -> false end;
verify(_, _, _, _) -> false.
