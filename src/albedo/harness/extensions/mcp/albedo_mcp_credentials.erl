-module(albedo_mcp_credentials).
-include_lib("kernel/include/file.hrl").
-export([server/1, server_at/2]).

-define(MAX_BYTES, 1048576).

%% Secrets never enter extension settings, prompt context or API responses.
%% They live in creds.json's "mcp" section. A missing file means no saved
%% credentials; a permissive file is an error.
server(Name) -> server_at(albedo_extension_settings:home(), Name).

server_at(Home, Name) ->
    Path = albedo_credentials:creds_path(Home),
    case file:read_link_info(Path) of
        {error, enoent} -> {ok, #{}};
        {ok, #file_info{type = regular, size = Size, mode = Mode}}
                when Size =< ?MAX_BYTES, Mode band 8#077 =:= 0 ->
            case albedo_credentials:mcp(Home) of
                {ok, Servers} -> {ok, maps:get(Name, Servers, #{})};
                {error, enoent} -> {ok, #{}};
                {error, _} -> {error, <<"invalid creds.json">>}
            end;
        _ -> {error, <<"creds.json must be a regular 0600 file under ~/.albedo">>}
    end.
