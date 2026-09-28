-module(albedo_compaction).
-export([fingerprint/1, term_hash/1]).

%% Images count by content hash, so a term fingerprints the same whether its
%% images are inline or stored.
fingerprint(Term) ->
    term_hash(albedo_images:canonical(Term)).

%% The stable digest of an Erlang term: deterministic serialization, sha256,
%% lowercase hex. Every saved fingerprint must hash the same way or a cut
%% silently stops validating.
term_hash(Term) ->
    binary:encode_hex(crypto:hash(sha256, term_to_binary(Term, [deterministic])), lowercase).
