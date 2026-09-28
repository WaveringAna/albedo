%% The process half of albedo/harness/vcs: every git and jj command runs
%% here, with the same environment allowlist as a usage feed's commands, a
%% deadline and a stdout cap, in the directory it is about.
-module(albedo_vcs).

-export([run/4]).

%% Large enough for the file list of a big checkout, small enough that a
%% runaway listing cannot fill memory; past it, output is discarded.
-define(STDOUT_CAP, 8388608).

%% Stdout of a command that exited 0 before the deadline, or an error for
%% anything else: a missing program, a failure, or a timeout.
run(Program, Args, Cwd, TimeoutMs) ->
    case os:find_executable(unicode:characters_to_list(Program)) of
        false -> {error, nil};
        Exe ->
            try open_port({spawn_executable, Exe},
                          [{args, Args}, {cd, Cwd}, exit_status, binary, hide,
                           {env, albedo_usage_core:command_env()}]) of
                Port ->
                    Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
                    drain(Port, [], 0, Deadline)
            catch
                error:_ -> {error, nil}
            end
    end.

drain(Port, Acc, Size, Deadline) ->
    Remaining = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {Port, {data, _}} when Size >= ?STDOUT_CAP ->
            drain(Port, Acc, Size, Deadline);
        {Port, {data, Data}} ->
            drain(Port, [Data | Acc], Size + byte_size(Data), Deadline);
        {Port, {exit_status, 0}} ->
            {ok, iolist_to_binary(lists:reverse(Acc))};
        {Port, {exit_status, _}} ->
            {error, nil}
    after Remaining ->
        albedo_usage_core:kill(Port),
        {error, nil}
    end.
