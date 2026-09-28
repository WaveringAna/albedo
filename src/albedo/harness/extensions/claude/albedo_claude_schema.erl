-module(albedo_claude_schema).
%% Anthropic requires an object input_schema without top-level combiners.
%% Keep property schemas intact; the harness still validates tool arguments.
-export([normalize/1]).

normalize(Json) ->
    case json:decode(iolist_to_binary(Json)) of
        Root when is_map(Root) -> json:encode(flatten(Root));
        _ -> json:encode(#{<<"type">> => <<"object">>, <<"properties">> => #{}})
    end.

flatten(Root) ->
    Keys = [<<"allOf">>, <<"oneOf">>, <<"anyOf">>],
    case lists:any(fun(K) -> maps:is_key(K, Root) end, Keys) of
        false -> Root;
        true ->
            All = branches(Root, <<"allOf">>),
            Unions = branches(Root, <<"oneOf">>) ++ branches(Root, <<"anyOf">>),
            Base = maps:without(Keys, Root),
            Props = lists:foldl(fun(B, P) -> maps:merge(properties(B), P) end,
                                properties(Base), All ++ Unions),
            Required = lists:usort(required(Base) ++
                lists:append([required(B) || B <- All]) ++ common_required(Unions)),
            describe_union(Base#{<<"type">> => <<"object">>, <<"properties">> => Props,
                                 <<"required">> => Required}, Root)
    end.

branches(Root, Key) ->
    case maps:get(Key, Root, []) of
        Values when is_list(Values) -> [V || V <- Values, is_map(V)];
        _ -> []
    end.

properties(Node) ->
    case maps:get(<<"properties">>, Node, #{}) of
        Props when is_map(Props) -> Props;
        _ -> #{}
    end.

required(Node) ->
    case maps:get(<<"required">>, Node, []) of
        Names when is_list(Names) -> [N || N <- Names, is_binary(N)];
        _ -> []
    end.

describe_union(Object, Root) ->
    Guidance = lists:filtermap(fun({Key, Prefix}) ->
        case [branch_hint(B) || B <- branches(Root, Key)] of
            [_, _ | _] = Alternatives ->
                case lists:member(<<>>, Alternatives) of
                    true -> false;
                    false ->
                        Text = iolist_to_binary(lists:join(<<" or ">>, Alternatives)),
                        {true, <<Prefix/binary, Text/binary>>}
                end;
            _ -> false
        end
    end, [{<<"oneOf">>, <<"Exactly one of: ">>},
          {<<"anyOf">>, <<"At least one of: ">>}]),
    case Guidance of
        [] -> Object;
        _ ->
            Existing = maps:get(<<"description">>, Object, <<>>),
            Object#{<<"description">> => iolist_to_binary(
                lists:join(<<"; ">>, [D || D <- [Existing | Guidance], D =/= <<>>]))}
    end.

branch_hint(Branch) ->
    Names = case required(Branch) of
        [] -> lists:sort(maps:keys(properties(Branch)));
        Required -> Required
    end,
    iolist_to_binary(lists:join(<<" + ">>, Names)).

common_required([]) -> [];
common_required([First | Rest]) ->
    [N || N <- required(First), lists:all(fun(B) -> lists:member(N, required(B)) end, Rest)].
