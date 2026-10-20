-module(albedo_folders_test_support).
-export([write/2, make_dir/1]).

write(Path, Bytes) ->
    ok = file:write_file(Path, Bytes),
    nil.

make_dir(Path) ->
    ok = file:make_dir(Path),
    nil.
