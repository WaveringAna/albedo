-module(albedo_settings_lock).
-export([with_lock/3]).

%% One daemon owns each home. This lock serializes its settings mutations,
%% including credential updates. It is not a lock shared with CLI processes.
%% Nested operations in the same process retain the outer lock until it exits.
with_lock(Home, Run, Busy) ->
    Directory = unicode:characters_to_binary(directory(Home)),
    Key = {?MODULE, Directory},
    case get(Key) of
        held -> Run();
        _ ->
            Locked = fun() ->
                put(Key, held),
                try
                    case albedo_settings_store:recover(Directory) of
                        {ok, nil} -> Run();
                        Error -> Error
                    end
                after erase(Key) end
            end,
            case global:trans({Key, self()}, Locked, [node()], 8) of
                aborted -> Busy();
                Result -> Result
            end
    end.

%% The home as given when it is already absolute, which the daemon's is.
%% filename:absname/1 asks the OS for the working directory even then, and
%% that call fails when the process is out of file descriptors, which would
%% crash a settings read that otherwise reports its error.
directory(Home) ->
    case filename:pathtype(Home) of
        absolute -> Home;
        _ -> filename:absname(Home)
    end.
