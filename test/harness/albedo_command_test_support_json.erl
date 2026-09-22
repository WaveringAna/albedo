%% Test helper: a parsed JSON document is a gleam decode.Dynamic on this target.
-module(albedo_command_test_support_json).
-export([parse/1]).

parse(Text) -> json:decode(Text).
