-module(albedo_sse_bytes).
-export([newline/1, assemble/1, compact/1, field/1]).

newline(Bytes) ->
    case binary:match(Bytes, [<<10>>, <<13>>]) of
        nomatch -> -1;
        {Offset, 1} -> Offset
    end.

assemble(Fragments) -> iolist_to_binary(lists:reverse(Fragments)).

compact(Bytes) ->
    case binary:referenced_byte_size(Bytes) > max(4096, byte_size(Bytes) * 4) of
        true -> binary:copy(Bytes);
        false -> Bytes
    end.

field(Line) ->
    case binary:split(Line, <<":">>) of
        [Name, <<32, Value/binary>>] -> {Name, Value};
        [Name, Value] -> {Name, Value};
        [Name] -> {Name, <<>>}
    end.
