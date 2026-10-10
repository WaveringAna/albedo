%% gleeunit's runner with every test module started at once, after the timed
%% ones. A module's tests keep running in order, one after another, so tests
%% that share a module's fixtures never race each other. There is no cap:
%% eunit's {inparallel, N, _} runs batches of N and waits out each batch's
%% slowest module.
-module(albedo_test_runner).

-export([main/0]).

%% Modules whose tests wait out a wall-clock window (a runtime that must answer
%% in a second while its store is suspended, a loopback server that must be
%% reached in time). With a hundred modules starting at once those windows are
%% starved, so these run first and alone: each passes under machine load by
%% itself, and failed only against the rest of the suite.
-define(TIMED, ['harness@runtime_test', 'harness@antigravity_errors_test',
                'openai_api@transport_test']).

main() ->
    %% albedo_test.gleam is the executable entrypoint, not a test suite.
    Modules = [module(Path) || Path <- filelib:wildcard("**/*_test.{erl,gleam}", "test"),
                              Path =/= "albedo_test.gleam",
                              not lists:prefix("manual/", Path)],
    case Modules of [] -> error(no_test_modules); _ -> ok end,
    lists:foreach(fun require_tests/1, Modules),
    Timed = [Module || Module <- ?TIMED, lists:member(Module, Modules)],
    Options = [
        verbose,
        no_tty,
        {report, {gleeunit_progress, [{colored, true}]}},
        {scale_timeouts, 10}
    ],
    Result = eunit:test([{inorder, Timed}, {inparallel, Modules -- Timed}], Options),
    albedo_test_home:cleanup(),
    erlang:halt(case Result of ok -> 0; _ -> 1 end).

require_tests(Module) ->
    {module, Module} = code:ensure_loaded(Module),
    HasTests = lists:any(fun({Name, Arity}) ->
        Arity =:= 0 andalso
        (lists:suffix("_test", atom_to_list(Name)) orelse
         lists:suffix("_test_", atom_to_list(Name)))
    end, Module:module_info(exports)),
    case HasTests of
        true -> ok;
        false -> error({no_tests_in_module, Module})
    end.

module(Path) ->
    Name =
        case filename:extension(Path) of
            ".gleam" -> string:replace(filename:rootname(Path), "/", "@", all);
            ".erl" -> filename:basename(Path, ".erl")
        end,
    list_to_atom(lists:flatten(Name)).
