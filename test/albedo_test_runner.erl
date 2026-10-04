%% gleeunit's runner with every test module started at once. A module's tests
%% keep running in order, one after another, so tests that share a module's
%% fixtures never race each other. There is no cap: eunit's {inparallel, N, _}
%% runs batches of N and waits out each batch's slowest module.
-module(albedo_test_runner).

-export([main/0]).

main() ->
    Modules = [module(Path) || Path <- filelib:wildcard("**/*.{erl,gleam}", "test"),
                              not lists:prefix("manual/", Path)],
    Options = [
        verbose,
        no_tty,
        {report, {gleeunit_progress, [{colored, true}]}},
        {scale_timeouts, 10}
    ],
    Result = eunit:test({inparallel, Modules}, Options),
    albedo_test_home:cleanup(),
    erlang:halt(case Result of ok -> 0; _ -> 1 end).

module(Path) ->
    Name =
        case filename:extension(Path) of
            ".gleam" -> string:replace(filename:rootname(Path), "/", "@", all);
            ".erl" -> filename:basename(Path, ".erl")
        end,
    list_to_atom(lists:flatten(Name)).
