-module(albedo_claude_catalog_test_support).
-export([temporary_home/0, cache_permissions/1, block_cache/1, cleanup/1]).
-include_lib("kernel/include/file.hrl").

temporary_home() ->
    Home = filename:join("/tmp", "albedo-claude-catalog-" ++ integer_to_list(erlang:unique_integer([positive]))),
    ok = file:make_dir(Home),
    unicode:characters_to_binary(Home).

cache_permissions(Home) ->
    {ok, Info} = file:read_file_info(filename:join(Home, "claude-models.json")),
    Info#file_info.mode band 8#777.

block_cache(Home) ->
    ok = file:make_dir(filename:join(Home, "claude-models.json")),
    nil.

cleanup(Home) ->
    ok = file:del_dir_r(Home),
    nil.
