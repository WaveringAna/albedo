-module(albedo_env_test_support).
-export([with_home/2, read/1]).

%% Runs Fun with ALBEDO_HOME pointing at Home, restoring the previous value, so
%% settings writes never reach the developer's real ~/.albedo.
with_home(Home, Fun) ->
    Previous = os:getenv("ALBEDO_HOME"),
    true = os:putenv("ALBEDO_HOME", unicode:characters_to_list(Home)),
    try Fun()
    after
        case Previous of
            false -> os:unsetenv("ALBEDO_HOME");
            Value -> os:putenv("ALBEDO_HOME", Value)
        end
    end.

read(Path) ->
    case file:read_file(Path) of
        {ok, Bytes} -> Bytes;
        _ -> <<>>
    end.
