-module(albedo_capabilities).
-export([enabled/4]).

%% A session override wins over a global default. Malformed preferences never
%% silently change the model's capabilities; composition fails and keeps the old one.
enabled(Home, Session, Kind, Name) ->
    Path = filename:join(Home, <<"capabilities.json">>),
    case file:read_file(Path) of
        {error, enoent} -> {ok, true};
        {ok, Bytes} when byte_size(Bytes) =< 1048576 ->
            try
                Config = json:decode(Bytes),
                Sessions = maps:get(<<"sessions">>, Config, #{}),
                Scoped = maps:get(Session, Sessions, #{}),
                Global = maps:get(<<"global">>, Config, #{}),
                Default = lookup(Global, Kind, Name, true),
                {ok, lookup(Scoped, Kind, Name, Default)}
            catch _:_ -> {error, <<"invalid capabilities.json">>} end;
        _ -> {error, <<"could not read capabilities.json">>}
    end.

lookup(Scope, Kind, Name, Default) ->
    case maps:find(Name, maps:get(Kind, Scope, #{})) of
        {ok, Value} when is_boolean(Value) -> Value;
        error -> Default;
        _ -> erlang:error(invalid_preference)
    end.
