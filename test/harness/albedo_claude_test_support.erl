-module(albedo_claude_test_support).
%% Constructs types:Image; the Gleam constructor is private.
-export([stored_image/7, bytes_contain/2]).

stored_image(Mime, Hash, Size, Read, Width, Height, Bytes) ->
    {image, Mime, {stored_data, Hash, Size, Read}, Width, Height, Bytes}.

bytes_contain(Haystack, Needle) ->
    binary:match(Haystack, Needle) =/= nomatch.
