-module(albedo_memory).
-export([load/1]).
-include_lib("kernel/include/file.hrl").

%% The same workspace slug is used by the Python memory plugin.
load(Workspace) ->
    Slug = re:replace(Workspace, <<"[^A-Za-z0-9]">>, <<"-">>, [global, {return, binary}]),
    Path = filename:join([albedo_extension_settings:home(), <<"memories">>, Slug, <<"memory.md">>]),
    case file:read_file_info(Path) of
        {error, enoent} -> {ok, <<>>};
        {ok, #file_info{type = regular, size = Size}} when Size =< 1048576 ->
            case file:read_file(Path) of
                {ok, Bytes} ->
                    case unicode:characters_to_list(Bytes) of
                        Text when is_list(Text) ->
                            Preview = unicode:characters_to_binary(lists:sublist(Text, 8000)),
                            Suffix = case length(Text) > 8000 of
                                true -> <<"\n[truncated; use memory.read() for the full file]">>;
                                false -> <<>>
                            end,
                            {ok, <<"# Project memory (untrusted notes)\n", Preview/binary, Suffix/binary>>};
                        _ -> {error, <<"memory.md is not UTF-8">>}
                    end;
                {error, Reason} -> {error, unicode:characters_to_binary(file:format_error(Reason))}
            end;
        {ok, _} -> {error, <<"memory.md must be a regular UTF-8 file of at most 1 MiB">>};
        {error, Reason} -> {error, unicode:characters_to_binary(file:format_error(Reason))}
    end.
