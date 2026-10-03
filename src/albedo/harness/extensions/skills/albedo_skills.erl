-module(albedo_skills).

-include_lib("kernel/include/file.hrl").

-export([home/0, builtin_root/0, catalog/3, discover/3, inputs/3, activate_selected/1, list_selected/1, read_selected/4, xml_escape/1]).

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
catalog(Workspace, Home, Builtin) ->
    try case scan(Workspace, Home, Builtin) of
        {ok, {Candidates, Diagnostics, _Truncated}} ->
            Skills = [selected_metadata(Name, Description, Lexical, Source)
                      || {candidate, _Id, {some, Name}, {some, Description},
                          Lexical, {some, Source}, true, _Diagnostic, true,
                          _Shadowed} <- Candidates],
            {ok, {lists:sort(Skills), Diagnostics, length(Candidates)}};
        Error -> Error
    end catch
        _:_ -> {error, <<"skill catalog changed during discovery; retry loading skills">>}
    end.

%% Detect source changes without parsing YAML or reconstructing candidate rows.
%% Hash contents as well as identity to detect same-length in-place edits.
inputs(Workspace, Home, Builtin) ->
    Roots = roots(text_list(Workspace), text_list(Home))
        ++ builtin_roots(text_list(Builtin)),
    {Sources, _Count} = input_roots(Roots, [], 0),
    Sources.

input_roots([], Sources, Count) -> {lists:reverse(Sources), Count};
input_roots([Root | Rest], Sources, Count) when Count >= ?MAX_SKILLS ->
    input_roots(Rest, [{Root, limited} | Sources], Count);
input_roots([Root | Rest], Sources, Count) ->
    case root_entries(Root) of
        {ok, Lexical, Entries} ->
            {Next, Number} = input_entries(Entries, Lexical, Sources, Count),
            input_roots(Rest, Next, Number);
        Other -> input_roots(Rest, [{Root, Other} | Sources], Count)
    end.

input_entries([], _Root, Sources, Count) -> {Sources, Count};
input_entries(_Entries, Root, Sources, Count) when Count >= ?MAX_SKILLS ->
    {[{Root, limited} | Sources], Count};
input_entries([Entry | Rest], Root, Sources, Count) ->
    Path = filename:join(Root, Entry),
    case file:read_link_info(Path) of
        {ok, #file_info{type = Type}} when Type =:= directory; Type =:= symlink ->
            case file:read_file_info(Path) of
                {ok, #file_info{type = directory}} ->
                    Fingerprint = bounded_fingerprint(filename:join(Path, "SKILL.md")),
                    input_entries(Rest, Root, [{Path, Fingerprint} | Sources], Count + 1);
                {ok, _} -> input_entries(Rest, Root, Sources, Count);
                Error -> input_entries(Rest, Root, [{Path, Error} | Sources], Count + 1)
            end;
        {ok, _} -> input_entries(Rest, Root, Sources, Count);
        Error -> input_entries(Rest, Root, [{Path, Error} | Sources], Count + 1)
    end.

discover(Workspace, Home, Builtin) ->
    case scan(Workspace, Home, Builtin) of
        {ok, {Candidates, Diagnostics, Limited}} ->
            Fingerprints = [bounded_fingerprint(text_list(Source))
                            || {candidate, _Id, _Name, _Description, Source,
                                _Resolved, _Valid, _Diagnostic, _Eligible,
                                _Shadowed} <- Candidates],
            Fingerprint = binary:encode_hex(crypto:hash(sha256,
                term_to_binary({Candidates, Diagnostics, Limited, Fingerprints}))),
            {ok, {Candidates, Diagnostics, Limited, Fingerprint}};
        Error -> Error
    end.

scan(Workspace0, Home0, Builtin0) ->
    try
        Roots = roots(text_list(Workspace0), text_list(Home0)),
        {Selected0, Diagnostics0, Count0, Limited0} =
            scan_roots(Roots, {#{}, []}, [], 0, false),
        {Builtin, Diagnostics2, _Count, Limited} =
            scan_roots(builtin_roots(text_list(Builtin0)), {#{}, []},
                       Diagnostics0, Count0, Limited0),
        {WorkspaceSelected, WorkspaceCandidates} = Selected0,
        {BuiltinSelected, BuiltinCandidates} = Builtin,
        Winners = maps:merge(BuiltinSelected, WorkspaceSelected),
        Candidates0 = unique_candidates(lists:reverse(WorkspaceCandidates)
                      ++ lists:reverse(BuiltinCandidates), #{}),
        Candidates = [with_precedence(Candidate, Winners)
                      || Candidate <- Candidates0],
        Diagnostics1 = [<<"skill discovery limit reached; remaining entries ignored">> || Limited] ++ Diagnostics2,
        Diagnostics = limit_diagnostics(lists:reverse(Diagnostics1)),
        {ok, {Candidates, Diagnostics, Limited}}
    catch
        _:_ -> {error, <<"skill discovery failed">>}
    end.

unique_candidates([], _Seen) -> [];
unique_candidates([{candidate, Id, _Name, _Description, _Source, _Resolved,
                    _Valid, _Diagnostic, _Eligible, _Shadowed} = Candidate | Rest],
                  Seen) ->
    case maps:is_key(Id, Seen) of
        true -> unique_candidates(Rest, Seen);
        false -> [Candidate | unique_candidates(Rest, Seen#{Id => true})]
    end.

with_precedence({candidate, Id, {some, Name}, Description, Source, Resolved,
                 true, Diagnostic, _Eligible, _Shadowed}, Winners) ->
    {WinnerId, _Skill} = maps:get(Name, Winners),
    Shadowed = case Id =:= WinnerId of true -> none; false -> {some, WinnerId} end,
    {candidate, Id, {some, Name}, Description, Source, Resolved,
     true, Diagnostic, Id =:= WinnerId, Shadowed};
with_precedence(Candidate, _Winners) -> Candidate.

selected_metadata(Name, Description, Source, ResolvedSource) ->
    {ok, Directory} = realpath(filename:dirname(text_list(Source))),
    {ok, Identity} = selection_identity(Directory, text_list(ResolvedSource)),
    {Name, Description, Source, unicode:characters_to_binary(Directory),
     ResolvedSource, Identity}.

%% Content edits stay live; replacing either selected filesystem object requires reload.
selection_identity(Directory, Instruction) ->
    case {file:read_file_info(Directory), file:read_file_info(Instruction)} of
        {{ok, DirectoryInfo}, {ok, InstructionInfo}} ->
            Identity = {object_identity(DirectoryInfo), object_identity(InstructionInfo)},
            {ok, binary:encode_hex(crypto:hash(sha256, term_to_binary(Identity)))};
        Error -> {error, Error}
    end.

object_identity(#file_info{inode = Inode, major_device = Major, minor_device = Minor}) ->
    {Inode, Major, Minor}.

bounded_fingerprint(Path) ->
    Directory = realpath(filename:dirname(Path)),
    case realpath(Path) of
        {ok, Actual} ->
            Identity = case Directory of
                {ok, ActualDirectory} -> selection_identity(ActualDirectory, Actual);
                DirectoryError -> DirectoryError
            end,
            {Directory, Actual, Identity,
             albedo_file_fingerprint:fingerprint(Actual, ?MAX_SKILL_BYTES)};
        Error -> {Directory, Error}
    end.

activate_selected(Skill) ->
    try
        case valid_selected_skill(Skill) of
            {ok, {Name, Description, Source, _Directory, Canonical}} ->
                case read_instructions(Canonical) of
                    {ok, Instructions} when byte_size(Instructions) > ?MAX_SKILL_BYTES ->
                        {error, <<"SKILL.md exceeds 1048576 bytes">>};
                    {ok, Instructions} ->
                        case unicode:characters_to_binary(Instructions, utf8, utf8) of
                            Instructions ->
                                {ok, {Name, Description,
                                      Source, Instructions}};
                            _ -> {error, <<"SKILL.md must be UTF-8 text">>}
                        end;
                    {error, _} -> {error, <<"SKILL.md cannot be read">>}
                end;
            Error -> Error
        end
    catch
        _:_ -> {error, <<"skill activation failed">>}
    end.

list_selected(Skill) ->
    try
        case valid_selected_skill(Skill) of
            {ok, {_Name, _Description, _Source, Root, _Canonical}} ->
                {Files0, Diagnostics0, _Seen, _Entries, Truncated} =
                    walk_resources(Root, "", 0, [], [], #{}, 0, false),
                {ok, {lists:sort(Files0), Truncated,
                      limit_diagnostics(lists:reverse(Diagnostics0))}};
            Error -> Error
        end
    catch
        _:_ -> {error, <<"resource listing failed">>}
    end.

read_selected(Skill, Relative0, Offset, Limit)
  when is_integer(Offset), Offset >= 0, is_integer(Limit), Limit >= 1, Limit =< ?MAX_READ_BYTES ->
    try
        case valid_selected_skill(Skill) of
            {ok, {_Name, _Description, _Source, Directory, _Canonical}} ->
                read_selected_resource(Directory,
                                       text_list(Relative0), Offset, Limit);
            Error -> Error
        end
    catch
        _:_ -> {error, <<"resource read failed">>}
    end;
read_selected(_Skill, _Relative0, _Offset, _Limit) ->
    {error, <<"offset must be nonnegative and limit must be 1..65536">>}.

valid_selected_skill({skill, SelectedName, SelectedDescription, Source,
                      Directory, Instruction, SelectedIdentity}) ->
    Selected = text_list(Source),
    case {realpath(filename:dirname(Selected)), realpath(Selected)} of
        {{ok, ActualDirectory}, {ok, Canonical}} ->
            case {unicode:characters_to_binary(ActualDirectory),
                  unicode:characters_to_binary(Canonical),
                  selection_identity(ActualDirectory, Canonical)} of
                {Directory, Instruction, {ok, SelectedIdentity}} ->
                    case file:read_file_info(Canonical) of
                        {ok, #file_info{type = regular, size = Size}}
                          when Size > ?MAX_SKILL_BYTES ->
                            {error, <<"SKILL.md exceeds 1048576 bytes">>};
                        {ok, #file_info{type = regular}} ->
                            case frontmatter(Canonical) of
                                {ok, SelectedName, SelectedDescription} ->
                                    {ok, {SelectedName, SelectedDescription, Source,
                                          ActualDirectory, Canonical}};
                                {ok, _Name, _Description} ->
                                    {error, <<"SKILL.md metadata changed since this session opened; reload the skills extension">>};
                                {error, Message} ->
                                    {error, unicode:characters_to_binary(Message)}
                            end;
                        _ -> {error, <<"selected SKILL.md is unavailable">>}
                    end;
                _ -> {error, <<"selected skill identity changed; reload the skills extension">>}
            end;
        _ -> {error, <<"selected skill is unavailable; reload the skills extension">>}
    end.

read_instructions(Path) ->
    case file:open(Path, [read, binary, raw]) of
        {ok, Io} ->
            try
                case file:pread(Io, 0, ?MAX_SKILL_BYTES + 1) of
                    eof -> {ok, <<>>};
                    Read -> Read
                end
            after file:close(Io) end;
        Error -> Error
    end.

%% An empty workspace has no project skills here: it is on another host.
roots(Workspace, Home) ->
    Project = case Workspace of
        [] -> [];
        _ -> [filename:join([Workspace, ".albedo", "skills"]),
              filename:join([Workspace, ".agents", "skills"])]
    end,
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
                {ok, Entries} -> {ok, filename:absname(Root0), lists:sort(Entries)};
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
scan_entries([Entry | Rest], Root, {Selected, Candidates} = State,
             Diagnostics, Count, Limited) ->
    CandidatePath = filename:join(Root, Entry),
    Source = unicode:characters_to_binary(filename:join(CandidatePath, "SKILL.md")),
    Id = <<"skills:", Source/binary>>,
    case candidate(CandidatePath, Entry) of
        skip ->
            scan_entries(Rest, Root, State, Diagnostics, Count, Limited);
        {error, Message} ->
            Candidate = {candidate, Id, none, none, Source, none, false,
                         {some, unicode:characters_to_binary(Message)}, false, none},
            scan_entries(Rest, Root, {Selected, [Candidate | Candidates]},
                         [diagnostic(CandidatePath, Message) | Diagnostics],
                         Count + 1, Limited);
        {ok, {Name, Description, SkillFile} = Skill} ->
            Candidate = {candidate, Id, {some, Name}, {some, Description}, Source,
                         {some, SkillFile}, true, none, false, none},
            {Selected1, Diagnostics1} = case maps:find(Name, Selected) of
                error ->
                    {maps:put(Name, {Id, Skill}, Selected), Diagnostics};
                {ok, {_WinnerId, {_OldName, _OldDescription, Winner}}} ->
                    Message = iolist_to_binary([
                        <<"duplicate skill ">>, Name, <<" ignored; using ">>, Winner]),
                    {Selected, [diagnostic(SkillFile, Message) | Diagnostics]}
            end,
            scan_entries(Rest, Root, {Selected1, [Candidate | Candidates]},
                         Diagnostics1, Count + 1, Limited)
    end.

candidate(Candidate, Entry) ->
    case file:read_link_info(Candidate) of
        {ok, #file_info{type = Type}} when Type =:= directory; Type =:= symlink ->
            case realpath(Candidate) of
                {ok, Directory} ->
                    case file:read_file_info(Directory) of
                        {ok, #file_info{type = directory}} ->
                            parse_skill(filename:join(Directory, "SKILL.md"), Entry);
                        _ -> skip
                    end;
                {error, _} -> {error, "skill directory cannot be resolved"}
            end;
        {ok, _} -> skip;
        {error, _} -> {error, "cannot be inspected"}
    end.

parse_skill(Skill0, Entry) ->
    case realpath(Skill0) of
        {ok, SkillFile} ->
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

walk_resources(_Directory, _Relative, _Depth, Files, Diagnostics,
               Seen, Entries, _Truncated)
  when length(Files) >= ?MAX_RESOURCES; Entries >= ?MAX_RESOURCE_ENTRIES ->
    {Files, Diagnostics, Seen, Entries, true};
walk_resources(_Directory, _Relative, Depth, Files, Diagnostics,
               Seen, Entries, _Truncated)
  when Depth > ?MAX_RESOURCE_DEPTH ->
    {Files, [<<"resource depth limit reached">> | Diagnostics], Seen,
     Entries, true};
walk_resources(Directory, Relative, Depth, Files, Diagnostics,
               Seen, Entries, Truncated) ->
    case maps:is_key(Directory, Seen) of
        true ->
            {Files, [diagnostic(Relative, "resource directory cycle skipped")
                     | Diagnostics], Seen, Entries, Truncated};
        false ->
            Seen1 = maps:put(Directory, true, Seen),
            case file:list_dir(Directory) of
                {ok, Names0} ->
                    {Files1, Diagnostics1, _Seen, Entries1, Truncated1} =
                        walk_entries(lists:sort(Names0), Directory, Relative,
                                     Depth, Files, Diagnostics, Seen1, Entries,
                                     Truncated),
                    {Files1, Diagnostics1, Seen, Entries1, Truncated1};
                {error, _} ->
                    {Files, [diagnostic(Relative, "resource directory cannot be listed")
                             | Diagnostics], Seen, Entries + 1, Truncated}
            end
    end.

walk_entries([], _Directory, _Relative, _Depth, Files, Diagnostics,
             Seen, Entries, Truncated) ->
    {Files, Diagnostics, Seen, Entries, Truncated};
walk_entries(_Names, _Directory, _Relative, _Depth, Files, Diagnostics,
             Seen, Entries, _Truncated)
  when length(Files) >= ?MAX_RESOURCES; Entries >= ?MAX_RESOURCE_ENTRIES ->
    {Files, Diagnostics, Seen, Entries, true};
walk_entries([Name | Rest], Directory, Relative, Depth, Files,
             Diagnostics, Seen, Entries, Truncated) ->
    Lexical = filename:join(Directory, Name),
    Rel = case Relative of "" -> Name; _ -> filename:join(Relative, Name) end,
    {Files1, Diagnostics1, Seen1, Entries1, Truncated1} = case realpath(Lexical) of
        {ok, Actual} ->
            case file:read_file_info(Actual) of
                {ok, #file_info{type = directory}} ->
                    walk_resources(Actual, Rel, Depth + 1, Files,
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
            end;
        {error, _} ->
            {Files,
             [diagnostic(Rel, "resource cannot be resolved") | Diagnostics],
             Seen, Entries + 1, Truncated}
    end,
    walk_entries(Rest, Directory, Relative, Depth, Files1, Diagnostics1,
                 Seen1, Entries1, Truncated1).

read_selected_resource(Root, Relative, Offset, Limit) ->
    case valid_relative(Relative) of
        false -> {error, <<"resource must be a relative path without parent traversal">>};
        true ->
            Lexical = filename:join(Root, Relative),
            case realpath(Lexical) of
                {ok, Actual} ->
                    read_file_page(Actual, Offset, Limit);
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
