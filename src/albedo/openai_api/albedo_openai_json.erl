-module(albedo_openai_json).
-export([encode/1, null/0]).

encode(Value) -> json:encode(Value).

null() -> null.
