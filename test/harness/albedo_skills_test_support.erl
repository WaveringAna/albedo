-module(albedo_skills_test_support).
-export([fixture/0, write/3, replace_with_symlink/3, exists/2, serve_once/1, chmod/3, cleanup/1]).

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

serve_once(Body0) ->
    Body = unicode:characters_to_binary(Body0),
    {ok, Listener} = gen_tcp:listen(0, [binary, {active, false}, {ip, {127, 0, 0, 1}}, {reuseaddr, true}]),
    {ok, Port} = inet:port(Listener),
    spawn(fun() ->
        {ok, Socket} = gen_tcp:accept(Listener),
        {ok, _Request} = gen_tcp:recv(Socket, 0, 5000),
        Response = [<<"HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: ">>,
                    integer_to_binary(byte_size(Body)), <<"\r\nconnection: close\r\n\r\n">>, Body],
        ok = gen_tcp:send(Socket, Response),
        gen_tcp:close(Socket),
        gen_tcp:close(Listener)
    end),
    iolist_to_binary(io_lib:format("http://127.0.0.1:~B/models.json", [Port])).

chmod(Base, Relative, Mode) ->
    ok = file:change_mode(filename:join(text(Base), text(Relative)), Mode),
    nil.

cleanup(Root) ->
    _ = file:del_dir_r(Root),
    nil.

text(Value) -> unicode:characters_to_list(Value).
bin(Value) -> unicode:characters_to_binary(Value).
