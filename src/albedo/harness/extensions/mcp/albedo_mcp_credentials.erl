-module(albedo_mcp_credentials).
-include_lib("kernel/include/file.hrl").
-export([server/1, server_at/2]).

-define(MAX_BYTES, 1048576).

%% Secrets never enter extension settings, prompt context or API responses.
%% A missing file means no saved credentials; a permissive file is an error.
server(Name) -> server_at(albedo_extension_settings:home(), Name).

server_at(Home, Name) ->
    Path = filename:join(Home, <<"mcp-credentials.json">>),
    case file:read_link_info(Path) of
        {error, enoent} -> {ok, #{}};
        {ok, #file_info{type = regular, size = Size, mode = Mode}}
                when Size =< ?MAX_BYTES, Mode band 8#077 =:= 0 ->
            case file:read_file(Path) of
                {ok, Bytes} when byte_size(Bytes) =< ?MAX_BYTES ->
                    try
                        Document = json:decode(Bytes),
                        Servers = maps:get(<<"servers">>, Document, #{}),
                        Secret = maps:get(Name, Servers, #{}),
                        true = is_map(Secret),
                        {ok, Secret}
                    catch _:_ -> {error, <<"invalid mcp-credentials.json">>} end;
                _ -> {error, <<"could not read mcp-credentials.json">>}
            end;
        _ -> {error, <<"mcp-credentials.json must be a regular 0600 file under ~/.albedo">>}
    end.
