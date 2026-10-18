%% Runs a child session's verifier command in its workspace and own process
%% group, returning {ok, <<>>} on exit 0 or {error, Detail} when the gate fails.
-module(albedo_verifier).
-export([check/2]).

-define(WAIT, 305000).

check(Cwd, Command) ->
    case albedo_python:local_paths() of
        {error, Reason} ->
            {error, unicode:characters_to_binary(io_lib:format("~p", [Reason]))};
        {ok, {Python, Kernel}} ->
            Helper = filename:join(filename:dirname(Kernel), <<"albedo_verifier.py">>),
            Request = iolist_to_binary(json:encode(#{cwd => Cwd, command => Command})),
            try open_port({spawn_executable, binary_to_list(Python)},
                          [binary, exit_status, use_stdio, hide,
                           {args, ["-u", binary_to_list(Helper)]},
                           {env, albedo_python:clean_environment()}]) of
                Port ->
                    true = port_command(Port, [Request, $\n]),
                    collect(Port, [], erlang:monotonic_time(millisecond) + ?WAIT)
            catch _:Reason ->
                {error, unicode:characters_to_binary(io_lib:format("~p", [Reason]))}
            end
    end.

collect(Port, Output, Deadline) ->
    Left = Deadline - erlang:monotonic_time(millisecond),
    receive
        {Port, {data, Data}} -> collect(Port, [Output, Data], Deadline);
        {Port, {exit_status, 0}} -> {ok, <<>>};
        {Port, {exit_status, _}} ->
            {error, string:trim(iolist_to_binary(Output))}
    after max(0, Left) ->
        try port_close(Port) catch _:_ -> ok end,
        {error, <<"verifier timed out">>}
    end.
