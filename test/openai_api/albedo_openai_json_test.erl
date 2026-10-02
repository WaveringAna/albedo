%% FFI contracts include Erlang null aliases and tuples that JSON fixtures cannot produce.
-module(albedo_openai_json_test).
-include_lib("eunit/include/eunit.hrl").

semantically_empty_test_() ->
    [?_assertEqual(true, albedo_openai_json:semantically_empty(Value))
     || Value <- [null, nil, undefined, <<>>, [], {}, #{}]] ++
    [?_assertEqual(false, albedo_openai_json:semantically_empty(Value))
     || Value <- [false, true, 0, <<"x">>, [null], {null}, #{<<"id">> => null}]].

object_fields_test_() ->
    [?_assertEqual({ok, Value}, albedo_openai_json:object_fields(Value))
     || Value <- [#{}, #{<<"content">> => <<"hello">>, <<"opaque">> => [1, #{}]}]] ++
    [?_assertEqual({error, #{}}, albedo_openai_json:object_fields(Value))
     || Value <- [null, [], 42, <<"x">>, #{content => <<"hello">>},
                  #{<<"content">> => <<"hello">>, 1 => null}]].
