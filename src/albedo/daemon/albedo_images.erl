%% Image payloads live in the `images` table, keyed by the SHA-256 of their
%% base64 text; transcript rows keep only that hash and the image metadata.
%%
%% In memory an image is {image, Mime, Data, Width, Height, Bytes} where Data is
%% {inline_data, Base64} or {stored_data, Hash, Size, Read}, Read being a fun/0
%% that fetches the payload (see types.ImageData). A packed row stores
%% {stored_data, Hash, Size} (no fun), or the legacy bare Base64 binary.
-module(albedo_images).
-export([externalize/2, attach/2, pack/1, pack_image/1, load/2, canonical/1, legacy/1, hashes/1, migrate/2, clean/1, ensure_dir/1]).

-define(MAX_DATA_BYTES, 6990508).

%% Moves the inline images of one input into Blobs [{Hash, Base64}], returning
%% the input with stored references. Read is fun(Hash) -> {ok, Base64} | {error, nil}.
%% Payloads that would need JSON escaping stay inline (a request writes a
%% stored payload verbatim between quotes).
externalize({user_image, Text, Image}, Read) ->
    {Stored, Blobs} = store(Image, Read),
    {{user_image, Text, Stored}, Blobs};
externalize({tool_output, Id, Text, Images}, Read) ->
    Pairs = [store(Image, Read) || Image <- Images],
    {{tool_output, Id, Text, [S || {S, _} <- Pairs]}, lists:append([B || {_, B} <- Pairs])};
externalize(Input, _) -> {Input, []}.

store({image, Mime, {inline_data, Data}, W, H, Bytes} = Image, Read) ->
    case byte_size(Data) =:= 4 * ((Bytes + 2) div 3) andalso clean(Data) of
        true ->
            Hash = hash(Data),
            {{image, Mime, stored(Hash, byte_size(Data), Read), W, H, Bytes}, [{Hash, Data}]};
        false -> {Image, []}
    end;
store(Image, _) -> {Image, []}.

stored(Hash, Size, Read) -> {stored_data, Hash, Size, fun() -> Read(Hash) end}.

hash(Data) -> binary:encode_hex(crypto:hash(sha256, Data), lowercase).

%% A decoded row's images with their readers attached; packed refs that fail
%% the shape check make the row invalid.
attach({user_image, Text, Image}, Read) ->
    case load(Image, Read) of
        {ok, Loaded} -> {ok, {user_image, Text, Loaded}};
        error -> error
    end;
attach({tool_output, Id, Text, Images}, Read) ->
    Loaded = [load(Image, Read) || Image <- Images],
    case lists:all(fun({ok, _}) -> true; (_) -> false end, Loaded) of
        true -> {ok, {tool_output, Id, Text, [I || {ok, I} <- Loaded]}};
        false -> error
    end;
attach(Input, _) -> {ok, Input}.

load({image, Mime, {stored_data, Hash, Size}, W, H, Bytes}, Read)
        when is_binary(Mime), is_binary(Hash), byte_size(Hash) =:= 64,
             is_integer(Size), Size > 0, Size =< ?MAX_DATA_BYTES,
             is_integer(W), is_integer(H), is_integer(Bytes), Bytes > 0 ->
    %% A stored payload was validated as canonical base64 on insert.
    case Size =:= 4 * ((Bytes + 2) div 3) of
        true -> {ok, {image, Mime, stored(Hash, Size, Read), W, H, Bytes}};
        false -> error
    end;
load({image, Mime, Data, W, H, Bytes} = Legacy, _) when is_binary(Data) ->
    case albedo_image:valid(Legacy) of
        true -> {ok, {image, Mime, {inline_data, Data}, W, H, Bytes}};
        false -> error
    end;
load(_, _) -> error.

%% The row form of an input: readers dropped, inline payloads in the legacy
%% bare-binary shape so rows that were never externalized read as before.
pack({user_image, Text, Image}) -> {user_image, Text, pack_image(Image)};
pack({tool_output, Id, Text, Images}) -> {tool_output, Id, Text, [pack_image(I) || I <- Images]};
pack(Input) -> Input.

pack_image({image, Mime, {inline_data, Data}, W, H, Bytes}) -> {image, Mime, Data, W, H, Bytes};
pack_image({image, Mime, {stored_data, Hash, Size, _}, W, H, Bytes}) ->
    {image, Mime, {stored_data, Hash, Size}, W, H, Bytes};
pack_image(Image) -> Image.

%% Any term with every image's payload replaced by its content hash, so equal
%% content fingerprints equally whether it is inline or stored. Terms without
%% images are returned unchanged.
canonical({image, Mime, {inline_data, Data}, W, H, Bytes}) when is_binary(Mime) ->
    {image, Mime, {sha256, hash(Data)}, W, H, Bytes};
canonical({image, Mime, {stored_data, Hash, _, _}, W, H, Bytes}) when is_binary(Mime) ->
    {image, Mime, {sha256, Hash}, W, H, Bytes};
canonical(T) when is_tuple(T) -> list_to_tuple(canonical(tuple_to_list(T)));
canonical([H | T]) -> [canonical(H) | canonical(T)];
canonical(M) when is_map(M) -> maps:from_list(canonical(maps:to_list(M)));
canonical(Other) -> Other.

%% The term as it was before images were stored: payloads inline as bare
%% binaries. Reads every stored payload; {error, nil} if one is missing.
legacy(Term) ->
    try {ok, legacy_term(Term)}
    catch throw:missing -> {error, nil}
    end.

legacy_term({image, Mime, {inline_data, Data}, W, H, Bytes}) when is_binary(Mime) ->
    {image, Mime, Data, W, H, Bytes};
legacy_term({image, Mime, {stored_data, _, _, Read}, W, H, Bytes}) when is_binary(Mime) ->
    case Read() of
        {ok, Data} -> {image, Mime, Data, W, H, Bytes};
        _ -> throw(missing)
    end;
legacy_term(T) when is_tuple(T) -> list_to_tuple(legacy_term(tuple_to_list(T)));
legacy_term([H | T]) -> [legacy_term(H) | legacy_term(T)];
legacy_term(M) when is_map(M) -> maps:from_list(legacy_term(maps:to_list(M)));
legacy_term(Other) -> Other.

%% Hashes a packed row references, without attaching or validating.
hashes(Payload) ->
    try binary_to_term(Payload, [safe]) of
        {1, {user_image, _, Image}} -> ref(Image);
        {1, {tool_output, _, _, Images}} when is_list(Images) -> lists:append([ref(I) || I <- Images]);
        _ -> []
    catch _:_ -> []
    end.

ref({image, _, {stored_data, Hash, _}, _, _, _}) -> [Hash];
ref(_) -> [].

%% One legacy row, rewritten: {rewrite, Payload, Blobs} when it held inline images
%% that moved to the image table, keep otherwise (including rows that do not
%% decode, which are left for the loader to report).
migrate(Payload, Read) ->
    case albedo_conversation:unpack(Payload, Read) of
        {ok, Input} ->
            case externalize(Input, Read) of
                {_, []} -> keep;
                {Stored, Blobs} -> {rewrite, albedo_conversation:pack(Stored), Blobs}
            end;
        _ -> keep
    end.

%% Canonical base64 needs no JSON escaping; anything else stays inline.
clean(<<C, Rest/binary>>)
        when (C >= $A andalso C =< $Z); (C >= $a andalso C =< $z);
             (C >= $0 andalso C =< $9); C =:= $+; C =:= $/; C =:= $= ->
    clean(Rest);
clean(<<>>) -> true;
clean(_) -> false.

ensure_dir(Path) -> _ = filelib:ensure_dir(Path), nil.
