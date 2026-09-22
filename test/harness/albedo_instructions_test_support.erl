-module(albedo_instructions_test_support).
-export([fixture/0, empty_fixture/0, cleanup/1]).

fixture() ->
    Root = filename:join("/tmp", "albedo-instructions-" ++ binary_to_list(albedo_native:new_id())),
    Project = filename:join(Root, "project"),
    Home = filename:join(Root, "home"),
    ok = filelib:ensure_dir(filename:join([Project, ".agents", "placeholder"])),
    ok = filelib:ensure_dir(filename:join([Project, ".albedo", "placeholder"])),
    ok = filelib:ensure_dir(filename:join([Home, ".agents", "placeholder"])),
    ok = filelib:ensure_dir(filename:join([Home, ".albedo", "placeholder"])),
    ok = file:write_file(filename:join(Project, "AGENTS.md"), <<"root project convention">>),
    ok = file:write_file(filename:join([Project, ".agents", "AGENTS.md"]), <<"nested project convention">>),
    ok = file:write_file(filename:join([Project, ".albedo", "notes.md"]), <<"albedo project convention">>),
    ok = file:write_file(filename:join([Project, ".albedo", "extensions.json"]), <<"must not load">>),
    ok = file:write_file(filename:join([Home, ".agents", "AGENTS.md"]), <<"global preference one">>),
    ok = file:write_file(filename:join([Home, ".albedo", "CLAUDE.md"]), <<"global preference two">>),
    {unicode:characters_to_binary(Root), unicode:characters_to_binary(Project),
     unicode:characters_to_binary(Home)}.

empty_fixture() ->
    Root = filename:join("/tmp", "albedo-instructions-" ++ binary_to_list(albedo_native:new_id())),
    Project = filename:join(Root, "project"),
    Home = filename:join(Root, "home"),
    ok = filelib:ensure_dir(filename:join(Project, "placeholder")),
    ok = filelib:ensure_dir(filename:join(Home, "placeholder")),
    {unicode:characters_to_binary(Root), unicode:characters_to_binary(Project),
     unicode:characters_to_binary(Home)}.

cleanup(Root) ->
    file:del_dir_r(Root),
    nil.
