%% The process half of albedo/harness/ssh: what each remote host looked like
%% when albedo last probed it, and the probes in flight. A probe is one run of
%% priv/python/albedo_ssh.py, the same ssh layer the model's remote plugin
%% uses, so both ride one ControlMaster per host.
%%
%% A ready answer is kept for a minute and a failure for five seconds; asking
%% again while a probe runs joins it instead of starting another.
-module(albedo_ssh).
-behaviour(gen_server).
-export([probe/2, peek/1, cached/1, forget/1, commands/2, exec/5, config_hosts/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(READY_MS, 60000).
-define(FAILED_MS, 5000).
-define(HELPER_MS, 170000). %% the helper's own probe and staging deadlines, and some

%% A fresh answer, or the one a probe started (or joined) now gives within
%% WaitMs. {error, nil} means it is still warming.
probe(Target, WaitMs) ->
    try gen_server:call(ensure(), {probe, Target}, WaitMs)
    catch exit:{timeout, _} -> {error, nil}
    end.

%% The cached answer, without waiting: a stale or missing one starts a probe
%% and reads as still warming.
peek(Target) -> gen_server:call(ensure(), {peek, Target}).

%% A fresh cached answer, never starting a probe.
cached(Target) -> gen_server:call(ensure(), {cached, Target}).

%% The Host names of ~/.ssh/config and its includes, as a JSON list.
config_hosts() ->
    case helper([<<"hosts">>], 5000) of
        {ok, Json} -> {ok, Json};
        {error, _} -> {error, nil}
    end.

forget(Target) -> gen_server:cast(ensure(), {forget, Target}), nil.

%% The commands for a host whose home is known, built locally (no network).
commands(Target, Home) ->
    case helper([<<"commands">>, Target, Home], 10000) of
        {ok, Json} -> {ok, Json};
        {error, _} -> {error, nil}
    end.

%% One remote command over ssh (Argv ends with the target), Input written to
%% its stdin: its stdout once it exits 0 within TimeoutMs, else why not.
exec(Argv, Command, AuthSock, Input, TimeoutMs) ->
    [Ssh | Options] = Argv,
    Env = case AuthSock of
        {some, Sock} -> [{"SSH_AUTH_SOCK", binary_to_list(Sock)} | albedo_python:clean_environment()];
        none -> albedo_python:clean_environment()
    end,
    case os:find_executable(binary_to_list(Ssh)) of
        false -> {error, <<"ssh not found on PATH">>};
        Exe ->
            try open_port({spawn_executable, Exe},
                          [binary, exit_status, use_stdio, hide,
                           {args, [binary_to_list(A) || A <- Options ++ [Command]]},
                           {env, Env}]) of
                Port ->
                    _ = (catch port_command(Port, Input)),
                    case collect(Port, [], erlang:monotonic_time(millisecond) + TimeoutMs) of
                        {ok, Out} -> {ok, Out};
                        {error, Why} -> {error, unicode:characters_to_binary(Why)}
                    end
            catch _:Reason -> {error, unicode:characters_to_binary(io_lib:format("~p", [Reason]))}
            end
    end.

ensure() ->
    case gen_server:start({local, ?MODULE}, ?MODULE, [], []) of
        {ok, Pid} -> Pid;
        {error, {already_started, Pid}} -> Pid
    end.

init([]) -> {ok, #{hosts => #{}, running => #{}}}.

handle_call({probe, Target}, From, S) ->
    case fresh(Target, S) of
        {ok, Json} -> {reply, {ok, Json}, S};
        none -> {noreply, start(Target, From, S)}
    end;
handle_call({cached, Target}, _, S) ->
    case fresh(Target, S) of
        {ok, Json} -> {reply, {ok, Json}, S};
        none -> {reply, {error, nil}, S}
    end;
handle_call({peek, Target}, _, S) ->
    case fresh(Target, S) of
        {ok, Json} -> {reply, {ok, Json}, S};
        none -> {reply, {error, nil}, start(Target, none, S)}
    end.

handle_cast({forget, Target}, S = #{hosts := Hosts}) ->
    {noreply, S#{hosts => maps:remove(Target, Hosts)}}.

handle_info({probed, Target, Json}, S = #{hosts := Hosts, running := Running}) ->
    Waiters = maps:get(Target, Running, []),
    [gen_server:reply(From, {ok, Json}) || From <- Waiters],
    Now = erlang:monotonic_time(millisecond),
    {noreply, S#{hosts => Hosts#{Target => {Json, Now + ttl(Json)}},
                 running => maps:remove(Target, Running)}};
handle_info(_, S) -> {noreply, S}.

fresh(Target, #{hosts := Hosts}) ->
    Now = erlang:monotonic_time(millisecond),
    case maps:get(Target, Hosts, none) of
        {Json, Until} when Until > Now -> {ok, Json};
        _ -> none
    end.

start(Target, From, S = #{running := Running}) ->
    Waiters = [W || W <- [From], W =/= none],
    case maps:find(Target, Running) of
        {ok, Earlier} -> S#{running => Running#{Target => Waiters ++ Earlier}};
        error ->
            Self = self(),
            spawn(fun() -> Self ! {probed, Target, run(Target)} end),
            S#{running => Running#{Target => Waiters}}
    end.

ttl(Json) ->
    case catch json:decode(Json) of
        #{<<"state">> := <<"ready">>} -> ?READY_MS;
        _ -> ?FAILED_MS
    end.

run(Target) ->
    case helper([<<"probe">>, Target], ?HELPER_MS) of
        {ok, Json} -> Json;
        {error, Why} -> failed(Why)
    end.

%% One run of albedo_ssh.py: its stdout, or why there is none.
helper(Args, Wait) ->
    case albedo_python:local_paths() of
        {ok, {Python, Kernel}} ->
            Helper = filename:join(filename:dirname(Kernel), <<"albedo_ssh.py">>),
            try open_port({spawn_executable, binary_to_list(Python)},
                          [binary, exit_status, use_stdio, hide,
                           {args, ["-u", binary_to_list(Helper) | [binary_to_list(A) || A <- Args]]},
                           {env, albedo_python:clean_environment()}]) of
                Port -> collect(Port, [], erlang:monotonic_time(millisecond) + Wait)
            catch _:Reason -> {error, io_lib:format("~p", [Reason])}
            end;
        {error, {unavailable, Why}} -> {error, Why}
    end.

collect(Port, Acc, Deadline) ->
    receive
        {Port, {data, Data}} -> collect(Port, [Data | Acc], Deadline);
        {Port, {exit_status, 0}} -> {ok, iolist_to_binary(lists:reverse(Acc))};
        {Port, {exit_status, Status}} -> {error, io_lib:format("albedo_ssh.py exited ~p", [Status])}
    after max(0, Deadline - erlang:monotonic_time(millisecond)) ->
        _ = try port_close(Port) catch _:_ -> ok end,
        {error, "albedo_ssh.py timed out"}
    end.

failed(Why) ->
    iolist_to_binary(json:encode(#{state => <<"unreachable">>,
                                   detail => unicode:characters_to_binary(Why)})).
