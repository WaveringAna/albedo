-module(albedo_oauth_test_support).
-export([get/1, occupy/1, release/1, identity/0]).

get(Url) ->
    _ = application:ensure_all_started(inets),
    case httpc:request(get, {binary_to_list(Url), []}, [{timeout, 5000}], [{body_format, binary}]) of
        {ok, {{_, Status, _}, _, _}} -> Status;
        _ -> 0
    end.

occupy(Port) ->
    {ok, Socket} = gen_tcp:listen(Port, [{ip, {127, 0, 0, 1}}]),
    {ok, {_, Bound}} = inet:sockname(Socket),
    {Socket, Bound}.

release({Socket, _}) -> gen_tcp:close(Socket), nil.

identity() ->
    <<Timestamp:48>> = <<(erlang:system_time(millisecond)):48>>,
    <<RandomA:12, RandomB:62, _:6>> = crypto:strong_rand_bytes(10),
    Hex = binary:encode_hex(<<Timestamp:48,7:4,RandomA:12,2:2,RandomB:62>>, lowercase),
    <<A:8/binary,B:4/binary,C:4/binary,D:4/binary,E:12/binary>> = Hex,
    <<A/binary,"-",B/binary,"-",C/binary,"-",D/binary,"-",E/binary>>.
