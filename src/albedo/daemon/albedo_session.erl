-module(albedo_session).
-export([kill/1, now_ms/0]).
kill(Pid) -> exit(Pid,kill), nil.
%% Monotonic: idle time must not move when the wall clock does.
now_ms() -> erlang:monotonic_time(millisecond).
