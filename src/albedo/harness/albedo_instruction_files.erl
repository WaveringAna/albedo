-module(albedo_instruction_files).

-include_lib("kernel/include/file.hrl").

-export([home/0, discover_instructions/2, discover_named/3, read/2]).

-define(MAX_FILE_BYTES, 1048576).
-define(MAX_FILES, 128).

home() -> albedo_daemon:env(<<"HOME">>).

discover_named(Workspace0, Home0, Name) ->
    try
        Lower = string:lowercase(unicode:characters_to_list(Name)),
        Match = fun(Entry) -> string:lowercase(Entry) =:= Lower end,
        discover_checked(Workspace0, Home0, Match, Match, <<"prompt">>)
    catch
        _:_ -> {error, <<"prompt file discovery failed">>}
    end.

discover_instructions(Workspace0, Home0) ->
    try
        discover_checked(Workspace0, Home0, fun instruction_name/1,
                         fun markdown/1, <<"instruction">>)
    catch
        _:_ -> {error, <<"instruction file discovery failed">>}
    end.

discover_checked(Workspace0, Home0, RootMatch, DirectoryMatch, Kind) ->
    Files = discover(unicode:characters_to_list(Workspace0),
                     unicode:characters_to_list(Home0), RootMatch, DirectoryMatch),
    case length(Files) =< ?MAX_FILES of
        true -> {ok, Files};
        false -> {error, <<"more than 128 ", Kind/binary, " files were discovered">>}
    end.

discover(Workspace, Home, RootMatch, DirectoryMatch) ->
    Project = root_files(Workspace, RootMatch)
              ++ directory_files(project_agents, Workspace, ".agents", DirectoryMatch)
              ++ directory_files(project_albedo, Workspace, ".albedo", DirectoryMatch),
    Global = case Home of
        [] -> [];
        _ -> directory_files(global_agents, Home, ".agents", DirectoryMatch)
             ++ directory_files(global_albedo, Home, ".albedo", DirectoryMatch)
    end,
    Project ++ Global.

root_files(Workspace, Match) ->
    listed(project_root, Workspace, fun unicode:characters_to_binary/1, Match).

instruction_name(Name) ->
    Lower = string:lowercase(Name),
    Lower =:= "agents.md" orelse Lower =:= "claude.md".

directory_files(Location, Base, Directory, Match) ->
    listed(Location, filename:join(Base, Directory),
           fun(Entry) -> directory_display(Location, Directory, Entry) end,
           Match).

%% Sorted regular files of one directory that satisfy Keep, tagged with their
%% location and shown as Display names. Tuple tags match Gleam's Candidate.
listed(Location, Root, Display, Keep) ->
    case file:list_dir(Root) of
        {ok, Entries} ->
            [{candidate, Location, Display(Entry), unicode:characters_to_binary(Path)}
             || Entry <- lists:sort(Entries), Keep(Entry),
                Path <- [filename:join(Root, Entry)],
                filelib:is_regular(Path)];
        {error, _} -> []
    end.

markdown(Name) ->
    Lower = string:lowercase(Name),
    string:lowercase(filename:extension(Name)) =:= ".md"
    andalso Lower =/= "system.md" andalso Lower =/= "append_system.md".

directory_display(Location, Directory, Entry)
  when Location =:= project_agents; Location =:= project_albedo ->
    unicode:characters_to_binary(filename:join(Directory, Entry));
directory_display(Location, Directory, Entry)
  when Location =:= global_agents; Location =:= global_albedo ->
    unicode:characters_to_binary(filename:join(["~", Directory, Entry])).

read(Files, instructions) -> read_files(Files, ?MAX_FILE_BYTES, <<"instruction">>);
read(Files, prompts) -> read_files(Files, unlimited, <<"prompt">>).

read_files(Files, Limit, Kind) ->
    try read_all(Files, [], [], Limit)
    catch
        _:_ -> {error, <<Kind/binary, " file discovery failed">>}
    end.

read_all([], Loaded, Warnings, _) ->
    {ok, {lists:reverse(Loaded), lists:reverse(Warnings)}};
read_all([File = {candidate, _Location, Display, Path} | Rest], Loaded, Warnings, Limit) ->
    case read_text(Path, Display, Limit) of
        {ok, Text} ->
            read_all(Rest, [{File, Text} | Loaded], Warnings, Limit);
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
