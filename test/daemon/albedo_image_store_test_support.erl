-module(albedo_image_store_test_support).
-export([legacy_payload/2, exists/1, legacy_fingerprint/3]).

%% A transcript row as written before images were stored: the payload inline.
legacy_payload(Text, Data) ->
    term_to_binary({1, {user_image, Text, {image, <<"image/png">>, Data, 2, 3, 45}}}).

exists(Path) -> filelib:is_regular(Path).

%% What rolling's fingerprint returned for #(Source, [UserImage(Text, _)])
%% before images were stored.
legacy_fingerprint(Source, Text, Data) ->
    Term = {Source, [{user_image, Text, {image, <<"image/png">>, Data, 2, 3, 45}}]},
    binary:encode_hex(crypto:hash(sha256, term_to_binary(Term, [deterministic])), lowercase).
