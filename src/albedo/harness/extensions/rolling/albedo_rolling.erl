-module(albedo_rolling).
-export([legacy_fingerprint/1]).

%% The fingerprint saved before images were stored, over their payload bytes.
legacy_fingerprint(Inputs) ->
    case albedo_images:legacy(Inputs) of
        {ok, Term} -> {ok, albedo_compaction:term_hash(Term)};
        Error -> Error
    end.
