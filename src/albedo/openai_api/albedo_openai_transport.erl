-module(albedo_openai_transport).

-export([open/4, receive_message/1, close/1, with_connection/2]).

-define(FLOW, 1).

open(URL, Headers, Body, Timeout)
        when is_binary(URL), is_list(Headers), is_integer(Timeout), Timeout > 0 ->
    case parse_url(URL) of
        {ok, Request} -> open_request(Request, Headers, Body, Timeout);
        error -> {error, invalid_url}
    end;
open(_, _, _, _) ->
    {error, invalid_url}.

open_request(#{host := Host, port := Port, target := Target,
        transport := Transport, protocols := Protocols}, Headers, Body, Timeout) ->
    case application:ensure_all_started(gun) of
        {ok, _} ->
            Options = #{
                connect_timeout => Timeout,
                domain_lookup_timeout => Timeout,
                protocols => Protocols,
                retry => 0,
                supervise => true,
                tls_handshake_timeout => Timeout,
                tls_opts => tls_options(Transport),
                transport => Transport
            },
            case gun:open(Host, Port, Options) of
                {ok, Pid} ->
                    unlink(Pid),
                    Monitor = erlang:monitor(process, Pid),
                    await_connection(Pid, Monitor, Target, Headers, Body, Timeout);
                {error, Reason} ->
                    transport_error(<<"connection open failed">>, Reason)
            end;
        {error, Reason} ->
            transport_error(<<"could not start HTTP transport">>, Reason)
    end.

await_connection(Pid, Monitor, Target, Headers, Body, Timeout) ->
    case gun:await_up(Pid, Timeout, Monitor) of
        {ok, _Protocol} ->
            start_request(Pid, Monitor, Target, Headers, Body, Timeout);
        {error, timeout} ->
            cleanup(Pid, Monitor),
            {error, timed_out};
        {error, Reason} ->
            cleanup(Pid, Monitor),
            transport_error(<<"connection failed">>, Reason)
    end.

start_request(Pid, Monitor, Target, Headers, Body, Timeout) ->
    try gun:post(Pid, Target, Headers, Body, #{flow => ?FLOW}) of
        Stream ->
            {ok, {connection, self(), Pid, Stream, Monitor, Timeout}}
    catch
        _Class:_Reason ->
            cleanup(Pid, Monitor),
            {error, {transport_error, <<"request failed">>}}
    end.

receive_message({connection, Owner, Pid, Stream, Monitor, Timeout})
        when Owner =:= self() ->
    case gun:await(Pid, Stream, Timeout, Monitor) of
        {inform, _Status, _Headers} ->
            receive_message({connection, Owner, Pid, Stream, Monitor, Timeout});
        {response, IsFin, Status, Headers} ->
            {ok, {headers, Status, Headers, IsFin =:= fin}};
        {data, IsFin, Bytes} ->
            maybe_replenish(IsFin, Pid, Stream),
            {ok, {data, Bytes, IsFin =:= fin}};
        {trailers, _Headers} ->
            {ok, {data, <<>>, true}};
        {error, timeout} ->
            {error, timed_out};
        {error, Reason} ->
            transport_error(<<"response failed">>, Reason);
        _Other ->
            receive_message({connection, Owner, Pid, Stream, Monitor, Timeout})
    end;
receive_message({connection, _, _, _, _, _}) ->
    {error, {transport_error, <<"connection used by a process that does not own it">>}}.

maybe_replenish(nofin, Pid, Stream) ->
    gun:update_flow(Pid, Stream, ?FLOW);
maybe_replenish(fin, _, _) ->
    ok.

close(Connection = {connection, Owner, _Pid, _Stream, _Monitor, _Timeout})
        when Owner =:= self() ->
    close_owned(Connection);
close({connection, _, Pid, _, _, _}) ->
    ignore_failure(fun() -> gun:close(Pid) end),
    nil.

close_owned({connection, _Owner, Pid, Stream, Monitor, _Timeout}) ->
    ignore_failure(fun() -> gun:cancel(Pid, Stream) end),
    ignore_failure(fun() -> gun:close(Pid) end),
    erlang:demonitor(Monitor, [flush]),
    gun:flush(Pid),
    nil.

with_connection(Connection, Run) ->
    try Run()
    after close(Connection)
    end.

cleanup(Pid, Monitor) ->
    ignore_failure(fun() -> gun:close(Pid) end),
    erlang:demonitor(Monitor, [flush]),
    gun:flush(Pid),
    ok.

ignore_failure(Run) ->
    try Run() of
        _ -> ok
    catch
        _:_ -> ok
    end.

%% Gun augments verify_peer with OTP system CAs, HTTPS hostname matching and SNI.
tls_options(tls) ->
    [{verify, verify_peer}];
tls_options(tcp) ->
    [].

parse_url(URL) ->
    try uri_string:parse(URL) of
        URI when is_map(URI) -> validate_url(URI);
        _ -> error
    catch
        _:_ -> error
    end.

validate_url(URI) ->
    Scheme = lowercase(maps:get(scheme, URI, <<>>)),
    Host = maps:get(host, URI, <<>>),
    case {transport(Scheme), valid_host(Host), forbidden_parts(URI), valid_port(URI)} of
        {{ok, Transport, DefaultPort, Protocols}, true, false, {ok, Port}} ->
            {ok, #{
                host => binary_to_list(Host),
                port => choose_port(Port, DefaultPort),
                protocols => Protocols,
                target => request_target(URI),
                transport => Transport
            }};
        _ ->
            error
    end.

transport(<<"https">>) -> {ok, tls, 443, [http2, http]};
transport(<<"http">>) -> {ok, tcp, 80, [http]};
transport(_) -> error.

valid_host(Host) -> is_binary(Host) andalso byte_size(Host) > 0.

forbidden_parts(URI) ->
    maps:is_key(userinfo, URI) orelse maps:is_key(fragment, URI).

valid_port(URI) ->
    case maps:get(port, URI, undefined) of
        undefined -> {ok, undefined};
        Port when is_integer(Port), Port > 0, Port =< 65535 -> {ok, Port};
        _ -> error
    end.

choose_port(undefined, Default) -> Default;
choose_port(Port, _) -> Port.

request_target(URI) ->
    Path = case maps:get(path, URI, <<>>) of
        <<>> -> <<"/">>;
        Value -> Value
    end,
    case maps:get(query, URI, undefined) of
        undefined -> Path;
        Query -> [Path, <<"?">>, Query]
    end.

lowercase(Binary) when is_binary(Binary) ->
    string:lowercase(Binary);
lowercase(_) ->
    <<>>.

transport_error(Context, Reason) ->
    Detail = unicode:characters_to_binary(io_lib:format("~0p", [Reason])),
    {error, {transport_error, <<Context/binary, ": ", Detail/binary>>}}.
