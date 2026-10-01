-module(albedo_conversation).
-export([pack/1,pack_fit/3,unpack/2,unpack_fit/2,unpack_trace/1,pack_list/1,unpack_list/2,row_atoms/0,classify/1,elide_tool_images/1,elision_marker/1]).
pack(Input) -> term_to_binary({1,albedo_images:pack(Input)}).

%% binary_to_term/2 with `safe` rejects atoms that do not exist yet; a stored
%% image reference is decoded here, so this module keeps its atom alive.
row_atoms() -> [stored_data].

%% Read fetches a stored image payload by hash (see albedo_images).
unpack(Bytes,Read) ->
  try binary_to_term(Bytes,[safe]) of
    {1,{Tag,Text}=Input} when (Tag=:=user orelse Tag=:=assistant), is_binary(Text) -> {ok,Input};
    {1,{user_image,Text,_}=Input} when is_binary(Text) -> attached(Input,Read);
    %% Tool outputs saved before tool images carry no image list.
    {1,{tool_output,Id,Text}} when is_binary(Id),is_binary(Text) -> {ok,{tool_output,Id,Text,[]}};
    {1,{tool_output,Id,Text,Images}=Input} when is_binary(Id),is_binary(Text),is_list(Images) -> attached(Input,Read);
    {1,{replay,{replay_item,responses,#{<<"type">> := Type}}}=Input} when is_binary(Type) -> {ok,Input};
    {1,{replay,{replay_item,chat_completions,#{<<"role">> := <<"assistant">>}}}=Input} -> {ok,Input};
    %% An image fit reads as its note everywhere but the history fold.
    {1,{image_fit,{user,Text},Source,_}} when is_binary(Text),is_binary(Source) -> {ok,{user,Text}};
    _ -> {error,nil}
  catch _:_ -> {error,nil} end.

%% An image fit row (see transcript.ImageFit): its note, the source payload
%% hash, and the fitted image, already stored.
pack_fit(Note,Source,Image) ->
  term_to_binary({1,{image_fit,{user,Note},Source,albedo_images:pack_image(Image)}}).

%% {ok, ImageFit} for an image fit row, with its image's reader attached;
%% {error, nil} for any other row.
unpack_fit(Bytes,Read) ->
  try binary_to_term(Bytes,[safe]) of
    {1,{image_fit,{user,Note},Source,Image}} when is_binary(Note),is_binary(Source) ->
      case albedo_images:load(Image,Read) of
        {ok,Loaded} -> {ok,{image_fit,Note,Source,Loaded}};
        error -> {error,nil}
      end;
    _ -> {error,nil}
  catch _:_ -> {error,nil} end.

attached(Input,Read) ->
  case albedo_images:attach(Input,Read) of {ok,_}=Ok -> Ok; error -> {error,nil} end.

unpack_trace(Bytes) -> try binary_to_term(Bytes,[safe]) of
  {1,#{<<"activities">> := A, <<"changes">> := C}=Trace} when is_list(A),is_list(C) -> {ok,Trace};
  _ -> {error,nil}
catch _:_ -> {error,nil} end.

%% A pinned prompt's context inputs, each packed like a transcript entry.
pack_list(Inputs) -> term_to_binary({1,[pack(I) || I <- Inputs]}).
unpack_list(Bytes,Read) -> try binary_to_term(Bytes,[safe]) of
  {1,Packed} when is_list(Packed) ->
    case albedo_images:results([unpack(P,Read) || P <- Packed]) of
      {ok,_}=Ok -> Ok;
      error -> {error,nil}
    end;
  _ -> {error,nil}
catch _:_ -> {error,nil} end.

%% A packed tool output without its images: {Id, Row, Hashes}, the marker
%% appended to its text. {error, nil} when the row holds no image.
elide_tool_images(Bytes) ->
  try binary_to_term(Bytes, [safe]) of
    {1, {tool_output, Id, Text, [_ | _]}} when is_binary(Id), is_binary(Text) ->
      Row = term_to_binary({1, {tool_output, Id, elision_marker(Text), []}}),
      {ok, {Id, Row, albedo_images:hashes(Bytes)}};
    _ -> {error, nil}
  catch _:_ -> {error, nil} end.

elision_marker(Text) -> <<Text/binary, "\n[image elided and is no longer available]">>.

%% Classification is derived from a valid payload, never from its textual tags.
classify(Bytes) ->
    Read = fun(_) -> {error,nil} end,
    try binary_to_term(Bytes,[safe]) of
        {1,{image_fit,_,_,_}} ->
            case unpack_fit(Bytes,Read) of
                {ok,_} -> {ok,<<"image_fit">>};
                _ -> {error,nil}
            end;
        _ ->
            case unpack(Bytes,Read) of
                {ok,{user,_}} -> {ok,<<"user">>};
                {ok,{user_image,_,_}} -> {ok,<<"user">>};
                {ok,_} -> {ok,<<"other">>};
                _ -> {error,nil}
            end
    catch _:_ -> {error,nil} end.
