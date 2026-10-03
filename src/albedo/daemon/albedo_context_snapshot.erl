-module(albedo_context_snapshot).
-export([page_count/2, page/3]).

page_count(Content, Size) when Size > 0 ->
    (scalar_count(Content, 0) + Size - 1) div Size.

scalar_count(<<>>, Count) -> Count;
scalar_count(<<_/utf8, Rest/binary>>, Count) -> scalar_count(Rest, Count + 1).

page(Content, Index, Size) when Index >= 0, Size > 0 ->
    Start = skip(Content, Index * Size),
    End = skip(Start, Size),
    %% Do not keep the whole rendered history alive through a small page.
    binary:copy(binary:part(Start, 0, byte_size(Start) - byte_size(End))).

skip(Content, 0) -> Content;
skip(<<>>, _) -> <<>>;
skip(<<_/utf8, Rest/binary>>, Count) -> skip(Rest, Count - 1).
