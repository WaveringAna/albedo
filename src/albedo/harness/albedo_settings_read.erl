-module(albedo_settings_read).
-export([mcp_definitions/1, composition_revision/1, json_null/0]).
-import(albedo_settings_store, [with_lock/2, guarded/1, object/2]).

json_null() -> null.

mcp_definitions(Home) -> with_lock(Home, fun() -> guarded(fun() ->
    Ext = albedo_settings_store:read(Home, <<"extensions.json">>),
    Servers = object(<<"servers">>, object(<<"mcp">>, Ext)),
    {ok, lists:sort([{Name, maps:get(<<"enabled">>, Definition, true)} || {Name, Definition} <- maps:to_list(Servers)])}
end) end).

%% Only redacted projections and revision counters reach this public hash.
%% Write-only credentials never contribute their bytes or hashes.
composition_revision(Home) -> with_lock(Home, fun() -> guarded(fun() ->
    Documents = maps:from_list([{File, albedo_settings_store:read(Home, File)} || File <-
        [<<"extensions.json">>, <<"capabilities.json">>, <<"creds.json">>]]),
    {ok, Groups} = 'albedo@harness@settings@projection':composition_groups(Documents),
    Revisions = albedo_settings_store:read(Home, <<"settings-revisions.json">>),
    Selected = [{Name, maps:get(Name, Groups), maps:get(Name, Revisions, 0)} ||
        Name <- [<<"extensions">>, <<"mcp">>, <<"capabilities">>]],
    {ok, binary:encode_hex(crypto:hash(sha256, term_to_binary(Selected)), lowercase)}
end) end).
