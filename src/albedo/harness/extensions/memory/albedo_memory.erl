%% Project memory on the daemon's disk: one directory per workspace under
%% $ALBEDO_HOME/memories, `memory.md` plus `journal/<date>.md`. The kernel
%% reaches it through the memory host route wherever the kernel runs, so a
%% remote session's memory lives here too. Writes to one workspace are
%% serialized through a global lock; reads span a workspace's link group.
-module(albedo_memory).
-export([load/1, linked/1, read/1, save/2, append/2, journal/3, documents/1]).
-include_lib("kernel/include/file.hrl").

-define(MAX_FILE, 1048576).
-define(PREVIEW, 8000).        %% characters of the snapshot a session opens with
-define(DOCUMENTS, 16777216).  %% bytes one documents answer carries

root(Workspace) ->
    Slug = re:replace(Workspace, <<"[^A-Za-z0-9]">>, <<"-">>, [global, unicode, {return, binary}]),
    filename:join([albedo_extension_settings:home(), <<"memories">>, Slug]).

memory(Workspace) -> filename:join(root(Workspace), <<"memory.md">>).

%% The snapshot a session opens with: its own memory, then each linked
%% workspace's under a heading naming it, within one character budget.
load([Own | Linked]) ->
    case text(memory(Own)) of
        {error, Reason} -> {error, Reason};
        {ok, Mine} ->
            Parts = [{none, Mine} | [{W, T} || W <- Linked, {ok, T} <- [text(memory(W))], T =/= <<>>]],
            case [P || {_, T} = P <- Parts, T =/= <<>>] of
                [] -> {ok, <<>>};
                _ -> {ok, iolist_to_binary([<<"# Project memory (untrusted notes)\n">> | snapshot(Parts, ?PREVIEW)])}
            end
    end.

%% The snapshot sections of workspaces that just joined a session's group:
%% the text its next snapshot holds for them, for the note that tells it.
linked(Workspaces) ->
    Parts = [{W, T} || W <- Workspaces, {ok, T} <- [text(memory(W))], T =/= <<>>],
    iolist_to_binary(snapshot(Parts, ?PREVIEW)).

snapshot([], _) -> [];
snapshot([{Where, Text} | Rest], Budget) ->
    Heading = case Where of
        none -> <<>>;
        _ -> [<<"\n## linked workspace ">>, Where, <<"\n">>]
    end,
    Chars = string:length(Text),
    Shown = string:slice(Text, 0, max(0, Budget)),
    Cut = case Chars > Budget of
        true -> <<"\n[truncated; use memory.read() for the full file]">>;
        false -> <<>>
    end,
    [Heading, Shown, Cut | snapshot(Rest, Budget - min(Chars, Budget))].

%% One file as UTF-8 text, empty when it does not exist.
text(Path) ->
    case file:read_file_info(Path) of
        {error, enoent} -> {ok, <<>>};
        {ok, #file_info{type = regular, size = Size}} when Size =< ?MAX_FILE ->
            case file:read_file(Path) of
                {ok, Bytes} ->
                    case unicode:characters_to_binary(Bytes) of
                        Text when is_binary(Text) -> {ok, Text};
                        _ -> {error, <<(filename:basename(Path))/binary, " is not UTF-8">>}
                    end;
                {error, Reason} -> {error, reason(Reason)}
            end;
        {ok, _} -> {error, <<(filename:basename(Path))/binary, " must be a regular UTF-8 file of at most 1 MiB">>};
        {error, Reason} -> {error, reason(Reason)}
    end.

read(Workspace) -> text(memory(Workspace)).

%% Replace the curated memory atomically.
save(_, Text) when byte_size(Text) > ?MAX_FILE -> {error, <<"memory.md cannot exceed 1 MiB">>};
save(Workspace, Text) ->
    Path = memory(Workspace),
    locked(Workspace, fun() ->
        Temp = <<Path/binary, ".", (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
        case file:write_file(Temp, Text) of
            ok ->
                case file:rename(Temp, Path) of
                    ok -> {ok, Path};
                    {error, Reason} -> _ = file:delete(Temp), {error, reason(Reason)}
                end;
            {error, Reason} -> _ = file:delete(Temp), {error, reason(Reason)}
        end
    end).

append(Workspace, Text) ->
    Path = memory(Workspace),
    locked(Workspace, fun() ->
        Size = case file:read_file_info(Path) of {ok, #file_info{size = S}} -> S; _ -> 0 end,
        Entry = entry(Size, Text),
        case Size + byte_size(Entry) > ?MAX_FILE of
            true -> {error, <<"memory.md cannot exceed 1 MiB">>};
            false -> write(Path, Entry)
        end
    end).

journal(Workspace, Date, Text) ->
    case re:run(Date, <<"^[0-9]{4}-[0-9]{2}-[0-9]{2}$">>, [{capture, none}]) of
        nomatch -> {error, <<"journal date must be YYYY-MM-DD">>};
        match ->
            Path = filename:join([root(Workspace), <<"journal">>, <<Date/binary, ".md">>]),
            locked(Workspace, fun() ->
                Size = case file:read_file_info(Path) of {ok, #file_info{size = S}} -> S; _ -> 0 end,
                write(Path, entry(Size, Text))
            end)
    end.

%% A note on its own line, a blank line from the one before it.
entry(Size, Text) ->
    Body = string:trim(Text, trailing, "\n"),
    Gap = case Size > 0 of true -> <<"\n">>; false -> <<>> end,
    iolist_to_binary([Gap, Body, <<"\n">>]).

write(Path, Entry) ->
    case file:write_file(Path, Entry, [append]) of
        ok -> {ok, Path};
        {error, Reason} -> {error, reason(Reason)}
    end.

locked(Workspace, Fun) ->
    case filelib:ensure_path(filename:join(root(Workspace), <<"journal">>)) of
        ok -> global:trans({{?MODULE, root(Workspace)}, self()}, Fun);
        {error, Reason} -> {error, reason(Reason)}
    end.

%% Every memory and journal file of the given workspaces, for grep and
%% search: [{Workspace, Relative, Text}] and whether the byte budget cut the
%% list short. Unreadable files are left out.
documents(Workspaces) -> documents(Workspaces, ?DOCUMENTS, []).

documents([], _, Acc) -> {lists:reverse(Acc), false};
documents([Workspace | Rest], Budget, Acc) ->
    Root = root(Workspace),
    Journals = lists:sort(filelib:wildcard("journal/*.md", binary_to_list(Root))),
    Files = [<<"memory.md">> | [unicode:characters_to_binary(J) || J <- Journals]],
    case collect(Workspace, Root, Files, Budget, Acc) of
        {full, Acc1} -> {lists:reverse(Acc1), true};
        {Left, Acc1} -> documents(Rest, Left, Acc1)
    end.

collect(_, _, [], Budget, Acc) -> {Budget, Acc};
collect(Workspace, Root, [Relative | Rest], Budget, Acc) ->
    case text(filename:join(Root, Relative)) of
        {ok, <<>>} -> collect(Workspace, Root, Rest, Budget, Acc);
        {ok, Text} when byte_size(Text) > Budget -> {full, Acc};
        {ok, Text} -> collect(Workspace, Root, Rest, Budget - byte_size(Text), [{Workspace, Relative, Text} | Acc]);
        {error, _} -> collect(Workspace, Root, Rest, Budget, Acc)
    end.

reason(Reason) -> unicode:characters_to_binary(file:format_error(Reason)).
