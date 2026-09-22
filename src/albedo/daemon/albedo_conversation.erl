-module(albedo_conversation).
-export([pack/1,unpack/1,unpack_trace/1]).
pack(Input) -> term_to_binary({1,Input}).
unpack(Bytes) ->
  try binary_to_term(Bytes,[safe]) of
    {1,{Tag,Text}=Input} when (Tag=:=user orelse Tag=:=assistant), is_binary(Text) -> {ok,Input};
    {1,{user_image,Text,Image}=Input} when is_binary(Text) ->
      case valid_image(Image) of true -> {ok,Input}; false -> {error,nil} end;
    {1,{tool_output,Id,Text}=Input} when is_binary(Id),is_binary(Text) -> {ok,Input};
    {1,{replay,{replay_item,Protocol,Value}}=Input} when is_map(Value), (Protocol=:=responses orelse Protocol=:=chat_completions) ->
      case {Protocol,Value} of
        {responses,#{<<"type">> := Type}} when is_binary(Type) -> {ok,Input};
        {chat_completions,#{<<"role">> := <<"assistant">>}} -> {ok,Input};
        _ -> {error,nil}
      end;
    _ -> {error,nil}
  catch _:_ -> {error,nil} end.

valid_image({image,Mime,Data,Width,Height,Bytes})
    when is_binary(Mime), is_binary(Data), is_integer(Width), is_integer(Height), is_integer(Bytes) ->
  case albedo_image:inspect(Data) of
    {ok,{Mime,Width,Height,Bytes}} -> true;
    _ -> false
  end;
valid_image(_) -> false.

unpack_trace(Bytes) -> try binary_to_term(Bytes,[safe]) of
  {1,#{<<"activities">> := A, <<"changes">> := C}=Trace} when is_list(A),is_list(C) -> {ok,Trace};
  _ -> {error,nil}
catch _:_ -> {error,nil} end.
