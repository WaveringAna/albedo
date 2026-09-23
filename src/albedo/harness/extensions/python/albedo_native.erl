-module(albedo_native).
-export([new_id/0, pack_cell/1, unpack_cell/1]).
new_id() -> binary:encode_hex(crypto:strong_rand_bytes(16), lowercase).
pack_cell(Value) -> term_to_binary({1, Value}).
unpack_cell(Binary) ->
    try binary_to_term(Binary, [safe]) of
        %% Cells journaled before images carry neither image field.
        {1, {ok, {outcome, Id, Status, Output, Value, Truncated}}} ->
            unpack_outcome({outcome, Id, Status, Output, Value, Truncated, [], []});
        {1, {ok, {outcome, _, _, _, _, _, _, _} = Outcome}} -> unpack_outcome(Outcome);
        {1, {error, E} = Result} when E =:= busy; E =:= lost -> {ok, Result};
        {1, {error, {Tag, Text}} = Result}
          when (Tag =:= invalid orelse Tag =:= unavailable), is_binary(Text) -> {ok, Result};
        _ -> {error, nil}
    catch _:_ -> {error, nil}
    end.

unpack_outcome({outcome, Id, Status, Output, Value, Truncated, Images, Errors} = Outcome)
  when is_binary(Id), is_binary(Output), is_binary(Value), is_boolean(Truncated),
       is_list(Images), is_list(Errors),
       (Status =:= succeeded orelse Status =:= failed orelse Status =:= interrupted) ->
    case lists:all(fun albedo_image:valid/1, Images) andalso lists:all(fun erlang:is_binary/1, Errors) of
        true -> {ok, {ok, Outcome}};
        false -> {error, nil}
    end;
unpack_outcome(_) -> {error, nil}.
