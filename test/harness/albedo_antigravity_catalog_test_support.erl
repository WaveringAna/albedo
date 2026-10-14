%% A home whose antigravity.json is fresh, so catalog lookups never reach the network.
-module(albedo_antigravity_catalog_test_support).
-export([home_with_catalog/1, cleanup/1]).

home_with_catalog(Json) ->
    Home = filename:join(os:getenv("TMPDIR", "/tmp"),
                         "albedo-antigravity-catalog-" ++ binary_to_list(albedo_native:new_id())),
    ok = file:make_dir(Home),
    ok = file:write_file(filename:join(Home, "antigravity.json"), Json),
    unicode:characters_to_binary(Home).

cleanup(Home) ->
    ok = file:del_dir_r(Home),
    nil.
