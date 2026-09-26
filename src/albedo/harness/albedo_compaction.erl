-module(albedo_compaction).
-export([fingerprint/1]).

%% Images count by content hash, so a term fingerprints the same whether its
%% images are inline or stored.
fingerprint(Term) ->
    Canonical = albedo_images:canonical(Term),
    binary:encode_hex(crypto:hash(sha256, term_to_binary(Canonical, [deterministic])), lowercase).
