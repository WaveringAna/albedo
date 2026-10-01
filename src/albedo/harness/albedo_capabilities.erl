-module(albedo_capabilities).
-export([read/1]).

read(Home) ->
    Path = filename:join(Home, <<"capabilities.json">>),
    case file:read_file(Path) of
        {error, enoent} -> {ok, <<"{}">>};
        {ok, Bytes} when byte_size(Bytes) =< 1048576 ->
            {ok, Bytes};
        _ -> {error, <<"could not read capabilities.json">>}
    end.
