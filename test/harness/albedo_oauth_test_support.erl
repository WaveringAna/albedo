-module(albedo_oauth_test_support).
-export([get/1, occupy/1, release/1]).

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
