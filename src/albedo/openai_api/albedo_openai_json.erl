-module(albedo_openai_json).
-export([encode/1, null/0, flatten/1, data_url/2, base64_string/1, semantically_empty/1, object_fields/1]).
-export([event/1, string_field/2, optional_string_field/2, int_field/2,
         optional_int_field/2, int_field_or/3, list_field/2, object_field/2,
         missing/2, empty_except/2]).

encode(Value) -> json:encode(Value).

null() -> null.

%% Inspect only the container, without decoding or copying its contents.
semantically_empty(null) -> true;
semantically_empty(nil) -> true;
semantically_empty(undefined) -> true;
semantically_empty(<<>>) -> true;
semantically_empty([]) -> true;
semantically_empty({}) -> true;
semantically_empty(Value) when is_map(Value) -> map_size(Value) =:= 0;
semantically_empty(_) -> false.

%% Validate the typed key contract while retaining the original map and values.
object_fields(Value) when is_map(Value) ->
    case has_string_keys(maps:iterator(Value)) of
        true -> {ok, Value};
        false -> {error, #{}}
    end;
object_fields(_) -> {error, #{}}.

has_string_keys(Iterator) ->
    case maps:next(Iterator) of
        none -> true;
        {Key, _, Next} when is_binary(Key) -> has_string_keys(Next);
        _ -> false
    end.

%% Binaries at least this large cross process boundaries by reference.
-define(SHARED, 512).

%% One encoded input as iodata with its small fragments coalesced. Encoding
%% leaves thousands of tiny pieces (keys, quotes, escape-split slices) that are
%% deep-copied whenever the request is sent to the HTTP connection process;
%% large binaries (message text, image data) stay as references, uncopied.
flatten(Json) -> coalesce(Json, [], [], []).

coalesce([], [], Small, Out) -> lists:reverse(emit(Small, Out));
coalesce([], [Next | Stack], Small, Out) -> coalesce(Next, Stack, Small, Out);
coalesce([H | T], Stack, Small, Out) -> coalesce(H, [T | Stack], Small, Out);
coalesce(B, Stack, Small, Out) when is_binary(B), byte_size(B) >= ?SHARED ->
    coalesce([], Stack, [], [B | emit(Small, Out)]);
coalesce({albedo_image, _, _} = Image, Stack, Small, Out) ->
    coalesce([], Stack, [], [Image | emit(Small, Out)]);
coalesce(Piece, Stack, Small, Out) -> coalesce([], Stack, [Piece | Small], Out).

emit([], Out) -> Out;
emit(Small, Out) -> [iolist_to_binary(lists:reverse(Small)) | Out].

%% A `data:` URL as a JSON string without concatenating the payload first. The
%% base64 alphabet needs no JSON escaping, so clean data is emitted as is. A
%% stored payload (always clean, see albedo_images.erl) is left as an
%% {albedo_image, Size, Read} placeholder that the transport reads while it
%% writes the body; nothing else may serialize such a body.
data_url(Mime, {stored_data, _, Size, Read}) ->
    [<<"\"data:">>, Mime, <<";base64,">>, {albedo_image, Size, Read}, $"];
data_url(Mime, {inline_data, Data}) ->
    case base64_clean(Data) of
        true -> [<<"\"data:">>, Mime, <<";base64,">>, Data, $"];
        false -> json:encode_binary(<<"data:", Mime/binary, ";base64,", Data/binary>>)
    end.

%% The payload alone as a JSON string, placeholder rules as for data_url/2.
base64_string({stored_data, _, Size, Read}) -> [$", {albedo_image, Size, Read}, $"];
base64_string({inline_data, Data}) -> json:encode_binary(Data).

base64_clean(<<C, Rest/binary>>)
        when (C >= $A andalso C =< $Z); (C >= $a andalso C =< $z);
             (C >= $0 andalso C =< $9); C =:= $+; C =:= $/; C =:= $= ->
    base64_clean(Rest);
base64_clean(<<>>) -> true;
base64_clean(_) -> false.

%% Field reads over objects json:decode produced, whose strings are already
%% valid UTF-8. Each answers {error, nil} for any shape its decode equivalent
%% would not take as is; the caller then runs that decoder for the verdict.

%% An event object and its string `type`.
event(Data) ->
    try json:decode(Data) of
        #{<<"type">> := Kind} = Event when is_binary(Kind) -> {ok, {Kind, Event}};
        _ -> {error, nil}
    catch
        error:_ -> {error, nil}
    end.

string_field(Object, Key) ->
    case Object of
        #{Key := Value} when is_binary(Value) -> {ok, Value};
        _ -> {error, nil}
    end.

int_field(Object, Key) ->
    case Object of
        #{Key := Value} when is_integer(Value) -> {ok, Value};
        _ -> {error, nil}
    end.

list_field(Object, Key) ->
    case Object of
        #{Key := Value} when is_list(Value) -> {ok, Value};
        _ -> {error, nil}
    end.

object_field(Object, Key) ->
    case Object of
        #{Key := Value} when is_map(Value) -> {ok, Value};
        _ -> {error, nil}
    end.

%% An absent or null field is none.
optional_string_field(Object, Key) when is_map(Object) ->
    case Object of
        #{Key := null} -> {ok, none};
        #{Key := Value} when is_binary(Value) -> {ok, {some, Value}};
        #{Key := _} -> {error, nil};
        _ -> {ok, none}
    end;
optional_string_field(_, _) -> {error, nil}.

optional_int_field(Object, Key) when is_map(Object) ->
    case Object of
        #{Key := null} -> {ok, none};
        #{Key := Value} when is_integer(Value) -> {ok, {some, Value}};
        #{Key := _} -> {error, nil};
        _ -> {ok, none}
    end;
optional_int_field(_, _) -> {error, nil}.

%% An absent field is Default; a present one must be an integer.
int_field_or(Object, Key, Default) when is_map(Object) ->
    case Object of
        #{Key := Value} when is_integer(Value) -> {ok, Value};
        #{Key := _} -> {error, nil};
        _ -> {ok, Default}
    end;
int_field_or(_, _, _) -> {error, nil}.

missing(Object, Key) ->
    case Object of
        #{Key := null} -> true;
        #{Key := _} -> false;
        _ -> true
    end.

%% Whether every field outside Keys is null or an empty list.
empty_except(Object, Keys) when is_map(Object) ->
    maps:fold(fun
        (_, null, Empty) -> Empty;
        (_, [], Empty) -> Empty;
        (Key, _, Empty) -> Empty andalso lists:member(Key, Keys)
    end, true, Object);
empty_except(_, _) -> false.
