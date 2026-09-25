-module(albedo_rolling).
-export([fingerprint/1, legacy_fingerprint/1]).

%% Images count by content hash, so a prefix fingerprints the same whether its
%% images are inline or stored; a term without images hashes as it always has.
fingerprint(Inputs) -> hash(albedo_images:canonical(Inputs)).

%% The fingerprint saved before images were stored, over their payload bytes.
legacy_fingerprint(Inputs) ->
    case albedo_images:legacy(Inputs) of
        {ok, Term} -> {ok, hash(Term)};
        Error -> Error
    end.

hash(Term) -> binary:encode_hex(crypto:hash(sha256, term_to_binary(Term, [deterministic])), lowercase).
