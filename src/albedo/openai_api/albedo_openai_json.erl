-module(albedo_openai_json).
-export([encode/1, null/0, flatten/1, data_url/2, base64_string/1]).

encode(Value) -> json:encode(Value).

null() -> null.

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
