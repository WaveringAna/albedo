-module(albedo_discord).
-export([open/2, call/3, close/1, manager_name/0, token_user/1]).

%% The Python bot helper under priv/python runs as one port per enabled bot.
%% This owns the port, its line framing, and the request ids a bot's replies
%% answer. Every other line goes to `OnLine`, raw, for Gleam to decode.

-define(MAX_LINE, 65536).

manager_name() -> albedo_discord_manager.
%% Starts the process and answers once the port is open, so a missing python
%% or script is reported instead of a silent exit. The process closes its port
%% when the caller (the manager) goes away.
open(Env, OnLine) ->
    Parent = self(),
    Pid = spawn(fun() -> start(Parent, Env, OnLine) end),
    receive
        {Pid, opened} -> {ok, Pid};
        {Pid, {failed, Reason}} -> {error, Reason}
    after 10000 ->
        exit(Pid, kill),
        {error, <<"the bot process did not start">>}
    end.

start(Parent, Env, OnLine) ->
    Owner = erlang:monitor(process, Parent),
    case paths() of
        {ok, Python, Script} ->
            try open_port({spawn_executable, Python},
                          [binary, exit_status, use_stdio, hide, {line, ?MAX_LINE},
                           {args, ["-u", Script]},
                           {cd, filename:dirname(Script)},
                           {env, [{binary_to_list(K), binary_to_list(V)} || {K, V} <- Env]}]) of
                Port ->
                    Parent ! {self(), opened},
                    loop(#{port => Port, owner => Owner, on_line => OnLine, next => 1,
                           pending => #{}, partial => []})
            catch _:Reason ->
                Parent ! {self(), {failed, detail(Reason)}}
            end;
        {error, Reason} -> Parent ! {self(), {failed, Reason}}
    end.

paths() ->
    case {os:find_executable("python3"), code:priv_dir(albedo)} of
        {false, _} -> {error, <<"python3 not found on PATH">>};
        {_, {error, _}} -> {error, <<"albedo priv directory not found">>};
        {Python, Priv} -> {ok, Python, filename:absname(filename:join([Priv, "python", "albedo_discord.py"]))}
    end.

loop(S = #{port := Port, owner := Owner}) ->
    receive
        {'DOWN', Owner, process, _, _} ->
            shut(S);
        {Port, {data, {noeol, Chunk}}} ->
            loop(S#{partial := [Chunk | maps:get(partial, S)]});
        {Port, {data, {eol, Chunk}}} ->
            Line = iolist_to_binary(lists:reverse([Chunk | maps:get(partial, S)])),
            loop(line(S#{partial := []}, Line));
        {Port, {exit_status, Status}} ->
            finish(S, Status);
        {call, From, Ref, Request} ->
            loop(request(S, From, Ref, Request));
        {cancel, Ref} ->
            Pending = maps:filter(fun(_, {_, R}) -> R =/= Ref end, maps:get(pending, S)),
            loop(S#{pending := Pending});
        close ->
            shut(S)
    end.

shut(S = #{port := Port}) ->
    _ = try port_close(Port) catch _:_ -> ok end,
    fail_pending(S).

line(S = #{on_line := OnLine, pending := Pending}, Line) ->
    case decode(Line) of
        #{<<"type">> := <<"reply">>, <<"id">> := Id} = Reply when is_map_key(Id, Pending) ->
            {{From, Ref}, Rest} = maps:take(Id, Pending),
            From ! {Ref, outcome(Reply)},
            S#{pending := Rest};
        #{<<"type">> := <<"reply">>} -> S;
        #{} -> OnLine(Line), S;
        _ -> S
    end.

outcome(#{<<"ok">> := true} = Reply) ->
    {ok, iolist_to_binary(json:encode(maps:get(<<"result">>, Reply, null)))};
outcome(Reply) ->
    case maps:get(<<"error">>, Reply, null) of
        Error when is_binary(Error) -> {error, Error};
        _ -> {error, <<"the bot process refused the request">>}
    end.

request(S = #{port := Port, next := Id, pending := Pending}, From, Ref, Request) ->
    case decode(Request) of
        #{} = Map ->
            try port_command(Port, [json:encode(Map#{<<"id">> => Id}), $\n]) of
                _ -> S#{next := Id + 1, pending := Pending#{Id => {From, Ref}}}
            catch _:_ ->
                From ! {Ref, {error, <<"the bot process exited">>}},
                S
            end;
        _ ->
            From ! {Ref, {error, <<"invalid request">>}},
            S
    end.

finish(S = #{on_line := OnLine}, Status) ->
    fail_pending(S),
    OnLine(iolist_to_binary(json:encode(#{<<"type">> => <<"exited">>, <<"status">> => Status}))),
    ok.

fail_pending(#{pending := Pending}) ->
    maps:foreach(fun(_, {From, Ref}) ->
        From ! {Ref, {error, <<"the bot process exited">>}}
    end, Pending).

decode(Line) ->
    try json:decode(Line) catch _:_ -> invalid end.

%% A request answered by the bot process, or why it was not. The caller waits
%% at most `Timeout` milliseconds; a dead process fails at once.
call(Pid, Request, Timeout) ->
    Ref = erlang:monitor(process, Pid),
    Pid ! {call, self(), Ref, Request},
    receive
        {Ref, Outcome} ->
            erlang:demonitor(Ref, [flush]),
            Outcome;
        {'DOWN', Ref, process, Pid, _} ->
            {error, <<"the bot process is not running">>}
    after Timeout ->
        erlang:demonitor(Ref, [flush]),
        Pid ! {cancel, Ref},
        receive {Ref, _} -> ok after 0 -> ok end,
        {error, <<"timed out waiting for the bot process">>}
    end.

close(Pid) -> Pid ! close, nil.

%% The bot user id a token carries in its first segment (unpadded base64url).
token_user(Token) ->
    try
        [First | _] = binary:split(Token, <<".">>),
        Id = base64:decode(First, #{mode => urlsafe, padding => false}),
        case Id =/= <<>> andalso lists:all(fun(C) -> C >= $0 andalso C =< $9 end, binary_to_list(Id)) of
            true -> {ok, Id};
            false -> {error, nil}
        end
    catch _:_ -> {error, nil}
    end.

detail(Reason) -> unicode:characters_to_binary(io_lib:format("~p", [Reason])).
