%% Image payloads live in the `images` table, keyed by the SHA-256 of their
%% base64 text; decoded bytes live in the table, while transcript rows keep
%% only the original base64 hash and image metadata.
%%
%% In memory an image is {image, Mime, Data, Width, Height, Bytes} where Data is
%% {inline_data, Base64} or {stored_data, Hash, Size, Read}, Read being a fun/0
%% that fetches the payload (see types.ImageData). A packed row stores
%% {stored_data, Hash, Size} (no fun), or the legacy bare Base64 binary.
-module(albedo_images).
-export([externalize/2, attach/2, pack/1, pack_image/1, load/2, canonical/1, legacy/1, results/1, hashes/1, migrate/2, ensure_dir/1, backup_exists/1, decode_base64/1, decode_legacy_base64/1, encode_base64/1]).

%% The same data-size limit the Gleam image owner guards with; a guard needs the macro.
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
    case results([load(Image, Read) || Image <- Images]) of
        {ok, Loaded} -> {ok, {tool_output, Id, Text, Loaded}};
        error -> error
    end;
attach(Input, _) -> {ok, Input}.

load({image, Mime, {stored_data, Hash, Size}, W, H, Bytes}, Read)
        when is_binary(Mime), is_binary(Hash), byte_size(Hash) =:= 64,
             is_integer(Size), Size > 0, Size =< ?MAX_DATA_BYTES,
             is_integer(W), is_integer(H), is_integer(Bytes), Bytes > 0,
             Size =:= 4 * ((Bytes + 2) div 3) ->
    %% A stored payload was validated as canonical base64 on insert.
    {ok, {image, Mime, stored(Hash, Size, Read), W, H, Bytes}};
load({image, Mime, Data, W, H, Bytes}, _)
    when is_binary(Mime), is_binary(Data), is_integer(W), is_integer(H), is_integer(Bytes) ->
    case 'albedo@daemon@image':valid_payload(Mime, Data, W, H, Bytes) of
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
canonical(Term) -> transform(Term, fun hash_payload/1).

hash_payload({image, Mime, Payload, W, H, Bytes}) ->
    Hash = case Payload of
        {inline_data, Data} -> hash(Data);
        {stored_data, Hsh, _, _} -> Hsh
    end,
    {image, Mime, {sha256, Hash}, W, H, Bytes}.

%% The term as it was before images were stored: payloads inline as bare
%% binaries. Reads every stored payload; {error, nil} if one is missing.
legacy(Term) ->
    try {ok, transform(Term, fun inline_payload/1)}
    catch throw:missing -> {error, nil}
    end.

inline_payload({image, Mime, {inline_data, Data}, W, H, Bytes}) ->
    {image, Mime, Data, W, H, Bytes};
inline_payload({image, Mime, {stored_data, _, _, Read}, W, H, Bytes}) ->
    case Read() of
        {ok, Data} -> {image, Mime, Data, W, H, Bytes};
        _ -> throw(missing)
    end.

%% Rebuilds a term with every image payload mapped through Replace; everything
%% else keeps its structure. An image tuple whose payload is neither inline
%% nor stored is walked like any other tuple.
transform({image, Mime, {inline_data, _}, _, _, _} = Image, Replace) when is_binary(Mime) -> Replace(Image);
transform({image, Mime, {stored_data, _, _, _}, _, _, _} = Image, Replace) when is_binary(Mime) -> Replace(Image);
transform(T, Replace) when is_tuple(T) -> list_to_tuple(transform(tuple_to_list(T), Replace));
transform([H | T], Replace) -> [transform(H, Replace) | transform(T, Replace)];
transform(M, Replace) when is_map(M) -> maps:from_list(transform(maps:to_list(M), Replace));
transform(Other, _) -> Other.

%% Every attempt's value, or error when one failed.
results(Attempts) ->
    case lists:all(fun({ok, _}) -> true; (_) -> false end, Attempts) of
        true -> {ok, [Value || {ok, Value} <- Attempts]};
        false -> error
    end.

%% Hashes a packed row references, without attaching or validating.
hashes(Payload) ->
    try binary_to_term(Payload, [safe]) of
        {1, {user_image, _, {image, _, {stored_data, Hash, _}, _, _, _}}} -> [Hash];
        {1, {tool_output, _, _, Images}} when is_list(Images) ->
            [Hash || {image, _, {stored_data, Hash, _}, _, _, _} <- Images];
        {1, {image_fit, _, _, {image, _, {stored_data, Hash, _}, _, _, _}}} -> [Hash];
        _ -> []
    catch _:_ -> []
    end.

%% One legacy row, rewritten: {rewrite, Payload, Blobs} when it held inline images
%% that moved to the image table, keep otherwise (including rows that do not
%% decode, which are left for the loader to report).
migrate(Payload, Read) ->
    maybe
        {ok, Input} ?= albedo_conversation:unpack(Payload, Read),
        {Stored, [_ | _] = Blobs} ?= externalize(Input, Read),
        {rewrite, albedo_conversation:pack(Stored), Blobs}
    else
        _ -> keep
    end.

%% Canonical base64 needs no JSON escaping; anything else stays inline.
clean(Value) -> 'albedo@daemon@image':safe_payload(Value).

ensure_dir(Path) -> _ = filelib:ensure_dir(Path), nil.

backup_exists(Path) -> filelib:is_regular(Path).

%% A clean, canonical inline payload was validated before externalize/2.
decode_base64(Data) -> base64:decode(Data).

%% A damaged legacy row fails migration without discarding its original TEXT.
decode_legacy_base64(Data) ->
    try {ok, base64:decode(Data)}
    catch error:_ -> {error, nil}
    end.

encode_base64(Data) -> base64:encode(Data).
