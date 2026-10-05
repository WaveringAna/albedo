%% gleeunit's runner with every test module started at once. A module's tests
%% keep running in order, one after another, so tests that share a module's
%% fixtures never race each other. There is no cap: eunit's {inparallel, N, _}
%% runs batches of N and waits out each batch's slowest module.
-module(albedo_test_runner).

-export([main/0]).

main() ->
    %% albedo_test.gleam is the executable entrypoint, not a test suite.
    Modules = [module(Path) || Path <- filelib:wildcard("**/*_test.{erl,gleam}", "test"),
                              Path =/= "albedo_test.gleam",
                              not lists:prefix("manual/", Path)],
    case Modules of [] -> error(no_test_modules); _ -> ok end,
    lists:foreach(fun require_tests/1, Modules),
    Options = [
        verbose,
        no_tty,
        {report, {gleeunit_progress, [{colored, true}]}},
        {scale_timeouts, 10}
    ],
    Result = eunit:test({inparallel, Modules}, Options),
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
