-module(albedo_sse_bytes).
-export([newline/1, compact/1]).

newline(Bytes) ->
    case binary:match(Bytes, [<<10>>, <<13>>]) of
        nomatch -> -1;
        {Offset, 1} -> Offset
    end.

compact(Bytes) ->
    case binary:referenced_byte_size(Bytes) > max(4096, byte_size(Bytes) * 4) of
        true -> binary:copy(Bytes);
        false -> Bytes
    end.
