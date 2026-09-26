-module(albedo_claude_files_test_server).
%% Mock Anthropic Files API server capturing one upload request.
-export([start/0, url/1, captured/1, stop/1]).

start() ->
    {ok, Listen} = gen_tcp:listen(0, [binary, {active, false},
        {reuseaddr, true}, {packet, raw}, {ip, {127, 0, 0, 1}}]),
    {ok, {_Address, Port}} = inet:sockname(Listen),
    Owner = self(),
    Pid = spawn(fun() -> serve(Listen, Owner) end),
    {fixture, Pid, Port}.

url({fixture, _, Port}) ->
    iolist_to_binary(io_lib:format("http://127.0.0.1:~B", [Port])).

captured({fixture, Pid, _}) ->
    receive
        {files_captured, Pid, Headers, Body} -> {ok, {Headers, Body}}
    after 2000 -> {error, nil}
    end.

stop({fixture, Pid, _}) ->
    exit(Pid, shutdown),
    nil.

serve(Listen, Owner) ->
    case gen_tcp:accept(Listen, 2000) of
        {ok, Socket} ->
            gen_tcp:close(Listen),
            case read_request(Socket, <<>>) of
                {ok, Headers, Body} ->
                    Owner ! {files_captured, self(), Headers, Body},
                    Metadata = iolist_to_binary(json:encode(#{
                        <<"id">> => <<"file-test-123">>,
                        <<"mime_type">> => <<"image/png">>,
                        <<"size_bytes">> => 24,
                        <<"expires_at">> => null
                    })),
                    Length = integer_to_binary(byte_size(Metadata)),
                    ok = gen_tcp:send(Socket, [
                        <<"HTTP/1.1 200 OK\r\ncontent-type: application/json\r\n">>,
                        <<"content-length: ">>, Length, <<"\r\n\r\n">>, Metadata
                    ]),
                    wait_for_close(Socket);
                _ ->
                    ok
            end;
        _ ->
            gen_tcp:close(Listen)
    end.

read_request(Socket, Acc) ->
    case binary:match(Acc, <<"\r\n\r\n">>) of
        {HeaderEnd, 4} ->
            <<Headers:HeaderEnd/binary, _Separator:4/binary, Rest/binary>> = Acc,
            Length = content_length(Headers),
            {ok, Headers, read_body(Socket, Rest, Length)};
        nomatch ->
            case gen_tcp:recv(Socket, 0, 2000) of
                {ok, Bytes} -> read_request(Socket, <<Acc/binary, Bytes/binary>>);
                Error -> Error
            end
    end.

content_length(Headers) ->
    Lines = binary:split(Headers, <<"\r\n">>, [global]),
    length_lines(Lines).

length_lines([]) -> 0;
length_lines([Line | Rest]) ->
    case binary:split(string:lowercase(Line), <<":">>) of
        [<<"content-length">>, Value] ->
            binary_to_integer(string:trim(Value));
        _ -> length_lines(Rest)
    end.

read_body(_Socket, Body, Length) when byte_size(Body) >= Length ->
    binary:part(Body, 0, Length);
read_body(Socket, Body, Length) ->
    case gen_tcp:recv(Socket, Length - byte_size(Body), 2000) of
        {ok, Bytes} -> read_body(Socket, <<Body/binary, Bytes/binary>>, Length);
        _ -> Body
    end.

wait_for_close(Socket) ->
    case gen_tcp:recv(Socket, 0, 2000) of
        {error, _} -> gen_tcp:close(Socket);
        {ok, _} -> wait_for_close(Socket)
    end.
