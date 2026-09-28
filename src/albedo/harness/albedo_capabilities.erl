-module(albedo_capabilities).
-export([enabled/4, optional/4]).

%% A session override wins over a global default. Malformed preferences never
%% silently change the model's capabilities; composition fails and keeps the old one.
enabled(Home, Session, Kind, Name) ->
    Path = filename:join(Home, <<"capabilities.json">>),
    case file:read_file(Path) of
        {error, enoent} -> {ok, true};
        {ok, Bytes} when byte_size(Bytes) =< 1048576 ->
            try
                Config = json:decode(Bytes),
                Scoped = maps:get(Session, maps:get(<<"sessions">>, Config, #{}), #{}),
                Default = lookup(maps:get(<<"global">>, Config, #{}), Kind, Name, true),
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

%% A capability check only a selected session performs: an unscoped reader is
%% enabled unconditionally.
optional(undefined, _Home, _Kind, _Name) -> {ok, true};
optional(Session, Home, Kind, Name) -> enabled(Home, Session, Kind, Name).
