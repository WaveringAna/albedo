%% Replace a real session actor and wait until its old lifetime has ended.
-module(albedo_stream_replay_probe).
-export([restart/1]).

restart(Id) ->
    {some, Session} = 'albedo@daemon@session':live(Id),
    {ok, Pid} = 'gleam@erlang@process':subject_owner(Session),
    Monitor = monitor(process, Pid),
    exit(Pid, kill),
    receive
        {'DOWN', Monitor, process, Pid, killed} -> <<"actor_stopped">>
    after 10000 -> error(actor_still_alive)
    end.
