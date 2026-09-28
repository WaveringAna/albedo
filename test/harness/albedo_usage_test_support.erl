%% A fake usage CLI, a local HTTP endpoint and a command whose whole job is to
%% dump the environment it ran with: the three things usage_feed's loop has to
%% get right (envelope on stdin, responses replayed, allowlist on commands)
%% without a real provider, a real credential or the network.
%%
%% ALBEDO_USAGE_CORE points the driver's binary resolution at the fake, so the
%% daemon is never involved: no route exercises this loop end to end yet.
-module(albedo_usage_test_support).

-export([start/0, stop/1, envelope/1, env_dump/1, request_line/1,
         break_binary/1, mono_ms/0, trickle_pid_gone/1]).

%% eunit runs a module's tests in parallel ({inparallel, _} reaches into the
%% module), and ALBEDO_USAGE_CORE is one global environment variable, so the
%% fakes must not overlap. A registered name is the lock: it is held from
%% start to stop, and the death of a crashed test process releases it.
-define(LOCK, albedo_usage_fake).

start() ->
    await_lock(),
    Dir = filename:join(tmp(), "albedo-usage-" ++ os:getpid() ++ "-"
                              ++ integer_to_list(erlang:unique_integer([positive]))),
    ok = file:make_dir(Dir),
    {ok, Listen} = gen_tcp:listen(0, [binary, {active, false}, {reuseaddr, true}, {packet, raw}]),
    {ok, {_Address, Port}} = inet:sockname(Listen),
    Server = spawn(fun() -> serve(Listen, []) end),
    Url = io_lib:format("http://127.0.0.1:~B/usage", [Port]),
    Usage = filename:join(Dir, "usage"),
    Dump = filename:join(Dir, "env-dump.sh"),
    Trickle = filename:join(Dir, "trickle.sh"),
    write(Usage, fake_usage(Url, Dump, Trickle, filename:join(Dir, "envelope.txt"))),
    write(Dump, ["#!/bin/sh\nenv >", filename:join(Dir, "env.txt"), "\necho dumped\n"]),
    %% Prints its own pid, then a line forever: a command that always has
    %% output but never exits, for the deadline-kill test.
    write(Trickle, ["#!/bin/sh\necho $$ >", filename:join(Dir, "trickle.pid"),
                    "\nwhile true; do\n  echo tick\n  sleep 0.2\ndone\n"]),
    ok = file:change_mode(Usage, 8#755),
    ok = file:change_mode(Dump, 8#755),
    ok = file:change_mode(Trickle, 8#755),
    os:putenv("ALBEDO_USAGE_CORE", Usage),
    os:putenv("ALBEDO_USAGE_TEST_CANARY", "leak"),
    {ok, #{dir => Dir, listen => Listen, server => Server,
           envelope => filename:join(Dir, "envelope.txt"),
           env => filename:join(Dir, "env.txt"),
           trickle_pid => filename:join(Dir, "trickle.pid")}}.

stop(Ref) ->
    exit(maps:get(server, Ref), kill),
    gen_tcp:close(maps:get(listen, Ref)),
    os:unsetenv("ALBEDO_USAGE_CORE"),
    os:unsetenv("ALBEDO_USAGE_TEST_CANARY"),
    _ = file:del_dir_r(maps:get(dir, Ref)),
    catch unregister(?LOCK),
    nil.

await_lock() ->
    case whereis(?LOCK) of
        Pid when is_pid(Pid) ->
            Ref = erlang:monitor(process, Pid),
            receive
                {'DOWN', Ref, process, Pid, _} -> ok
            after 15000 ->
                exit(usage_fake_lock_timeout)
            end,
            await_lock();
        undefined ->
            try register(?LOCK, self()) of
                true -> ok
            catch
                _:_ -> await_lock()
            end
    end.

envelope(Ref) ->
    read(maps:get(envelope, Ref)).

env_dump(Ref) ->
    read(maps:get(env, Ref)).

request_line(Ref) ->
    Server = maps:get(server, Ref),
    Server ! {requests, self()},
    receive
        {requests, Server, Lines} -> Lines
    after 2000 -> []
    end.

%% Points resolution at a path that does not exist: the override must be
%% authoritative, never silently falling back to PATH.
break_binary(Ref) ->
    os:putenv("ALBEDO_USAGE_CORE", filename:join(maps:get(dir, Ref), "not-there")),
    nil.

mono_ms() ->
    erlang:monotonic_time(millisecond).

%% The trickle command is killed on timeout, not orphaned: its pid stops
%% answering signal 0. The beam reaps its port children asynchronously, so
%% the check polls briefly rather than asserting the very first probe.
trickle_pid_gone(Ref) ->
    Path = maps:get(trickle_pid, Ref),
    case file:read_file(Path) of
        {ok, Bin} ->
            Pid = binary_to_integer(string:trim(Bin)),
            gone(Pid, 20);
        _ ->
            false
    end.

gone(Pid, 0) ->
    signal(Pid) =/= 0;
gone(Pid, N) ->
    case signal(Pid) of
        0 -> timer:sleep(50), gone(Pid, N - 1);
        _ -> true
    end.

%% Exit status of `kill -0 Pid`: 0 while the process exists.
signal(Pid) ->
    Port = open_port({spawn_executable, "/bin/kill"},
                     [{args, ["-0", integer_to_list(Pid)]}, exit_status, binary, hide]),
    receive
        {Port, {exit_status, Status}} -> Status
    after 1000 ->
        catch erlang:port_close(Port),
        0
    end.

read(Path) ->
    case file:read_file(Path) of
        {ok, Bin} -> Bin;
        _ -> <<>>
    end.

write(Path, Content) ->
    ok = file:write_file(Path, Content).

tmp() ->
    case os:getenv("TMPDIR") of
        false -> "/tmp";
        T -> T
    end.

%% The fake core speaks the real protocol: one envelope line in (the whole
%% history, on stdin), one step line out, and the provider name decides what
%% kind of feed it is. The default feed answers round one with an http request
%% and a command, and round two with a report built from the http body - so
%% the loop, the envelope and the command environment are all load-bearing.
fake_usage(Url, Dump, Trickle, EnvelopeLog) ->
    ["#!/usr/bin/env python3\n"
     "import json, sys\n"
     "line = sys.stdin.readline()\n"
     "open(", quote(EnvelopeLog), ", 'a').write(line)\n"
     "envelope = json.loads(line)\n"
     "provider = envelope.get('provider')\n"
     "responses = envelope.get('responses', [])\n"
     "if provider == 'endless':\n"
     "    step = {'requests': [{'kind': 'command', 'command': 'true', 'args': []}]}\n"
     "elif provider == 'broken':\n"
     "    step = {'report': {'limits': [], 'error': 'the provider is unreachable'}}\n"
     "elif provider == 'trickle':\n"
     "    if responses:\n"
     "        status = responses[-1][0]['status']\n"
     "        step = {'report': {'limits': [], 'error': 'command answered %d' % status}}\n"
     "    else:\n"
     "        step = {'requests': [\n"
     "            {'kind': 'command', 'command': ", quote(Trickle), ", 'args': [],\n"
     "             'timeoutMs': 1000}]}\n"
     "elif provider == 'missing-command' and responses:\n"
     "    status = responses[-1][0]['status']\n"
     "    step = {'report': {'limits': [], 'error': 'command answered %d' % status}}\n"
     "elif responses:\n"
     "    body = json.loads(responses[-1][0]['body'])\n"
     "    step = {'report': {\n"
     "        'accountId': 'acct-1', 'email': 'dawn@example.com', 'planType': 'token',\n"
     "        'limits': [{'id': 'five_hour', 'label': 'Session',\n"
     "                    'usedPercent': body['pct'], 'windowLabel': '5h window',\n"
     "                    'windowSeconds': 18000, 'resetsAt': 1893456000000,\n"
     "                    'status': 'ok'}],\n"
     "        'error': None}}\n"
     "elif provider == 'missing-command':\n"
     "    step = {'requests': [\n"
     "        {'kind': 'command', 'command': 'no-such-binary-xyz', 'args': []}]}\n"
     "else:\n"
     "    step = {'requests': [\n"
     "        {'kind': 'http', 'method': 'GET', 'url': ", quote(Url), ",\n"
     "         'headers': [['accept', 'application/json']]},\n"
     "        {'kind': 'command', 'command': ", quote(Dump), ", 'args': [],\n"
     "         'timeoutMs': 5000}]}\n"
     "print(json.dumps(step))\n"].

quote(Text) ->
    [$', Text, $'].

serve(Listen, Acc) ->
    receive
        {requests, From} ->
            From ! {requests, self(), lists:reverse(Acc)}
    after 0 ->
        ok
    end,
    case gen_tcp:accept(Listen, 200) of
        {ok, Socket} ->
            case read_head(Socket, <<>>) of
                {ok, Head} ->
                    [RequestLine | _] = binary:split(Head, <<"\r\n">>),
                    Body = <<"{\"pct\":37}">>,
                    ok = gen_tcp:send(Socket, [
                        <<"HTTP/1.1 200 OK\r\ncontent-type: application/json\r\n">>,
                        <<"content-length: ">>, integer_to_binary(byte_size(Body)),
                        <<"\r\n\r\n">>, Body]),
                    gen_tcp:close(Socket),
                    serve(Listen, [RequestLine | Acc]);
                _ ->
                    gen_tcp:close(Socket),
                    serve(Listen, Acc)
            end;
        {error, timeout} ->
            serve(Listen, Acc);
        _ ->
            ok
    end.

read_head(Socket, Acc) ->
    case binary:match(Acc, <<"\r\n\r\n">>) of
        nomatch ->
            case gen_tcp:recv(Socket, 0, 5000) of
                {ok, Bytes} -> read_head(Socket, <<Acc/binary, Bytes/binary>>);
                Error -> Error
            end;
        _ ->
            {ok, Acc}
    end.
