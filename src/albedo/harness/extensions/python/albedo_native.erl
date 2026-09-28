-module(albedo_native).
-export([new_id/0, pack_cell/1, unpack_cell/1, elide_cell_images/1]).
new_id() -> binary:encode_hex(crypto:strong_rand_bytes(16), lowercase).
%% Images are journaled in the transcript row shape (albedo_images:pack_image/1).
pack_cell({ok, {outcome, Id, Status, Output, Value, Truncated, Images, Errors}}) ->
    Packed = [albedo_images:pack_image(I) || I <- Images],
    term_to_binary({1, {ok, {outcome, Id, Status, Output, Value, Truncated, Packed, Errors}}});
pack_cell(Value) -> term_to_binary({1, Value}).
%% A finished cell without its images, the elision marker after its output.
elide_cell_images(Binary) ->
    case unpack_cell(Binary) of
        {ok, {ok, {outcome, Id, Status, Output, Value, Truncated, [_ | _], Errors}}} ->
            Marked = albedo_conversation:elision_marker(Output),
            {ok, pack_cell({ok, {outcome, Id, Status, Marked, Value, Truncated, [], Errors}})};
        _ -> {error, nil}
    end.

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

unpack_outcome({outcome, Id, Status, Output, Value, Truncated, Images, Errors})
  when is_binary(Id), is_binary(Output), is_binary(Value), is_boolean(Truncated),
       is_list(Images), is_list(Errors),
       (Status =:= succeeded orelse Status =:= failed orelse Status =:= interrupted) ->
    %% A journaled image is always inline, so nothing here reads a payload.
    Loaded = [albedo_images:load(I, fun(_) -> {error, nil} end) || I <- Images],
    case {albedo_images:results(Loaded), lists:all(fun erlang:is_binary/1, Errors)} of
        {{ok, Images1}, true} -> {ok, {ok, {outcome, Id, Status, Output, Value, Truncated, Images1, Errors}}};
        _ -> {error, nil}
    end;
unpack_outcome(_) -> {error, nil}.
