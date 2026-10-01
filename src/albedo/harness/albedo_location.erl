%% The native half of albedo/harness/location: a local directory check, and
%% the user `ssh -G` resolves for a host, for host labels. That user is kept
%% in a persistent term for the daemon's life, a miss included: there are a
%% handful of hosts, ssh config rarely changes, and a label is cosmetic, so
%% it never pays to ask again.
-module(albedo_location).

-export([is_directory/1, ssh_user/1]).

is_directory(Path) ->
    filename:pathtype(Path) =:= absolute andalso filelib:is_dir(Path).

ssh_user(Host) ->
    Key = {?MODULE, Host},
    case persistent_term:get(Key, undefined) of
        undefined ->
            User = lookup(Host),
            persistent_term:put(Key, User),
            User;
        User -> User
    end.

lookup(Host) ->
    case albedo_vcs:run(<<"ssh">>, [<<"-G">>, Host], <<"/">>, 2000) of
        {ok, Out} -> user(binary:split(Out, <<"\n">>, [global]));
        {error, nil} -> {error, nil}
    end.

user([<<"user ", User/binary>> | _]) -> {ok, string:trim(User)};
user([_ | Rest]) -> user(Rest);
user([]) -> {error, nil}.
