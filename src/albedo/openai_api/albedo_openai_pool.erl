-module(albedo_openai_pool).

%% Kept-alive HTTP/1.1 connections between requests, owned by one process
%% started on first use. A finished exchange may release its connection
%% before the response's last bytes (a chunked terminator) arrive; they are
%% read here, at most ?DRAIN_BYTES within ?DRAIN_MS, so the caller never
%% waits, and a request to the same host meanwhile waits for it rather than
%% opening another. An idle connection waits at most ?IDLE_MS, at most
%% ?IDLE_PER_HOST per host; one that closes or sends anything meanwhile is
%% dropped.

-export([checkout/1, checkin/5]).

-define(IDLE_MS, 60000).
-define(IDLE_PER_HOST, 8).
-define(DRAIN_MS, 5000).
-define(DRAIN_BYTES, 65536).
%% How long a checkout waits for a connection that is still draining before
%% opening its own; a new TLS connection costs about as much.
-define(WAIT_MS, 50).
-define(CALL_MS, 1000).

%% An idle connection to Key ({Transport, Host, Port}), now owned by the
%% caller and in passive mode, or none. When the only connections to Key are
%% still reading the end of a response, waits up to ?WAIT_MS for one.
checkout(Key) ->
    case whereis(?MODULE) of
        undefined -> none;
        Pool ->
            Ref = erlang:monitor(process, Pool),
            Pool ! {checkout, self(), Ref, Key},
            receive
                {Ref, Reply} -> erlang:demonitor(Ref, [flush]), Reply;
                {'DOWN', Ref, process, _, _} -> none
            after ?CALL_MS ->
                erlang:demonitor(Ref, [flush]),
                none
            end
    end.

%% Gives the pool a passive socket owned by the caller, partway through a
%% response in Framing with Buffer not yet framed.
checkin(Key, Transport, Socket, Framing, Buffer) ->
    Pool = pool(),
    case controlling_process(Transport, Socket, Pool) of
        ok -> Pool ! {checkin, Key, Transport, Socket, Framing, Buffer};
        {error, _} -> albedo_openai_transport:close_socket(Transport, Socket)
    end,
    ok.

pool() ->
    case whereis(?MODULE) of
        undefined ->
            Pid = spawn(fun() -> loop(#{}, []) end),
            try register(?MODULE, Pid) of
                true -> Pid
            catch error:badarg -> exit(Pid, kill), pool()
            end;
        Pid -> Pid
    end.

controlling_process(tcp, Socket, Pid) ->
    gen_tcp:controlling_process(Socket, Pid);
controlling_process(tls, Socket, Pid) -> ssl:controlling_process(Socket, Pid).

%% Conns maps each socket to #{key, transport, phase, since, timer}, where
%% phase is idle or {draining, Framing, Buffer, Read}: Read counts the body
%% bytes drained so far. Waiters are checkouts, oldest first, waiting for a
%% connection to their host that is still draining.
loop(Conns, Waiters) ->
    receive
        {checkout, From, Ref, Key} ->
            Timer = erlang:start_timer(?WAIT_MS, self(), {give_up, Ref}),
            serve(Conns, Waiters ++ [{From, Ref, Key, Timer}]);
        {checkin, Key, Transport, Socket, Framing, Buffer} ->
            Conn = #{key => Key, transport => Transport, since => 0,
                     phase => {draining, Framing, <<>>, 0},
                     timer => timer(?DRAIN_MS, Socket)},
            serve(settle(Socket, Conn, Buffer, Conns#{Socket => Conn}), Waiters);
        {Tag, Socket, Bytes} when Tag =:= tcp; Tag =:= ssl ->
            case Conns of
                #{Socket := #{phase := {draining, _, _, _}} = Conn} ->
                    serve(settle(Socket, Conn, Bytes, Conns), Waiters);
                #{} -> serve(drop(Socket, Conns), Waiters)
            end;
        {Tag, Socket} when Tag =:= tcp_closed; Tag =:= ssl_closed ->
            serve(drop(Socket, Conns), Waiters);
        {Tag, Socket, _} when Tag =:= tcp_error; Tag =:= ssl_error ->
            serve(drop(Socket, Conns), Waiters);
        {timeout, Timer, {expire, Socket}} ->
            case Conns of
                #{Socket := #{timer := Timer}} -> serve(drop(Socket, Conns), Waiters);
                #{} -> loop(Conns, Waiters)
            end;
        {timeout, _, {give_up, Ref}} ->
            {Gone, Rest} = lists:partition(fun({_, Id, _, _}) -> Id =:= Ref end, Waiters),
            [From ! {Ref, none} || {From, _, _, _} <- Gone],
            loop(Conns, Rest);
        _ -> loop(Conns, Waiters)
    end.

%% Answers every waiter that can be answered: with an idle connection to its
%% host, or none once no connection to its host is draining.
serve(Conns, Waiters) ->
    {Next, Waiting} = lists:foldl(fun({From, Ref, Key, Timer} = Waiter, {Acc, Kept}) ->
        case idle(Key, Acc) =:= [] andalso draining(Key, Acc) of
            true -> {Acc, [Waiter | Kept]};
            false ->
                erlang:cancel_timer(Timer),
                {Reply, Rest} = take(Key, From, Acc),
                From ! {Ref, Reply},
                {Rest, Kept}
        end
    end, {Conns, []}, Waiters),
    loop(Next, lists:reverse(Waiting)).

draining(Key, Conns) ->
    lists:any(fun(#{key := K, phase := P}) -> K =:= Key andalso P =/= idle end, maps:values(Conns)).

%% Reads Bytes into a draining connection; it turns idle once its response
%% ends with nothing after it.
settle(Socket, #{phase := {draining, Framing, Buffer, Read}, key := Key, timer := Timer} = Conn,
       Bytes, Conns) ->
    case albedo_openai_transport:unframe(Framing, <<Buffer/binary, Bytes/binary>>) of
        {_, done, <<>>} ->
            erlang:cancel_timer(Timer),
            Idle = Conn#{phase := idle, since := erlang:monotonic_time(),
                         timer := timer(?IDLE_MS, Socket)},
            arm(Socket, Idle, trim(Key, Conns#{Socket := Idle}));
        {Data, Next, Rest} when Next =/= done ->
            Total = Read + iolist_size(Data),
            case Total > ?DRAIN_BYTES of
                true -> drop(Socket, Conns);
                false ->
                    Draining = Conn#{phase := {draining, Next, Rest, Total}},
                    arm(Socket, Draining, Conns#{Socket := Draining})
            end;
        _ ->
            drop(Socket, Conns)
    end.

arm(Socket, #{transport := Transport}, Conns) ->
    case albedo_openai_transport:setopts(Transport, Socket, [{active, once}]) of
        ok -> Conns;
        {error, _} -> drop(Socket, Conns)
    end.

%% Keeps the newest ?IDLE_PER_HOST idle connections to Key.
trim(Key, Conns) ->
    Idle = idle(Key, Conns),
    Oldest = lists:nthtail(min(?IDLE_PER_HOST, length(Idle)), Idle),
    lists:foldl(fun drop/2, Conns, Oldest).

%% Idle sockets to Key, newest first.
idle(Key, Conns) ->
    Idle = [{Since, Socket}
            || Socket := #{key := K, phase := idle, since := Since} <- Conns, K =:= Key],
    [Socket || {_, Socket} <- lists:reverse(lists:sort(Idle))].

take(Key, From, Conns) ->
    case idle(Key, Conns) of
        [] -> {none, Conns};
        [Socket | _] ->
            #{transport := Transport, timer := Timer} = maps:get(Socket, Conns),
            Rest = maps:remove(Socket, Conns),
            erlang:cancel_timer(Timer),
            Passive = albedo_openai_transport:setopts(Transport, Socket, [{active, false}]),
            Handed = Passive =:= ok
                andalso not stirred(Socket)
                andalso controlling_process(Transport, Socket, From) =:= ok,
            case Handed of
                true -> {{ok, Socket}, Rest};
                false ->
                    albedo_openai_transport:close_socket(Transport, Socket),
                    take(Key, From, Rest)
            end
    end.

%% Whether an idle socket closed or sent something before it went passive.
stirred(Socket) ->
    receive
        {Tag, Socket} when Tag =:= tcp_closed; Tag =:= ssl_closed -> true;
        {Tag, Socket, _} when Tag =:= tcp; Tag =:= ssl;
                              Tag =:= tcp_error; Tag =:= ssl_error -> true
    after 0 -> false
    end.

drop(Socket, Conns) ->
    case maps:take(Socket, Conns) of
        {#{transport := Transport, timer := Timer}, Rest} ->
            erlang:cancel_timer(Timer),
            albedo_openai_transport:close_socket(Transport, Socket),
            Rest;
        error -> Conns
    end.

timer(Ms, Socket) -> erlang:start_timer(Ms, self(), {expire, Socket}).
