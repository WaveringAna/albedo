-module(albedo_codex_catalog_test_support).
-export([temporary_home/0, cleanup/1, seed/2, read/1, block_cache/1,
         permissions/1, script/1, get/2, calls/0]).
-include_lib("kernel/include/file.hrl").

temporary_home() ->
    Home = filename:join("/tmp", "albedo-codex-catalog-" ++ integer_to_list(erlang:unique_integer([positive]))),
    ok = file:make_dir(Home),
    unicode:characters_to_binary(Home).
cleanup(Home) -> ok = file:del_dir_r(Home), nil.
seed(Home, Json) -> ok = file:write_file(filename:join(Home, "codex-models.json"), Json), nil.
read(Home) -> {ok, Bytes} = file:read_file(filename:join(Home, "codex-models.json")), Bytes.
block_cache(Home) -> ok = file:make_dir(filename:join(Home, "codex-models.json")), nil.
permissions(Home) ->
    {ok, Info} = file:read_file_info(filename:join(Home, "codex-models.json")),
    Info#file_info.mode band 8#777.
script(Responses) -> put(codex_responses, Responses), put(codex_calls, []), nil.
get(Url, Headers) ->
    put(codex_calls, [{Url, Headers} | get(codex_calls)]),
    [Response | Rest] = get(codex_responses),
    put(codex_responses, Rest),
    Response.
calls() -> lists:reverse(get(codex_calls)).
