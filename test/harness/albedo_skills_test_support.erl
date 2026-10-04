-module(albedo_skills_test_support).
-export([fixture/0, write/3, replace_with_symlink/3, exists/2, chmod/3, cleanup/1]).

fixture() ->
    Root = filename:join(os:getenv("TMPDIR", "/tmp"), "albedo-skills-" ++ integer_to_list(erlang:system_time(nanosecond)) ++ "-" ++ integer_to_list(erlang:unique_integer([positive]))),
    Workspace = filename:join(Root, "workspace"),
    Home = filename:join(Root, "home"),
    ok = filelib:ensure_dir(filename:join(Workspace, "placeholder")),
    ok = filelib:ensure_dir(filename:join(Home, "placeholder")),
    {bin(Root), bin(Workspace), bin(Home)}.

write(Base0, Relative0, Content) ->
    Path = filename:join(text(Base0), text(Relative0)),
    ok = filelib:ensure_dir(Path),
    ok = file:write_file(Path, Content),
    bin(Path).

replace_with_symlink(Base0, TargetRelative0, LinkRelative0) ->
    Base = text(Base0),
    Target = filename:join(Base, text(TargetRelative0)),
    Link = filename:join(Base, text(LinkRelative0)),
    ok = file:delete(Link),
    ok = file:make_symlink(Target, Link),
    nil.

exists(Base0, Relative0) ->
    filelib:is_file(filename:join(text(Base0), text(Relative0))).

chmod(Base, Relative, Mode) ->
    ok = file:change_mode(filename:join(text(Base), text(Relative)), Mode),
    nil.

cleanup(Root) ->
    _ = file:del_dir_r(Root),
    nil.

text(Value) -> unicode:characters_to_list(Value).
bin(Value) -> unicode:characters_to_binary(Value).
