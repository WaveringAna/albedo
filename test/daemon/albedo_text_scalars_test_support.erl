-module(albedo_text_scalars_test_support).
-export([referenced_size/1]).

referenced_size(Text) -> binary:referenced_byte_size(Text).
