-module(albedo_artifacts).
-export([bridge/0]).

%% The page bridge (priv/artifacts/bridge.js), read once per daemon.
bridge() ->
    case persistent_term:get({?MODULE, bridge}, undefined) of
        undefined ->
            Path = case code:priv_dir(albedo) of
                {error, _} -> "priv/artifacts/bridge.js";
                Dir -> filename:join([Dir, "artifacts", "bridge.js"])
            end,
            case file:read_file(Path) of
                {ok, Source} ->
                    persistent_term:put({?MODULE, bridge}, Source),
                    {ok, Source};
                {error, Reason} ->
                    {error, iolist_to_binary(io_lib:format("cannot read ~ts: ~p", [Path, Reason]))}
            end;
        Source -> {ok, Source}
    end.
