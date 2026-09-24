-module(albedo_image).
-export([inspect/1, valid/1]).

-define(MAX_DATA_BYTES, 6990508).
-define(MAX_IMAGE_BYTES, 5242880).

inspect(Data) when is_binary(Data), byte_size(Data) > 0, byte_size(Data) =< ?MAX_DATA_BYTES ->
  try base64:decode(Data) of
    Bytes when byte_size(Bytes) > 0, byte_size(Bytes) =< ?MAX_IMAGE_BYTES ->
      case base64:encode(Bytes) =:= Data of
        true ->
          case dimensions(Bytes) of
            {ok, Mime, Width, Height} -> {ok, {Mime, Width, Height, byte_size(Bytes)}};
            error -> {error, nil}
          end;
        false -> {error, nil}
      end;
    _ -> {error, nil}
  catch _:_ -> {error, nil} end;
inspect(_) -> {error, nil}.

%% A saved types.Image whose metadata still matches its payload. Runs for every
%% image each time a transcript loads, so it proves what inspect/1 proves
%% without its two full-size copies: a scan establishes canonical base64 and the
%% decoded size, and only a prefix is decoded to read the dimensions.
valid({image, Mime, Data, Width, Height, Bytes})
    when is_binary(Mime), is_binary(Data), is_integer(Width), is_integer(Height), is_integer(Bytes),
         byte_size(Data) > 0, byte_size(Data) =< ?MAX_DATA_BYTES ->
  case canonical_size(Data) of
    Bytes when Bytes > 0, Bytes =< ?MAX_IMAGE_BYTES ->
      header_dimensions(Data) =:= {ok, Mime, Width, Height};
    _ -> false
  end;
valid(_) -> false.

%% Headers are read from this many base64 characters (48 KiB decoded); a JPEG
%% whose frame header lies beyond them is decoded whole, as before.
-define(HEADER_CHARS, 65536).

header_dimensions(Data) when byte_size(Data) =< ?HEADER_CHARS -> dimensions(base64:decode(Data));
header_dimensions(Data) ->
  case dimensions(base64:decode(binary:part(Data, 0, ?HEADER_CHARS))) of
    {ok, <<"image/webp">>, _, _} -> dimensions(base64:decode(Data));  %% RIFF size covers the whole file
    {ok, _, _, _} = Found -> Found;
    error -> dimensions(base64:decode(Data))
  end.

%% The decoded size of canonical, padded base64 (what base64:encode/1 emits),
%% or error. Canonical means encode(decode(Data)) =:= Data: standard alphabet,
%% length a multiple of four, at most two '=' at the end, and zero unused bits
%% in the final character.
canonical_size(Data) when byte_size(Data) >= 4, byte_size(Data) rem 4 =:= 0 ->
  Body = byte_size(Data) - 4,
  <<Head:Body/binary, Last:4/binary>> = Data,
  case alphabet(Head) of
    true ->
      case Last of
        <<A, B, $=, $=>> -> quad_tail(A, B, 16#0F, 1, Body);
        <<A, B, C, $=>> -> quad_tail3(A, B, C, Body);
        <<A, B, C, D>> ->
          case alphabet(<<A, B, C, D>>) of true -> Body div 4 * 3 + 3; false -> error end;
        _ -> error
      end;
    false -> error
  end;
canonical_size(_) -> error.

quad_tail(A, B, Mask, Extra, Body) ->
  case alphabet(<<A, B>>) andalso value(B) band Mask =:= 0 of
    true -> Body div 4 * 3 + Extra;
    false -> error
  end.

quad_tail3(A, B, C, Body) ->
  case alphabet(<<A, B, C>>) andalso value(C) band 16#03 =:= 0 of
    true -> Body div 4 * 3 + 2;
    false -> error
  end.

alphabet(<<C, Rest/binary>>)
    when (C >= $A andalso C =< $Z); (C >= $a andalso C =< $z);
         (C >= $0 andalso C =< $9); C =:= $+; C =:= $/ -> alphabet(Rest);
alphabet(<<>>) -> true;
alphabet(_) -> false.

value(C) when C >= $A, C =< $Z -> C - $A;
value(C) when C >= $a, C =< $z -> C - $a + 26;
value(C) when C >= $0, C =< $9 -> C - $0 + 52;
value($+) -> 62;
value($/) -> 63.

dimensions(<<16#89, "PNG", 13, 10, 26, 10, 13:32/big, "IHDR", Width:32/big, Height:32/big, _/binary>>)
    when Width > 0, Height > 0 -> {ok, <<"image/png">>, Width, Height};
dimensions(<<16#FF, 16#D8, Rest/binary>>) -> jpeg(Rest);
dimensions(<<"RIFF", Size:32/little, "WEBP", Chunks/binary>> = Bytes)
    when Size + 8 =:= byte_size(Bytes) -> webp(Chunks);
dimensions(_) -> error.

jpeg(<<16#FF, Rest/binary>>) -> jpeg_marker(Rest);
jpeg(<<_, Rest/binary>>) -> jpeg(Rest);
jpeg(<<>>) -> error.

jpeg_marker(<<16#FF, Rest/binary>>) -> jpeg_marker(Rest);
jpeg_marker(<<Marker, Rest/binary>>) when Marker =:= 16#D8; Marker =:= 16#01;
    (Marker >= 16#D0 andalso Marker =< 16#D7) -> jpeg(Rest);
jpeg_marker(<<Marker, Length:16/big, Segment/binary>>)
    when Length >= 2, byte_size(Segment) >= Length - 2 ->
  PayloadSize = Length - 2,
  <<Payload:PayloadSize/binary, Tail/binary>> = Segment,
  case is_sof(Marker) of
    true ->
      case Payload of
        <<_Precision, Height:16/big, Width:16/big, _/binary>> when Width > 0, Height > 0 ->
          {ok, <<"image/jpeg">>, Width, Height};
        _ -> error
      end;
    false when Marker =:= 16#DA; Marker =:= 16#D9 -> error;
    false -> jpeg(Tail)
  end;
jpeg_marker(_) -> error.

is_sof(Marker) ->
  lists:member(Marker, [16#C0,16#C1,16#C2,16#C3,16#C5,16#C6,16#C7,
                        16#C9,16#CA,16#CB,16#CD,16#CE,16#CF]).

webp(<<"VP8X", 10:32/little, _Flags, _Reserved:24,
       WidthMinusOne:24/little, HeightMinusOne:24/little, _/binary>>) ->
  {ok, <<"image/webp">>, WidthMinusOne + 1, HeightMinusOne + 1};
webp(<<"VP8L", Size:32/little, 16#2F, Bits:32/little, _/binary>>) when Size >= 5 ->
  {ok, <<"image/webp">>, (Bits band 16#3FFF) + 1, ((Bits bsr 14) band 16#3FFF) + 1};
webp(<<"VP8 ", Size:32/little, _FrameTag:24/little, 16#9D, 16#01, 16#2A,
       WidthBits:16/little, HeightBits:16/little, _/binary>>) when Size >= 10 ->
  Width = WidthBits band 16#3FFF,
  Height = HeightBits band 16#3FFF,
  case Width > 0 andalso Height > 0 of
    true -> {ok, <<"image/webp">>, Width, Height};
    false -> error
  end;
webp(<<_Kind:4/binary, Size:32/little, Rest/binary>>) when byte_size(Rest) >= Size ->
  Padding = Size rem 2,
  case Rest of
    <<_Payload:Size/binary, _Pad:Padding/binary, Tail/binary>> -> webp(Tail);
    _ -> error
  end;
webp(_) -> error.
