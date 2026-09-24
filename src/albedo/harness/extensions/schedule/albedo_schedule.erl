-module(albedo_schedule).
-export([now/0]).
now() -> erlang:system_time(second).
