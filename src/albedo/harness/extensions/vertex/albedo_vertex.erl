%% RS256 signing for Vertex AI service-account JWTs. public_key:sign/3
%% rejects a raw PKCS8 'PrivateKeyInfo' record (it only matches concrete key
%% records such as 'RSAPrivateKey'), so an unencrypted "BEGIN PRIVATE KEY"
%% PEM block must be unwrapped by hand first; this mirrors the private
%% der_priv_key_decode/1 clause OTP's own public_key module uses for the
%% equivalent encrypted-key path (lib/public_key/src/public_key.erl).
-module(albedo_vertex).
-export([rs256_sign/2]).
-include_lib("public_key/include/public_key.hrl").

rs256_sign(PemBin, Message) ->
    try
        [Entry] = public_key:pem_decode(PemBin),
        Key = unwrap(public_key:pem_entry_decode(Entry)),
        {ok, public_key:sign(Message, sha256, Key)}
    catch
        _:_ -> {error, <<"invalid Vertex service-account private key">>}
    end.

unwrap(#'PrivateKeyInfo'{
    privateKeyAlgorithm = #'PrivateKeyInfo_privateKeyAlgorithm'{algorithm = ?'rsaEncryption'},
    privateKey = Der
}) ->
    public_key:der_decode('RSAPrivateKey', Der);
unwrap(Key) ->
    Key.
