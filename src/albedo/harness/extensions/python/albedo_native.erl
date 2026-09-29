-module(albedo_native).
-export([new_id/0, pack_cell/1, unpack_cell/1, unpack_cell/2, elide_cell_images/1, inline_cell/1, cell_hashes/1]).
new_id() -> binary:encode_hex(crypto:strong_rand_bytes(16), lowercase).
%% Images are journaled in the transcript row shape (albedo_images:pack_image/1).
pack_cell({ok, {outcome, Id, Status, Output, Value, Truncated, Images, Errors, Duration}}) ->
    Packed = [albedo_images:pack_image(I) || I <- Images],
    term_to_binary({1, {ok, {outcome, Id, Status, Output, Value, Truncated, Packed, Errors, Duration}}});
pack_cell(Value) -> term_to_binary({1, Value}).
%% A finished cell without its images, the elision marker after its output.
elide_cell_images(Binary) ->
    case unpack_cell(Binary) of
        {ok, {ok, {outcome, Id, Status, Output, Value, Truncated, [_ | _], Errors, Duration}}} ->
            Marked = albedo_conversation:elision_marker(Output),
            {ok, pack_cell({ok, {outcome, Id, Status, Marked, Value, Truncated, [], Errors, Duration}})};
        _ -> {error, nil}
    end.

unpack_cell(Binary) -> unpack_cell(Binary, fun(_) -> {error, nil} end).

unpack_cell(Binary, Read) ->
    try binary_to_term(Binary, [safe]) of
        %% Cells journaled before images carry neither image field, and cells
        %% journaled before timing carry no duration.
        {1, {ok, {outcome, Id, Status, Output, Value, Truncated}}} ->
            unpack_outcome({outcome, Id, Status, Output, Value, Truncated, [], [], none}, Read);
        {1, {ok, {outcome, Id, Status, Output, Value, Truncated, Images, Errors}}} ->
            unpack_outcome({outcome, Id, Status, Output, Value, Truncated, Images, Errors, none}, Read);
        {1, {ok, {outcome, _, _, _, _, _, _, _, _} = Outcome}} -> unpack_outcome(Outcome, Read);
        {1, {error, E} = Result} when E =:= busy; E =:= lost -> {ok, Result};
        {1, {error, {Tag, Text}} = Result}
          when (Tag =:= invalid orelse Tag =:= unavailable), is_binary(Text) -> {ok, Result};
        _ -> {error, nil}
    catch _:_ -> {error, nil}
    end.

unpack_outcome({outcome, Id, Status, Output, Value, Truncated, Images, Errors, Duration}, Read)
  when is_binary(Id), is_binary(Output), is_binary(Value), is_boolean(Truncated),
       is_list(Images), is_list(Errors),
       (Status =:= succeeded orelse Status =:= failed orelse Status =:= interrupted) ->
    %% Loaded references retain a lazy reader; opening a cell never fetches image bytes.
    Loaded = [albedo_images:load(I, Read) || I <- Images],
    case {albedo_images:results(Loaded), lists:all(fun erlang:is_binary/1, Errors), duration(Duration)} of
        {{ok, Images1}, true, true} -> {ok, {ok, {outcome, Id, Status, Output, Value, Truncated, Images1, Errors, Duration}}};
        _ -> {error, nil}
    end;
unpack_outcome(_, _) -> {error, nil}.

duration(none) -> true;
duration({some, Seconds}) -> is_float(Seconds);
duration(_) -> false.

%% A migration rewrites only legacy cells; stored references need no work.
inline_cell(Binary) ->
    case unpack_cell(Binary) of
        {ok, {ok, {outcome, _, _, _, _, _, Images, _, _}}} ->
            lists:any(fun({image, _, {inline_data, _}, _, _, _}) -> true;
                         (_) -> false end, Images);
        _ -> false
    end.

cell_hashes(Binary) ->
    try binary_to_term(Binary, [safe]) of
        {1, {ok, {outcome, _, _, _, _, _, Images, _, _}}} ->
            [Hash || {image, _, {stored_data, Hash, _}, _, _, _} <- Images];
        _ -> []
    catch _:_ -> []
    end.
