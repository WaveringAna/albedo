-module(albedo_instructions).

-include_lib("kernel/include/file.hrl").

-export([home/0, load/2, load_selected/3]).

-define(MAX_FILE_BYTES, 1048576).
-define(MAX_FILES, 128).

home() -> albedo_daemon:env(<<"HOME">>).

load(Workspace0, Home0) -> load_impl(Workspace0, Home0, undefined).

load_selected(Workspace0, Home0, Session) ->
    load_impl(Workspace0, Home0, {albedo_extension_settings:home(), Session}).

load_impl(Workspace0, Home0, Selection) ->
    try
        Workspace = unicode:characters_to_list(Workspace0),
        Home = unicode:characters_to_list(Home0),
        Project = root_files(Workspace) ++ directory_files(project, Workspace, ".agents")
                  ++ directory_files(project, Workspace, ".albedo"),
        Global = case Home of
            [] -> [];
            _ -> directory_files(global, Home, ".agents")
                 ++ directory_files(global, Home, ".albedo")
        end,
        Files = Project ++ Global,
        case length(Files) =< ?MAX_FILES of
            false -> {error, <<"more than 128 instruction files were discovered">>};
            true ->
                maybe
                    {ok, Selected} ?= select_files(Files, Selection, []),
                    {ok, Loaded} ?= read_all(Selected, []),
                    {ok, render(Loaded)}
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
            albedo_capabilities:optional(Session, Home, <<"instructions">>, Name)
    end,
    case Enabled of
        {ok, true} -> select_files(Rest, Selection, [File | Selected]);
        {ok, false} -> select_files(Rest, Selection, Selected);
        Error -> Error
    end.

root_files(Workspace) ->
    listed(project, Workspace, fun unicode:characters_to_binary/1, fun instruction_name/1).

instruction_name(Name) ->
    Lower = string:lowercase(Name),
    Lower =:= "agents.md" orelse Lower =:= "claude.md".

directory_files(Scope, Base, Directory) ->
    listed(Scope, filename:join(Base, Directory),
           fun(Entry) -> directory_display(Scope, Directory, Entry) end,
           fun markdown/1).

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
    string:lowercase(filename:extension(Name)) =:= ".md".

directory_display(project, Directory, Entry) ->
    unicode:characters_to_binary(filename:join(Directory, Entry));
directory_display(global, Directory, Entry) ->
    unicode:characters_to_binary(filename:join(["~", Directory, Entry])).

read_all([], Loaded) -> {ok, lists:reverse(Loaded)};
read_all([{Scope, Display, Path} | Rest], Loaded) ->
    case file:read_file_info(Path) of
        {ok, #file_info{type = regular, size = Size}} when Size =< ?MAX_FILE_BYTES ->
            case file:read_file(Path) of
                {ok, Contents} ->
                    case unicode:characters_to_binary(Contents, utf8, utf8) of
                        Text when is_binary(Text) ->
                            read_all(Rest, [{Scope, Display, Text} | Loaded]);
                        _ -> file_error(Display, <<"must be UTF-8 text">>)
                    end;
                {error, _} -> file_error(Display, <<"cannot be read">>)
            end;
        {ok, #file_info{type = regular}} ->
            file_error(Display, <<"exceeds 1048576 bytes">>);
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
