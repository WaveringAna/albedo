-module(albedo_rolling).
-export([legacy_fingerprint/1]).

%% The fingerprint saved before images were stored, over their payload bytes.
legacy_fingerprint(Inputs) ->
    case albedo_images:legacy(Inputs) of
        {ok, Term} -> {ok, hash(Term)};
        Error -> Error
    end.

hash(Term) -> binary:encode_hex(crypto:hash(sha256, term_to_binary(Term, [deterministic])), lowercase).
