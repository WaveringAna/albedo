-module(albedo_session_catalog).
-export([fingerprint/1, inputs/4, saved/1]).

fingerprint(Value) -> binary:encode_hex(crypto:hash(sha256, Value), lowercase).

%% This private owner key retains exact relevant inputs, never an age or mtime.
%% Secret contents participate in the key but never in public wire revisions.
inputs(Home, Workspace, SourcesHome, Builtin) ->
    try
        Saved = saved_documents(Home),
        Files = {albedo_skills:inputs(Workspace, SourcesHome, Builtin),
                 albedo_instruction_files:inputs(Workspace, SourcesHome)},
        Extensions = proplists:get_value(<<"extensions.json">>, Saved),
        Caps = proplists:get_value(<<"capabilities.json">>, Saved),
        Creds = proplists:get_value(<<"creds.json">>, Saved),
        %% Effective extension names are captured separately by preparation.
        %% Provider credentials and unrelated defaults are not loaded plugins.
        Basis = {Files, maps:get(<<"mcp">>, Extensions, #{}),
                 maps:get(<<"global">>, Caps, #{}), maps:get(<<"mcp">>, Creds, #{})},
        {ok, {fingerprint(term_to_binary({Saved, Files})),
              fingerprint(term_to_binary(Basis))}}
    catch
        _:_ -> {error, <<"composition inputs are unavailable">>}
    end.

%% The saved settings alone, without walking skill or instruction files.
saved(Home) ->
    try
        {ok, fingerprint(term_to_binary(saved_documents(Home)))}
    catch
        _:_ -> {error, <<"composition inputs are unavailable">>}
    end.

saved_documents(Home) ->
    albedo_settings_store:with_lock(Home, fun() ->
        [{Name, albedo_settings_store:read(Home, Name)} || Name <-
            [<<"extensions.json">>, <<"capabilities.json">>, <<"creds.json">>,
             <<"settings-revisions.json">>]]
    end).
