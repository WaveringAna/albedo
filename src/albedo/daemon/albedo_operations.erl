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

%% Record tags must exist before safe ETF decoding in a restarted VM.
%% Displays saved before messages held several images carry an option.
decode_display(Payload) ->
    case binary_to_term(Payload, [safe]) of
        {display, Text, Source, ClientId, OperationId, Images}
          when is_binary(Text), is_binary(Source), is_binary(ClientId) ->
            case OperationId of none -> ok; {some, Id} when is_binary(Id) -> ok end,
            Listed = case Images of
                none -> [];
                {some, Image} -> [Image];
                _ when is_list(Images) -> Images
            end,
            [ok = image_metadata(Image) || Image <- Listed],
            {display, Text, Source, ClientId, OperationId, Listed}
    end.

image_metadata({image_metadata, Mime, Width, Height, Bytes})
  when is_binary(Mime), is_integer(Width), is_integer(Height), is_integer(Bytes) -> ok.
