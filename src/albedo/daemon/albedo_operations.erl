-module(albedo_operations).
-export([validate_id/2, decode_display/1]).

validate_id(Id, Now) ->
    case re:run(Id, <<"^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$">>, [{capture, none}]) of
        match ->
            <<First:8/binary, "-", Second:4/binary, _/binary>> = Id,
            Timestamp = binary_to_integer(<<First/binary, Second/binary>>, 16),
            if
                Timestamp > Now + 300000 -> {error, <<"operation_future">>};
                Timestamp < Now - 604800000 -> {error, <<"operation_expired">>};
                true -> {ok, nil}
            end;
        _ -> {error, <<"operation_invalid">>}
    end.

decode_display(Payload) -> binary_to_term(Payload, [safe]).
