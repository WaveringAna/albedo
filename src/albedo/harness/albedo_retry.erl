-module(albedo_retry).
-export([sleep/1]).
sleep(Milliseconds) -> timer:sleep(Milliseconds), nil.
