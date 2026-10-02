%% FFI contracts include Erlang null aliases and tuples that JSON fixtures cannot produce.
-module(albedo_openai_json_test).
-include_lib("eunit/include/eunit.hrl").

semantically_empty_test_() ->
    [?_assertEqual(true, albedo_openai_json:semantically_empty(Value))
     || Value <- [null, nil, undefined, <<>>, [], {}, #{}]] ++
    [?_assertEqual(false, albedo_openai_json:semantically_empty(Value))
     || Value <- [false, true, 0, <<"x">>, [null], {null}, #{<<"id">> => null}]].
