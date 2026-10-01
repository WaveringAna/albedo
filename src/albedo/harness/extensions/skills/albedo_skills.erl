-module(albedo_skills).

-include_lib("kernel/include/file.hrl").

-export([home/0, builtin_root/0, catalog/3, activate_selected/1, list_selected/1, read_selected/4, list_resources/3, xml_escape/1]).

-define(MAX_SKILLS, 128).
-define(MAX_DIAGNOSTICS, 64).
-define(MAX_FRONTMATTER_BYTES, 65536).
-define(MAX_SKILL_BYTES, 1048576).
-define(MAX_RESOURCE_BYTES, 16777216).
-define(MAX_RESOURCES, 512).
-define(MAX_RESOURCE_ENTRIES, 2048).
-define(MAX_RESOURCE_DEPTH, 16).
-define(MAX_READ_BYTES, 65536).

xml_escape(Value) ->
    try
        Codepoints = unicode:characters_to_list(Value),
        iolist_to_binary([xml_codepoint(Codepoint) || Codepoint <- Codepoints])
    catch
        _:_ -> <<"[invalid text]">>
    end.

xml_codepoint($&) -> <<"&amp;">>;
xml_codepoint($<) -> <<"&lt;">>;
xml_codepoint($>) -> <<"&gt;">>;
xml_codepoint($") -> <<"&quot;">>;
xml_codepoint($') -> <<"&apos;">>;
xml_codepoint(Codepoint)
  when Codepoint =:= 9; Codepoint =:= 10; Codepoint =:= 13;
       Codepoint >= 16#20, Codepoint =< 16#D7FF;
       Codepoint >= 16#E000, Codepoint =< 16#FFFD;
       Codepoint >= 16#10000, Codepoint =< 16#10FFFF ->
    unicode:characters_to_binary([Codepoint]);
xml_codepoint(_) -> <<16#EF, 16#BF, 16#BD>>.

home() -> albedo_daemon:env(<<"HOME">>).

%% Skills shipped with albedo live in priv/skills; the empty string disables them.
builtin_root() ->
    case code:priv_dir(albedo) of
        {error, _} -> <<>>;
        Priv -> unicode:characters_to_binary(filename:join(Priv, "skills"))
    end.

%% Built-in skills rank below every workspace and user skill, so a same-named
%% skill there replaces one silently instead of reporting a duplicate.
catalog(Workspace0, Home0, Builtin0) ->
    try
        Roots = roots(text_list(Workspace0), text_list(Home0)),
        {Selected0, Diagnostics0, Count0, Limited0} =
            scan_roots(Roots, #{}, [], 0, false),
        {Builtin, Diagnostics2, Count, Limited} =
            scan_roots(builtin_roots(text_list(Builtin0)), #{}, Diagnostics0, Count0, Limited0),
        Selected = maps:merge(Builtin, Selected0),
        Diagnostics1 = [<<"skill discovery limit reached; remaining entries ignored">> || Limited] ++ Diagnostics2,
        Skills = lists:sort(maps:values(Selected)),
        {ok, {Skills, limit_diagnostics(lists:reverse(Diagnostics1)), Count}}
    catch
        _:_ -> {error, <<"skill discovery failed">>}
    end.

activate_selected(SkillFile0) ->
    try
        case valid_selected_skill(text_list(SkillFile0)) of
            {ok, {Name, Description, Canonical}} ->
                case file:read_file(Canonical) of
                    {ok, Instructions} when byte_size(Instructions) > ?MAX_SKILL_BYTES ->
                        {error, <<"SKILL.md exceeds 1048576 bytes">>};
                    {ok, Instructions} ->
                        case unicode:characters_to_binary(Instructions, utf8, utf8) of
                            Instructions ->
                                {ok, {Name, Description,
                                      unicode:characters_to_binary(Canonical),
                                      Instructions}};
                            _ -> {error, <<"SKILL.md must be UTF-8 text">>}
                        end;
                    {error, _} -> {error, <<"SKILL.md cannot be read">>}
                end;
            Error -> Error
        end
    catch
        _:_ -> {error, <<"skill activation failed">>}
    end.

%% Resolve the current catalog identity before listing; unlike list_selected/1,
%% callers of this API supply a workspace and catalog path, not a selected file.
list_resources(Workspace, Home, Identity) ->
    try
        case catalog(Workspace, Home, builtin_root()) of
            {ok, {Skills, _Diagnostics, _Count}} ->
                case lists:keyfind(unicode:characters_to_binary(Identity), 3, Skills) of
                    false -> {error, <<"unknown skill path; use a path from the current catalog">>};
                    {_Name, _Description, SkillFile} -> list_selected(SkillFile)
                end;
            Error -> Error
        end
    catch
        _:_ -> {error, <<"resource listing failed">>}
    end.

list_selected(SkillFile0) ->
    try
        case valid_selected_skill(text_list(SkillFile0)) of
            {ok, {_Name, _Description, Canonical}} ->
                Root = filename:dirname(Canonical),
                {Files0, Diagnostics0, _Seen, _Entries, Truncated} =
                    walk_resources(Root, Root, "", 0, [], [], #{}, 0, false),
                {ok, {lists:sort(Files0), Truncated,
                      limit_diagnostics(lists:reverse(Diagnostics0))}};
            Error -> Error
        end
    catch
        _:_ -> {error, <<"resource listing failed">>}
    end.

read_selected(SkillFile0, Relative0, Offset, Limit)
  when is_integer(Offset), Offset >= 0, is_integer(Limit), Limit >= 1, Limit =< ?MAX_READ_BYTES ->
    try
        case valid_selected_skill(text_list(SkillFile0)) of
            {ok, {_Name, _Description, Canonical}} ->
                read_selected_resource(filename:dirname(Canonical),
                                       text_list(Relative0), Offset, Limit);
            Error -> Error
        end
    catch
        _:_ -> {error, <<"resource read failed">>}
    end;
read_selected(_SkillFile0, _Relative0, _Offset, _Limit) ->
    {error, <<"offset must be nonnegative and limit must be 1..65536">>}.

valid_selected_skill(SkillFile0) ->
    Selected = filename:absname(SkillFile0),
    case realpath(Selected) of
        {ok, Canonical} when Canonical =/= Selected ->
            {error, <<"selected SKILL.md identity changed; reload the skills extension">>};
        {ok, Canonical} ->
            case filename:basename(Canonical) of
                "SKILL.md" ->
                    case file:read_file_info(Canonical) of
                        {ok, #file_info{type = regular, size = Size}}
                          when Size > ?MAX_SKILL_BYTES ->
                            {error, <<"SKILL.md exceeds 1048576 bytes">>};
                        {ok, #file_info{type = regular}} ->
                            case frontmatter(Canonical) of
                                {ok, Name, Description} ->
                                    {ok, {Name, Description, Canonical}};
                                {error, Message} ->
                                    {error, unicode:characters_to_binary(Message)}
                            end;
                        _ -> {error, <<"selected SKILL.md is unavailable">>}
                    end;
                _ -> {error, <<"selected path is not SKILL.md">>}
            end;
        {error, _} -> {error, <<"selected SKILL.md is unavailable">>}
    end.

roots(Workspace, Home) ->
    Project = [filename:join([Workspace, ".albedo", "skills"]),
               filename:join([Workspace, ".agents", "skills"])],
    User = case Home of
        [] -> [];
        _ -> [filename:join([Home, ".albedo", "skills"]),
              filename:join([Home, ".agents", "skills"])]
    end,
    Project ++ User.

builtin_roots([]) -> [];
builtin_roots(Root) -> [Root].

scan_roots([], Selected, Diagnostics, Count, Limited) ->
    {Selected, Diagnostics, Count, Limited};
scan_roots([_ | Rest], Selected, Diagnostics, Count, _Limited)
  when Count >= ?MAX_SKILLS ->
    scan_roots(Rest, Selected, Diagnostics, Count, true);
scan_roots([Root0 | Rest], Selected, Diagnostics, Count, Limited) ->
    case root_entries(Root0) of
        {ok, Root, Entries} ->
            {Selected1, Diagnostics1, Count1, Limited1} =
                scan_entries(Entries, Root, Selected, Diagnostics, Count, Limited),
            scan_roots(Rest, Selected1, Diagnostics1, Count1, Limited1);
        {error, Msg} ->
            scan_roots(Rest, Selected,
                       [diagnostic(Root0, Msg) | Diagnostics],
                       Count, Limited);
        ignore ->
            scan_roots(Rest, Selected, Diagnostics, Count, Limited)
    end.

root_entries(Root0) ->
    case realpath(Root0) of
        {ok, Root} ->
            case file:list_dir(Root) of
                {ok, Entries} -> {ok, Root, lists:sort(Entries)};
                {error, enoent} -> ignore;
                {error, enotdir} -> {error, "is not a directory"};
                {error, _} -> {error, "cannot be listed"}
            end;
        {error, enoent} -> ignore;
        {error, _} -> {error, "cannot be resolved"}
    end.

scan_entries([], _Root, Selected, Diagnostics, Count, Limited) ->
    {Selected, Diagnostics, Count, Limited};
scan_entries(_Entries, _Root, Selected, Diagnostics, Count, _Limited)
  when Count >= ?MAX_SKILLS ->
    {Selected, Diagnostics, Count, true};
scan_entries([Entry | Rest], Root, Selected, Diagnostics, Count, Limited) ->
    Candidate = filename:join(Root, Entry),
    case candidate(Root, Candidate, Entry) of
        skip ->
            scan_entries(Rest, Root, Selected, Diagnostics, Count, Limited);
        {error, Message} ->
            scan_entries(Rest, Root, Selected,
                         [diagnostic(Candidate, Message) | Diagnostics],
                         Count + 1, Limited);
        {ok, {Name, _Description, SkillFile} = Skill} ->
            {Selected1, Diagnostics1} = case maps:find(Name, Selected) of
                error ->
                    {maps:put(Name, Skill, Selected), Diagnostics};
                {ok, {_OldName, _OldDescription, Winner}} ->
                    Message = iolist_to_binary([
                        <<"duplicate skill ">>, Name, <<" ignored; using ">>, Winner]),
                    {Selected, [diagnostic(SkillFile, Message) | Diagnostics]}
            end,
            scan_entries(Rest, Root, Selected1, Diagnostics1, Count + 1, Limited)
    end.

candidate(Root, Candidate, Entry) ->
    case file:read_link_info(Candidate) of
        {ok, #file_info{type = Type}} when Type =:= directory; Type =:= symlink ->
            case realpath(Candidate) of
                {ok, Directory} ->
                    case within(Directory, Root) of
                        false -> {error, "skill directory symlink escapes discovery root"};
                        true ->
                            case file:read_file_info(Directory) of
                                {ok, #file_info{type = directory}} ->
                                    parse_skill(Root, Directory, filename:join(Directory, "SKILL.md"), Entry);
                                _ -> skip
                            end
                    end;
                {error, _} -> {error, "skill directory cannot be resolved"}
            end;
        {ok, _} -> skip;
        {error, _} -> {error, "cannot be inspected"}
    end.

parse_skill(Root, Directory, Skill0, Entry) ->
    case realpath(Skill0) of
        {ok, SkillFile} ->
            case within(SkillFile, Directory) andalso within(SkillFile, Root) of
                false -> {error, "SKILL.md symlink escapes skill root"};
                true ->
                    case file:read_file_info(SkillFile) of
                        {ok, #file_info{type = regular, size = Size}}
                          when Size > ?MAX_SKILL_BYTES ->
                            {error, "SKILL.md exceeds 1048576 bytes"};
                        {ok, #file_info{type = regular}} ->
                            case frontmatter(SkillFile) of
                                {ok, Name, Description} ->
                                    case Name =:= unicode:characters_to_binary(Entry) of
                                        true -> {ok, {Name, Description,
                                                      unicode:characters_to_binary(SkillFile)}};
                                        false -> {error, "frontmatter name must match directory name"}
                                    end;
                                Error -> Error
                            end;
                        {ok, _} -> {error, "SKILL.md is not a regular file"};
                        {error, _} -> {error, "SKILL.md cannot be inspected"}
                    end
            end;
        {error, enoent} -> {error, "missing SKILL.md"};
        {error, _} -> {error, "SKILL.md cannot be resolved"}
    end.

frontmatter(Path) ->
    case file:open(Path, [read, binary, raw]) of
        {ok, Io} ->
            Read = file:pread(Io, 0, ?MAX_FRONTMATTER_BYTES + 1),
            ok = file:close(Io),
            case Read of
                {ok, Data} -> extract_frontmatter(Data);
                eof -> {error, "empty SKILL.md"};
                {error, _} -> {error, "SKILL.md cannot be read"}
            end;
        {error, _} -> {error, "SKILL.md cannot be read"}
    end.

extract_frontmatter(Data) ->
    Lines = binary:split(Data, <<"
">>, [global]),
    case Lines of
        [First | Rest] ->
            case strip_cr(First) of
                <<"---">> -> find_frontmatter_end(Rest, [], byte_size(First) + 1);
                _ -> {error, "SKILL.md must begin with YAML frontmatter"}
            end;
        _ -> {error, "empty SKILL.md"}
    end.

find_frontmatter_end([], _Acc, _Bytes) ->
    {error, "YAML frontmatter is not closed within 65536 bytes"};
find_frontmatter_end([Line | _Rest], _Acc, Bytes)
  when Bytes + byte_size(Line) + 1 > ?MAX_FRONTMATTER_BYTES ->
    {error, "YAML frontmatter exceeds 65536 bytes"};
find_frontmatter_end([Line | Rest], Acc, Bytes) ->
    case strip_cr(Line) of
        <<"---">> -> parse_yaml(iolist_to_binary(lists:join(<<"
">>, lists:reverse(Acc))));
        _ -> find_frontmatter_end(Rest, [Line | Acc], Bytes + byte_size(Line) + 1)
    end.

parse_yaml(Yaml) ->
    _ = application:ensure_all_started(yamerl),
    try yamerl_constr:string(Yaml, [
            {schema, failsafe},
            {node_mods, []},
            {keep_duplicate_keys, true},
            {ignore_unrecognized_tags, false}
        ]) of
        [Document] when is_list(Document) -> metadata(Document);
        _ -> {error, "frontmatter must contain one YAML mapping"}
    catch
        _:_ -> {error, "invalid YAML frontmatter"}
    end.

metadata(Document) ->
    case lists:all(fun({_, _}) -> true; (_) -> false end, Document) of
        false -> {error, "frontmatter must be a YAML mapping"};
        true ->
            case {proplists:get_all_values("name", Document),
                  proplists:get_all_values("description", Document)} of
                {[Name0], [Description0]} when is_list(Name0), is_list(Description0) ->
                    validate_metadata(Name0, Description0);
                {[], _} -> {error, "frontmatter is missing name"};
                {_, []} -> {error, "frontmatter is missing description"};
                {[_], [_]} -> {error, "name and description must be YAML strings"};
                _ -> {error, "frontmatter has duplicate name or description fields"}
            end
    end.

validate_metadata(Name0, Description0) ->
    try
        Name = unicode:characters_to_binary(Name0),
        Description = unicode:characters_to_binary(string:trim(Description0)),
        NameValid = byte_size(Name) >= 1 andalso byte_size(Name) =< 64
            andalso re:run(Name, <<"^[a-z0-9]+(?:-[a-z0-9]+)*$">>,
                           [{capture, none}, unicode]) =:= match,
        DescriptionValid = byte_size(Description) >= 1
            andalso length(unicode:characters_to_list(Description)) =< 1024,
        case {NameValid, DescriptionValid} of
            {true, true} -> {ok, Name, Description};
            {false, _} -> {error, "frontmatter name is invalid"};
            {_, false} -> {error, "frontmatter description is invalid"}
        end
    catch
        _:_ -> {error, "frontmatter strings must be valid UTF-8"}
    end.

walk_resources(_Root, _Directory, _Relative, _Depth, Files, Diagnostics,
               Seen, Entries, _Truncated)
  when length(Files) >= ?MAX_RESOURCES; Entries >= ?MAX_RESOURCE_ENTRIES ->
    {Files, Diagnostics, Seen, Entries, true};
walk_resources(_Root, _Directory, _Relative, Depth, Files, Diagnostics,
               Seen, Entries, _Truncated)
  when Depth > ?MAX_RESOURCE_DEPTH ->
    {Files, [<<"resource depth limit reached">> | Diagnostics], Seen,
     Entries, true};
walk_resources(Root, Directory, Relative, Depth, Files, Diagnostics,
               Seen, Entries, Truncated) ->
    case maps:is_key(Directory, Seen) of
        true -> {Files, Diagnostics, Seen, Entries, Truncated};
        false ->
            Seen1 = maps:put(Directory, true, Seen),
            case file:list_dir(Directory) of
                {ok, Names0} ->
                    walk_entries(lists:sort(Names0), Root, Directory, Relative,
                                 Depth, Files, Diagnostics, Seen1, Entries,
                                 Truncated);
                {error, _} ->
                    {Files, [diagnostic(Relative, "resource directory cannot be listed")
                             | Diagnostics], Seen1, Entries + 1, Truncated}
            end
    end.

walk_entries([], _Root, _Directory, _Relative, _Depth, Files, Diagnostics,
             Seen, Entries, Truncated) ->
    {Files, Diagnostics, Seen, Entries, Truncated};
walk_entries(_Names, _Root, _Directory, _Relative, _Depth, Files, Diagnostics,
             Seen, Entries, _Truncated)
  when length(Files) >= ?MAX_RESOURCES; Entries >= ?MAX_RESOURCE_ENTRIES ->
    {Files, Diagnostics, Seen, Entries, true};
walk_entries([Name | Rest], Root, Directory, Relative, Depth, Files,
             Diagnostics, Seen, Entries, Truncated) ->
    Lexical = filename:join(Directory, Name),
    Rel = case Relative of "" -> Name; _ -> filename:join(Relative, Name) end,
    {Files1, Diagnostics1, Seen1, Entries1, Truncated1} = case realpath(Lexical) of
        {ok, Actual} ->
            case within(Actual, Root) of
                false ->
                    {Files, [diagnostic(Rel, "resource symlink escapes skill root")
                             | Diagnostics], Seen, Entries + 1, Truncated};
                true ->
                    case file:read_file_info(Actual) of
                        {ok, #file_info{type = directory}} ->
                            walk_resources(Root, Actual, Rel, Depth + 1, Files,
                                           Diagnostics, Seen, Entries + 1,
                                           Truncated);
                        {ok, #file_info{type = regular, size = Size}}
                          when Size =< ?MAX_RESOURCE_BYTES ->
                            {[unicode:characters_to_binary(Rel) | Files],
                             Diagnostics, Seen, Entries + 1, Truncated};
                        {ok, #file_info{type = regular}} ->
                            {Files,
                             [diagnostic(Rel, "resource exceeds 16777216 bytes")
                              | Diagnostics], Seen, Entries + 1, Truncated};
                        _ ->
                            {Files, Diagnostics, Seen, Entries + 1, Truncated}
                    end
            end;
        {error, _} ->
            {Files,
             [diagnostic(Rel, "resource cannot be resolved") | Diagnostics],
             Seen, Entries + 1, Truncated}
    end,
    walk_entries(Rest, Root, Directory, Relative, Depth, Files1, Diagnostics1,
                 Seen1, Entries1, Truncated1).

read_selected_resource(Root, Relative, Offset, Limit) ->
    case valid_relative(Relative) of
        false -> {error, <<"resource must be a relative path without parent traversal">>};
        true ->
            Lexical = filename:join(Root, Relative),
            case realpath(Lexical) of
                {ok, Actual} ->
                    case within(Actual, Root) of
                        false -> {error, <<"resource path escapes skill root">>};
                        true -> read_file_page(Actual, Offset, Limit)
                    end;
                {error, enoent} -> {error, <<"resource does not exist">>};
                {error, _} -> {error, <<"resource cannot be resolved">>}
            end
    end.

read_file_page(Path, Offset, Limit) ->
    case file:read_file_info(Path) of
        {ok, #file_info{type = regular, size = Size}}
          when Size > ?MAX_RESOURCE_BYTES ->
            {error, <<"resource exceeds 16777216 bytes">>};
        {ok, #file_info{type = regular, size = Size}}
          when Offset > Size ->
            {error, <<"offset exceeds resource size">>};
        {ok, #file_info{type = regular, size = Size}} ->
            case file:open(Path, [read, binary, raw]) of
                {ok, Io} ->
                    Read = file:pread(Io, Offset, Limit),
                    ok = file:close(Io),
                    Chunk = case Read of eof -> <<>>; {ok, Bytes} -> Bytes end,
                    Next = Offset + byte_size(Chunk),
                    Truncated = Next < Size,
                    {Encoding, Content} = encode_chunk(Chunk),
                    {ok, {Encoding, Content, Next, Truncated, Size,
                          unicode:characters_to_binary(Path)}};
                {error, _} -> {error, <<"resource cannot be read">>}
            end;
        {ok, _} -> {error, <<"resource is not a regular file">>};
        {error, _} -> {error, <<"resource cannot be inspected">>}
    end.

encode_chunk(Chunk) ->
    case unicode:characters_to_binary(Chunk, utf8, utf8) of
        Chunk -> {<<"utf-8">>, Chunk};
        _ -> {<<"base64">>, base64:encode(Chunk)}
    end.

valid_relative([]) -> false;
valid_relative(Relative) ->
    filename:pathtype(Relative) =:= relative
        andalso not lists:member(0, Relative)
        andalso lists:all(fun(Component) ->
            Component =/= "" andalso Component =/= "."
                andalso Component =/= ".."
        end, filename:split(Relative)).

realpath(Path0) ->
    resolve_path(filename:absname(Path0), 0).

resolve_path(_Path, Depth) when Depth > 40 -> {error, eloop};
resolve_path(Path, Depth) ->
    [Root | Parts] = filename:split(filename:absname(Path)),
    resolve_parts(Root, Parts, Depth).

resolve_parts(Current, [], Depth) ->
    case file:read_link_info(Current) of
        {ok, #file_info{type = symlink}} -> resolve_link(Current, [], Depth);
        {ok, _} -> {ok, filename:absname(Current)};
        {error, Reason} -> {error, Reason}
    end;
resolve_parts(Current, ["." | Rest], Depth) ->
    resolve_parts(Current, Rest, Depth);
resolve_parts(Current, [".." | Rest], Depth) ->
    resolve_parts(filename:dirname(Current), Rest, Depth);
resolve_parts(Current, [Part | Rest], Depth) ->
    Candidate = filename:join(Current, Part),
    case file:read_link_info(Candidate) of
        {ok, #file_info{type = symlink}} -> resolve_link(Candidate, Rest, Depth);
        {ok, _} -> resolve_parts(Candidate, Rest, Depth);
        {error, Reason} -> {error, Reason}
    end.

resolve_link(Link, Rest, Depth) ->
    case file:read_link(Link) of
        {ok, Target} ->
            Base = case filename:pathtype(Target) of
                absolute -> Target;
                _ -> filename:join(filename:dirname(Link), Target)
            end,
            resolve_path(filename:join([Base | Rest]), Depth + 1);
        {error, Reason} -> {error, Reason}
    end.

within(Path0, Root0) ->
    Path = filename:absname(Path0),
    Root = filename:absname(Root0),
    Path =:= Root orelse lists:prefix(root_prefix(Root), Path).

root_prefix("/") -> "/";
root_prefix(Root) -> Root ++ "/".

strip_cr(<<>>) -> <<>>;
strip_cr(Line) ->
    case binary:last(Line) of
        $\r -> binary:part(Line, 0, byte_size(Line) - 1);
        _ -> Line
    end.

text_list(Value) -> unicode:characters_to_list(Value).

diagnostic(Path, Message) ->
    iolist_to_binary([unicode:characters_to_binary(Path), <<": ">>,
                      unicode:characters_to_binary(Message)]).

limit_diagnostics(Diagnostics) ->
    case length(Diagnostics) =< ?MAX_DIAGNOSTICS of
        true -> Diagnostics;
        false ->
            {Shown, Hidden} = lists:split(?MAX_DIAGNOSTICS - 1, Diagnostics),
            Shown ++ [iolist_to_binary([
                integer_to_binary(length(Hidden)),
                <<" additional skill diagnostics omitted">>])]
    end.
