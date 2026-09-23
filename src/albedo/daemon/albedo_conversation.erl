-module(albedo_conversation).
-export([pack/1,unpack/1,unpack_trace/1,pack_list/1,unpack_list/1]).
pack(Input) -> term_to_binary({1,Input}).
unpack(Bytes) ->
  try binary_to_term(Bytes,[safe]) of
    {1,{Tag,Text}=Input} when (Tag=:=user orelse Tag=:=assistant), is_binary(Text) -> {ok,Input};
    {1,{user_image,Text,Image}=Input} when is_binary(Text) ->
      case albedo_image:valid(Image) of true -> {ok,Input}; false -> {error,nil} end;
    %% Tool outputs saved before tool images carry no image list.
    {1,{tool_output,Id,Text}} when is_binary(Id),is_binary(Text) -> {ok,{tool_output,Id,Text,[]}};
    {1,{tool_output,Id,Text,Images}=Input} when is_binary(Id),is_binary(Text),is_list(Images) ->
      case lists:all(fun albedo_image:valid/1,Images) of true -> {ok,Input}; false -> {error,nil} end;
    {1,{replay,{replay_item,Protocol,Value}}=Input} when is_map(Value), (Protocol=:=responses orelse Protocol=:=chat_completions) ->
      case {Protocol,Value} of
        {responses,#{<<"type">> := Type}} when is_binary(Type) -> {ok,Input};
        {chat_completions,#{<<"role">> := <<"assistant">>}} -> {ok,Input};
        _ -> {error,nil}
      end;
    _ -> {error,nil}
  catch _:_ -> {error,nil} end.

unpack_trace(Bytes) -> try binary_to_term(Bytes,[safe]) of
  {1,#{<<"activities">> := A, <<"changes">> := C}=Trace} when is_list(A),is_list(C) -> {ok,Trace};
  _ -> {error,nil}
catch _:_ -> {error,nil} end.

%% A pinned prompt's context inputs, each packed like a transcript entry.
pack_list(Inputs) -> term_to_binary({1,[pack(I) || I <- Inputs]}).
unpack_list(Bytes) -> try binary_to_term(Bytes,[safe]) of
  {1,Packed} when is_list(Packed) ->
    Inputs = [unpack(P) || P <- Packed],
    case lists:all(fun({ok,_}) -> true; (_) -> false end, Inputs) of
      true -> {ok,[I || {ok,I} <- Inputs]};
      false -> {error,nil}
    end;
  _ -> {error,nil}
catch _:_ -> {error,nil} end.
