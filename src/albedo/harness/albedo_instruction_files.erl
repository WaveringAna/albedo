-module(albedo_instruction_files).

-include_lib("kernel/include/file.hrl").

-export([home/0, load/2, load_selected/3, named/4]).

-define(MAX_FILE_BYTES, 1048576).
-define(MAX_FILES, 128).

home() -> albedo_daemon:env(<<"HOME">>).

%% First match wins for a replacement; append files concatenate in discovery order.
named(Workspace0, Home0, Name, Mode) ->
    try
        Lower = string:lowercase(unicode:characters_to_list(Name)),
        Match = fun(Entry) -> string:lowercase(Entry) =:= Lower end,
        Files = discover(unicode:characters_to_list(Workspace0),
                         unicode:characters_to_list(Home0), Match, Match),
        case length(Files) =< ?MAX_FILES of
            false -> {error, <<"more than 128 prompt files were discovered">>};
            true ->
                Chosen = case {Mode, Files} of
                    {first, [File | _]} -> [File];
                    {first, []} -> [];
                    {all, _} -> Files
                end,
                case read_all(Chosen, [], [], unlimited) of
                    {ok, {[], _}} -> {ok, none};
                    {ok, {Loaded, _}} ->
                        {ok, {some, iolist_to_binary(lists:join(<<"\n\n">>,
                            [Text || {_, _, Text} <- Loaded]))}};
                    Error -> Error
                end
        end
    catch
        _:_ -> {error, <<"prompt file discovery failed">>}
    end.

load(Workspace0, Home0) ->
    case load_impl(Workspace0, Home0, undefined) of
        {ok, {Context, _Warnings}} -> {ok, Context};
        Error -> Error
    end.

load_selected(Workspace0, Home0, Session) ->
    load_impl(Workspace0, Home0, {albedo_extension_settings:home(), Session}).

load_impl(Workspace0, Home0, Selection) ->
    try
        Files = discover(unicode:characters_to_list(Workspace0),
                         unicode:characters_to_list(Home0),
                         fun instruction_name/1, fun markdown/1),
        case length(Files) =< ?MAX_FILES of
            false -> {error, <<"more than 128 instruction files were discovered">>};
            true ->
                maybe
                    {ok, Selected} ?= select_files(Files, Selection, []),
                    {ok, {Loaded, Warnings}} ?= read_all(Selected, [], [], ?MAX_FILE_BYTES),
                    {ok, {render(Loaded), Warnings}}
                end
        end
    catch
        _:_ -> {error, <<"instruction file discovery failed">>}
    end.

select_files([], _, Selected) -> {ok, lists:reverse(Selected)};
select_files([File = {Scope, Display, _} | Rest], Selection, Selected) ->
    Enabled = case Selection of
        undefined -> {ok, true};
        {Home, Session} ->
            Name = <<(atom_to_binary(Scope))/binary, ":", Display/binary>>,
            SelectedSession = case Session of undefined -> none; _ -> {some, Session} end,
            'albedo@harness@capabilities':optional(SelectedSession, Home, <<"instructions">>, Name)
    end,
    case Enabled of
        {ok, true} -> select_files(Rest, Selection, [File | Selected]);
        {ok, false} -> select_files(Rest, Selection, Selected);
        Error -> Error
    end.

discover(Workspace, Home, RootMatch, DirectoryMatch) ->
    Project = root_files(Workspace, RootMatch)
              ++ directory_files(project, Workspace, ".agents", DirectoryMatch)
              ++ directory_files(project, Workspace, ".albedo", DirectoryMatch),
    Global = case Home of
        [] -> [];
        _ -> directory_files(global, Home, ".agents", DirectoryMatch)
             ++ directory_files(global, Home, ".albedo", DirectoryMatch)
    end,
    Project ++ Global.

root_files(Workspace, Match) ->
    listed(project, Workspace, fun unicode:characters_to_binary/1, Match).

instruction_name(Name) ->
    Lower = string:lowercase(Name),
    Lower =:= "agents.md" orelse Lower =:= "claude.md".

directory_files(Scope, Base, Directory, Match) ->
    listed(Scope, filename:join(Base, Directory),
           fun(Entry) -> directory_display(Scope, Directory, Entry) end,
           Match).

%% Sorted regular files of one directory that satisfy Keep, tagged with their
%% discovery scope and shown as Display names.
listed(Scope, Root, Display, Keep) ->
    case file:list_dir(Root) of
        {ok, Entries} ->
            [{Scope, Display(Entry), Path}
             || Entry <- lists:sort(Entries), Keep(Entry),
                Path <- [filename:join(Root, Entry)],
                filelib:is_regular(Path)];
        {error, _} -> []
    end.

markdown(Name) ->
    Lower = string:lowercase(Name),
    string:lowercase(filename:extension(Name)) =:= ".md"
    andalso Lower =/= "system.md" andalso Lower =/= "append_system.md".

directory_display(project, Directory, Entry) ->
    unicode:characters_to_binary(filename:join(Directory, Entry));
directory_display(global, Directory, Entry) ->
    unicode:characters_to_binary(filename:join(["~", Directory, Entry])).

read_all([], Loaded, Warnings, _) ->
    {ok, {lists:reverse(Loaded), lists:reverse(Warnings)}};
read_all([{Scope, Display, Path} | Rest], Loaded, Warnings, Limit) ->
    case read_text(Path, Display, Limit) of
        {ok, Text} ->
            read_all(Rest, [{Scope, Display, Text} | Loaded], Warnings, Limit);
        {skip, Warning} -> read_all(Rest, Loaded, [Warning | Warnings], Limit);
        Error -> Error
    end.

read_text(Path, Display, Limit) ->
    case file:read_file_info(Path) of
        {ok, #file_info{type = regular, size = Size}}
          when Limit =:= unlimited; Size =< Limit ->
            case file:read_file(Path) of
                {ok, Contents} ->
                    case unicode:characters_to_binary(Contents, utf8, utf8) of
                        Text when is_binary(Text) -> {ok, Text};
                        _ -> file_error(Display, <<"must be UTF-8 text">>)
                    end;
                {error, _} -> file_error(Display, <<"cannot be read">>)
            end;
        {ok, #file_info{type = regular}} ->
            {skip, iolist_to_binary([Display,
                <<" exceeds 1 MiB and was not loaded">>])};
        _ -> file_error(Display, <<"is no longer a regular file">>)
    end.

file_error(Display, Message) ->
    {error, iolist_to_binary([Display, <<" ">>, Message])}.

render([]) -> <<>>;
render(Loaded) ->
    Project = [File || {project, _, _} = File <- Loaded],
    Global = [File || {global, _, _} = File <- Loaded],
    iolist_to_binary([
        <<"# Autoloaded instructions

"
          "Project-level files define conventions for this project. Global-level files "
          "describe the user's general preferences. Apply both; when they conflict on "
          "project-specific work, follow the project-level convention. Files at the same "
          "level are concatenated rather than overriding one another.
">>,
        render_group(<<"
## Project-level conventions

Use these for project-level conventions.
">>, Project),
        render_group(<<"
## Global user preferences

Use these for acting in the user's preferences.
">>, Global)
    ]).

render_group(_, []) -> [];
render_group(Header, Files) ->
    [Header, [render_file(File) || File <- Files]].

render_file({_Scope, Display, Contents}) ->
    [<<"
### ">>, Display, <<"

">>, Contents, <<"
">>].
