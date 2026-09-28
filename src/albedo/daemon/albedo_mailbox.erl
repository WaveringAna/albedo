%% Session mailbox registry: session id -> the closure its actor registered to
%% admit one letter.
%%
%% Letters are posted from outside any session actor (a kernel host route, an
%% HTTP request, another session finishing), so posting needs a lookup from
%% session id to the actor that can admit a turn. A closure answers the Gleam
%% Result(Bool, String): {ok, Queued} or {error, Reason}. A missing or crashed
%% session is not an error the sender must handle: the letter is durable, and
%% the dispatcher delivers it once the session is running.
-module(albedo_mailbox).
-export([register/2, forget/1, deliver/2, on_waiting/1, waiting/0]).

-define(TABLE, albedo_mailbox).

register(Id, Fun) -> albedo_registry:register(?TABLE, Id, Fun).

forget(Id) -> albedo_registry:forget(?TABLE, Id).

deliver(Id, Letter) ->
    albedo_registry:call(?TABLE, Id, 1, [Letter],
                         {error, <<"session unavailable">>},
                         {error, <<"session unavailable">>}).

%% The daemon's dispatcher: woken when a stored letter was not taken, instead
%% of waiting for its next tick.
on_waiting(Wake) -> persistent_term:put({?MODULE, dispatcher}, Wake), nil.

waiting() ->
    case persistent_term:get({?MODULE, dispatcher}, undefined) of
        undefined -> nil;
        Wake -> Wake(), nil
    end.
