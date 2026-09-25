-module(albedo_webhooks_test_support).
-export([sign/2]).
sign(Body, Secret) -> <<"sha256=", (binary:encode_hex(crypto:mac(hmac, sha256, Secret, Body), lowercase))/binary>>.
