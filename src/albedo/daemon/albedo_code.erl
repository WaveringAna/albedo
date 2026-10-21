%% The daemon runs for days on an Erlang install that a package manager can
%% replace underneath it. Modules load on first call, so once the old install
%% is deleted, the first call into an OTP module nothing has loaded yet fails
%% with undef: a Homebrew upgrade left a settings publication half done this
%% way, and every settings read afterwards failed. preload/0 loads at boot
%% everything the daemon can reach, as Erlang's embedded mode does from a
%% release boot script, so later deletion of the install's files cannot strand
%% it; runtime_removed/0 reports the deletion for what preloading cannot cover
%% (ERTS port programs, OTP priv files).
-module(albedo_code).
-export([start/0, preload/0, runtime_removed/0]).

%% Preloads in the background; a module that will not load is reported once.
%% The outcome stays in a persistent term for inspection.
start() ->
    _ = spawn(fun() ->
        Outcome = try preload() catch Class:Reason ->
            {error, iolist_to_binary(io_lib:format("preload failed: ~p:~0p", [Class, Reason]))}
        end,
        case Outcome of
            {ok, _} -> ok;
            {error, Detail} -> io:format("code preload: ~ts~n", [Detail])
        end,
        persistent_term:put({?MODULE, preloaded}, Outcome)
    end),
    nil.

%% {ok, Count} once every reachable module is loaded, or {error, Detail} naming
%% the modules that would not load (each one still fails only when called).
preload() ->
    Index = index(),
    Apps = close([], [albedo], Index),
    Modules = lists:usort(beams(filename:join(code:lib_dir(albedo), "ebin"))
        ++ lists:append([app_modules(App) || App <- Apps])),
    case code:ensure_modules_loaded(Modules) of
        ok -> {ok, length(Modules)};
        {error, Failed} ->
            Names = lists:join(<<", ">>, [atom_to_binary(Module) || {Module, _} <- lists:sublist(Failed, 10)]),
            {error, iolist_to_binary([integer_to_binary(length(Failed)), <<" modules did not preload: ">>, Names])}
    end.

%% True once the Erlang install this node was started from is gone.
runtime_removed() ->
    not filelib:is_dir(filename:join(code:root_dir(), "lib")).

%% The applications reachable from the daemon: declared dependencies and the
%% owners of every module an application's code imports. Build tools on the
%% code path (Elixir, Mix) stay out unless something calls into them.
close(Done, [], _Index) -> lists:reverse(Done);
close(Done, [App | Rest], Index) ->
    case lists:member(App, Done) of
        true -> close(Done, Rest, Index);
        false ->
            Declared = app_key(App, applications) ++ app_key(App, included_applications),
            Called = [Owner || Module <- app_modules(App), Imported <- imports(Module),
                               {ok, Owner} <- [maps:find(Imported, Index)]],
            close([App | Done], Rest ++ lists:usort(Declared ++ Called), Index)
    end.

imports(Module) ->
    case code:where_is_file(atom_to_list(Module) ++ ".beam") of
        non_existing -> [];
        File ->
            case beam_lib:chunks(File, [imports]) of
                {ok, {_, [{imports, Imports}]}} -> lists:usort([M || {M, _, _} <- Imports]);
                _ -> []
            end
    end.

%% Module => application for every application directory on the code path.
index() ->
    maps:from_list([{list_to_atom(filename:basename(Beam, ".beam")), App}
        || Dir <- code:get_path(), AppFile <- filelib:wildcard(filename:join(Dir, "*.app")),
           App <- [list_to_atom(filename:basename(AppFile, ".app"))],
           Beam <- filelib:wildcard(filename:join(Dir, "*.beam"))]).

app_modules(App) -> app_key(App, modules).

app_key(App, Key) ->
    _ = application:load(App),
    case application:get_key(App, Key) of
        {ok, Values} -> Values;
        undefined -> []
    end.

beams(Dir) -> [list_to_atom(filename:basename(Beam, ".beam")) || Beam <- filelib:wildcard(filename:join(Dir, "*.beam"))].
