-module(albedo_retry_test).
-export([reset/0, next/0]).
reset() -> erase(retry_count), nil.
next() ->
    N = case get(retry_count) of undefined -> 0; Value -> Value end,
    put(retry_count, N + 1), N + 1.
