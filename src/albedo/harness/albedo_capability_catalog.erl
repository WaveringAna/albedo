-module(albedo_capability_catalog).
-export([fingerprint/1, source_title/1]).

fingerprint(Value) ->
    binary:encode_hex(crypto:hash(sha256, term_to_binary(Value, [deterministic]))).

source_title(Source) ->
    case filename:basename(Source) of
        <<"SKILL.md">> -> filename:basename(filename:dirname(Source));
        Name -> Name
    end.
