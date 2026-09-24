-module(albedo_proxy).
-export([encode/1, conversation/1, now/0, unique/0]).

encode(Value) -> json:encode(Value).

%% Names one client conversation for upstream identity without storing it.
conversation(Seed) ->
    <<"proxy-", (binary:encode_hex(binary:part(crypto:hash(sha256, Seed), 0, 12), lowercase))/binary>>.

now() -> erlang:system_time(second).

unique() -> erlang:unique_integer([positive]).
