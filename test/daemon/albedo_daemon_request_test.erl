%% Exact exception classification cannot be asserted through HTTP: application
%% panics and disappearing actor handles must have different failure behavior.
-module(albedo_daemon_request_test).
-include_lib("eunit/include/eunit.hrl").

closed_actor_calls_are_unavailable_test() ->
    lists:foreach(fun(Message) ->
        Reason = #{module => <<"gleam/erlang/process">>,
                   function => <<"perform_call">>, message => Message},
        ?assertEqual({error,nil}, albedo_daemon:http_request(fun() ->
            erlang:error(Reason)
        end))
    end, [<<"callee exited: ProcessDown(..., Normal)">>,
          <<"Callee subject had no owner">>,
          <<"callee did not send reply before timeout">>]).

unrelated_errors_keep_their_reason_test() ->
    Reasons = [#{module => <<"application">>, function => <<"perform_call">>,
                 message => <<"callee exited: unrelated application error">>},
               #{module => <<"gleam/erlang/process">>,
                 function => <<"perform_call">>,
                 message => <<"callee did not send reply before timeout: application error">>},
               #{module => <<"gleam/erlang/process">>,
                 function => <<"application_call">>,
                 message => <<"callee did not send reply before timeout">>},
               application_bug],
    lists:foreach(fun(Reason) ->
        ?assertException(error,Reason,albedo_daemon:http_request(fun() ->
            erlang:error(Reason)
        end))
    end, Reasons),
    ?assertException(throw,application_bug,albedo_daemon:http_request(fun() ->
        throw(application_bug)
    end)).

ordinary_responses_pass_through_test() ->
    ?assertEqual({ok,response}, albedo_daemon:http_request(fun() -> response end)).
