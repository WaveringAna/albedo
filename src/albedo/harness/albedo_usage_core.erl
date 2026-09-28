%% The I/O half of albedo/harness/usage_feed: usage-core is a pure Zig core,
%% so every byte of I/O happens here. One `usage advance -` process per round,
%% fed the envelope on stdin because it carries the credential; `http`
%% requests go through albedo_http; `command` requests run with an environment
%% allowlist, a timeout and a stdout cap. Nothing the envelope or a response
%% carries is ever logged: both can hold credentials.
-module(albedo_usage_core).

-export([advance/1, http_request/4, run_command/4, command_env/0, kill/1]).

-define(ADVANCE_TIMEOUT_MS, 15000).
-define(COMMAND_TIMEOUT_MS, 15000).
-define(COMMAND_TIMEOUT_CAP_MS, 60000).
-define(STDOUT_CAP, 65536).

%% PATH, HOME, locale, timezone and proxies: what a CLI needs to find and
%% speak to its own backend, and nothing that could leak this session.
-define(ALLOWED_ENV,
    ["PATH", "HOME", "LANG", "LC_ALL", "LC_CTYPE", "TZ",
     "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
     "http_proxy", "https_proxy", "all_proxy", "no_proxy"]).

%% One round. The envelope line is the whole message: the CLI stops reading
%% at the first newline, which is what an Erlang port needs (it cannot
%% half-close stdin), and stdout is read to exit. The last output line is
%% the step; the caller parses it, this side only moves bytes.
advance(Envelope) when is_binary(Envelope) ->
    case resolve() of
        false ->
            {error, <<"usage is not built; run nix build or put it on PATH">>};
        Bin ->
            Port = open_port({spawn_executable, Bin},
                             [{args, ["advance", "-"]}, exit_status, binary, hide]),
            Port ! {self(), {command, [Envelope, $\n]}},
            drain(Port, [], deadline(?ADVANCE_TIMEOUT_MS))
    end.

%% An `http` request through albedo's one front door. A transport failure is
%% data for the feed, not a driver failure: the protocol says "no response"
%% with status 0, and the reason travels in the body.
http_request(Method, Url, Headers, Body) ->
    RequestBody = case Body of
        none -> none;
        {some, Payload} -> {content_type(Headers), Payload}
    end,
    HeaderList = without_content_type(Headers),
    case albedo_http:request(method(Method), Url, HeaderList, RequestBody, 30000, 10000) of
        {ok, {Status, _ResponseHeaders, ResponseBody}} ->
            {Status, ResponseBody};
        {error, Reason} ->
            ReasonText = unicode:characters_to_binary(io_lib:format("~0p", [Reason])),
            {0, ReasonText}
    end.

%% A `command` request, run with only the allowed environment, a timeout and
%% a stdout cap. 127 is reserved for "this host will not run commands", so a
%% command that cannot run or timed out answers 126: the feed routes around
%% either the same way.
run_command(Command, Args, Stdin, TimeoutMs) ->
    Timeout = case TimeoutMs of
        {some, Ms} when is_integer(Ms), Ms > 0 -> min(Ms, ?COMMAND_TIMEOUT_CAP_MS);
        _ -> ?COMMAND_TIMEOUT_MS
    end,
    case executable(Command) of
        false ->
            Body = iolist_to_binary([Command, <<" is not on PATH">>]),
            {126, Body};
        Exe ->
            Port = open_port({spawn_executable, Exe},
                             [{args, Args}, exit_status, binary, hide, {env, command_env()}]),
            case Stdin of
                {some, Data} -> Port ! {self(), {command, Data}};
                none -> ok
            end,
            case drain_capped(Port, [], 0, deadline(Timeout)) of
                {ok, Result} -> Result;
                timeout -> {126, <<"the command timed out">>}
            end
    end.

%% ALBEDO_USAGE_CORE overrides resolution, so tests can point at a fake; the
%% shipped binary sits in priv/bin beside albedo-render, and PATH is the last
%% resort.
resolve() ->
    case os:getenv("ALBEDO_USAGE_CORE") of
        Override when Override =/= false, Override =/= "" ->
            case filelib:is_file(Override) of
                true -> Override;
                false -> on_path(Override)
            end;
        _ ->
            Bin = case code:priv_dir(albedo) of
                {error, _} -> false;
                Priv -> filename:join(Priv, "bin/usage")
            end,
            case is_file(Bin) of
                true -> Bin;
                false -> on_path("usage")
            end
    end.

%% os:find_executable wants a list, and the commands arrive as binaries.
on_path(Name) ->
    os:find_executable(unicode:characters_to_list(Name)).

is_file(false) -> false;
is_file(Path) -> filelib:is_file(Path).

%% A path in the command is used as given; a bare name is looked up on PATH.
executable(Command) ->
    case binary:match(Command, <<"/">>) of
        nomatch -> on_path(Command);
        _ -> case filelib:is_file(Command) of
            true -> Command;
            false -> on_path(Command)
        end
    end.

%% open_port's {env, ...} adds to the inherited environment rather than
%% replacing it, so every other variable is removed by name: the allowlist is
%% the whole environment a command sees.
command_env() ->
    lists:map(
        fun({K, V}) ->
            case lists:member(K, ?ALLOWED_ENV) of
                true -> {K, V};
                false -> {K, false}
            end
        end,
        os:env()).

method(Method) ->
    binary_to_atom(string:lowercase(Method), utf8).

%% httpc wants the body's content type in the request tuple rather than the
%% header list, so it moves there and the rest travel as headers.
content_type(Headers) ->
    case [V || {K, V} <- Headers, is_content_type(K)] of
        [Type | _] -> unicode:characters_to_list(Type);
        [] -> "application/json"
    end.

without_content_type(Headers) ->
    [{K, V} || {K, V} <- Headers, not is_content_type(K)].

is_content_type(K) ->
    string:equal(string:lowercase(K), "content-type").

%% A receive's `after` is an idle timeout: a child that trickles a byte now
%% and then never trips it. The deadline is computed once and counts down
%% across every chunk.
deadline(Timeout) ->
    erlang:monotonic_time(millisecond) + Timeout.

remaining(Deadline) ->
    max(0, Deadline - erlang:monotonic_time(millisecond)).

drain(Port, Acc, Deadline) ->
    receive
        {Port, {data, Data}} -> drain(Port, [Data | Acc], Deadline);
        {Port, {exit_status, 0}} ->
            catch erlang:port_close(Port),
            {ok, iolist_to_binary(lists:reverse(Acc))};
        {Port, {exit_status, Status}} ->
            catch erlang:port_close(Port),
            Text = integer_to_binary(Status),
            {error, <<"the usage CLI exited with status ", Text/binary>>}
    after remaining(Deadline) ->
        kill(Port),
        {error, <<"the usage CLI timed out">>}
    end.

%% Stdout up to the cap, then discarded, so a runaway command cannot fill
%% memory. Stderr is not merged: the body the feed sees stays stdout only.
drain_capped(Port, Acc, Size, Deadline) ->
    receive
        {Port, {data, Data}} ->
            {Kept, Size2} = cap(Size, Data),
            drain_capped(Port, [Kept | Acc], Size2, Deadline);
        {Port, {exit_status, Status}} ->
            catch erlang:port_close(Port),
            {ok, {Status, iolist_to_binary(lists:reverse(Acc))}}
    after remaining(Deadline) ->
        kill(Port),
        timeout
    end.

%% port_close closes the pipes; a child blocked on the network would keep
%% running. The child is ours, so the timeout path takes its pid and sends
%% KILL. A pid that already exited and was reaped makes kill itself fail,
%% which is the outcome we wanted anyway.
kill(Port) ->
    Pid = case erlang:port_info(Port, os_pid) of
        {os_pid, OsPid} when is_integer(OsPid) -> OsPid;
        _ -> false
    end,
    catch erlang:port_close(Port),
    case Pid of
        false -> ok;
        _ ->
            Killer = open_port({spawn_executable, "/bin/kill"},
                               [{args, ["-KILL", integer_to_list(Pid)]},
                                exit_status, binary, hide]),
            receive
                {Killer, {exit_status, _}} -> ok
            after 1000 ->
                catch erlang:port_close(Killer)
            end
    end.

cap(Size, _Data) when Size >= ?STDOUT_CAP ->
    {<<>>, Size};
cap(Size, Data) ->
    Room = ?STDOUT_CAP - Size,
    case byte_size(Data) =< Room of
        true -> {Data, Size + byte_size(Data)};
        false -> {binary:part(Data, 0, Room), ?STDOUT_CAP}
    end.
