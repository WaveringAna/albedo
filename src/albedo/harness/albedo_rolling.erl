-module(albedo_rolling).
-export([fingerprint/1]).
fingerprint(Inputs) -> binary:encode_hex(crypto:hash(sha256, term_to_binary(Inputs, [deterministic])), lowercase).
