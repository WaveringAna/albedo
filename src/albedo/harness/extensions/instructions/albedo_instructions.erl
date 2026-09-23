-module(albedo_instructions).

-include_lib("kernel/include/file.hrl").

-export([home/0, load/2, load_selected/3]).

-define(MAX_FILE_BYTES, 1048576).
-define(MAX_FILES, 128).

home() ->
    case os:getenv("HOME") of
        false -> <<>>;
        Value -> unicode:characters_to_binary(Value)
    end.

load(Workspace0, Home0) -> load_impl(Workspace0, Home0, undefined).

load_selected(Workspace0, Home0, Session) ->
    load_impl(Workspace0, Home0, {albedo_extension_settings:home(), Session}).

load_impl(Workspace0, Home0, Selection) ->
    try
        Workspace = text_list(Workspace0),
        Home = text_list(Home0),
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
                case select_files(Files, Selection, []) of
                    {ok, Selected} ->
                        case read_all(Selected, []) of
                            {ok, Loaded} -> {ok, render(Loaded)};
                            Error -> Error
                        end;
                    Error -> Error
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
            albedo_capabilities:enabled(Home, Session, <<"instructions">>, Name)
    end,
    case Enabled of
        {ok, true} -> select_files(Rest, Selection, [File | Selected]);
        {ok, false} -> select_files(Rest, Selection, Selected);
        Error -> Error
    end.

root_files(Workspace) ->
    case file:list_dir(Workspace) of
        {ok, Entries} ->
            [{project, root_display(Name), filename:join(Workspace, Name)}
             || Name <- lists:sort(Entries), instruction_name(Name),
                regular_file(filename:join(Workspace, Name))];
        {error, _} -> []
    end.

instruction_name(Name) ->
    Lower = string:lowercase(Name),
    Lower =:= "agents.md" orelse Lower =:= "claude.md".

directory_files(Scope, Base, Directory) ->
    Root = filename:join(Base, Directory),
    case file:list_dir(Root) of
        {ok, Entries} ->
            [{Scope, directory_display(Scope, Directory, Entry), filename:join(Root, Entry)}
             || Entry <- lists:sort(Entries), markdown(Entry),
                regular_file(filename:join(Root, Entry))];
        {error, _} -> []
    end.

regular_file(Path) ->
    case file:read_file_info(Path) of
        {ok, #file_info{type = regular}} -> true;
        _ -> false
    end.

markdown(Name) ->
    string:lowercase(filename:extension(Name)) =:= ".md".

root_display(Name) -> unicode:characters_to_binary(Name).
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
        render_group(project, Project),
        render_group(global, Global)
    ]).

render_group(_, []) -> [];
render_group(project, Files) ->
    [<<"
## Project-level conventions

Use these for project-level conventions.
">>,
     [render_file(File) || File <- Files]];
render_group(global, Files) ->
    [<<"
## Global user preferences

Use these for acting in the user's preferences.
">>,
     [render_file(File) || File <- Files]].

render_file({_Scope, Display, Contents}) ->
    [<<"
### ">>, Display, <<"

">>, Contents, <<"
">>].

text_list(Value) when is_binary(Value) -> unicode:characters_to_list(Value);
text_list(Value) when is_list(Value) -> Value.
