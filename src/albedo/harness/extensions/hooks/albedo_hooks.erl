%% Starts priv/python/albedo_hook_command.py for one hook event, when
%% hooks.json configures any command for it, and answers its verdict line.
-module(albedo_hooks).
-export([fire/3]).

%% The helper enforces each command's own timeout; this only stops waiting
%% on a helper that outlives every one of them.
-define(WAIT, 660000).

fire(Config, Event, Request) ->
    case configured(Config, Event) of
        false -> {ok, <<"{}">>};
        true -> run(Request)
    end.

%% A file that does not parse is configured: the helper reports it.
configured(Config, Event) ->
    case file:read_file(Config) of
        {error, _} -> false;
        {ok, Text} ->
            try json:decode(Text) of
                #{<<"hooks">> := #{Event := [_ | _]}} -> true;
                #{<<"hooks">> := #{}} -> false;
                _ -> true
            catch _:_ -> true
            end
    end.

run(Request) ->
    case albedo_python:local_paths() of
        {error, Reason} -> {error, unicode:characters_to_binary(io_lib:format("~p", [Reason]))};
        {ok, {Python, Kernel}} ->
            Helper = filename:join(filename:dirname(Kernel), <<"albedo_hook_command.py">>),
            try open_port({spawn_executable, binary_to_list(Python)},
                          [binary, exit_status, use_stdio, hide,
                           {args, ["-u", binary_to_list(Helper)]},
                           {env, albedo_python:clean_environment()}]) of
                Port ->
                    true = port_command(Port, [Request, $\n]),
                    collect(Port, [], erlang:monotonic_time(millisecond) + ?WAIT)
            catch _:Reason -> {error, unicode:characters_to_binary(io_lib:format("~p", [Reason]))}
            end
    end.

collect(Port, Output, Deadline) ->
    Left = Deadline - erlang:monotonic_time(millisecond),
    receive
        {Port, {data, Data}} -> collect(Port, [Output, Data], Deadline);
        {Port, {exit_status, 0}} -> {ok, string:trim(iolist_to_binary(Output))};
        {Port, {exit_status, Status}} ->
            {error, iolist_to_binary(io_lib:format("its helper exited ~p: ~ts", [Status, Output]))}
    after max(0, Left) ->
        try port_close(Port) catch _:_ -> ok end,
        {error, <<"its helper did not answer">>}
    end.
