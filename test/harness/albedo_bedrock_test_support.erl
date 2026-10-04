%% Hermetic AWS file/helper fixtures: no network or user credentials.
-module(albedo_bedrock_test_support).
-export([profile_fixtures/0]).

profile_fixtures() ->
    Dir = filename:join("/tmp", "albedo-bedrock-" ++ os:getpid() ++ "-" ++ integer_to_list(erlang:unique_integer([positive]))),
    ok = file:make_dir(Dir),
    Config = filename:join(Dir, "config"),
    Creds = filename:join(Dir, "credentials"),
    Helper = filename:join(Dir, "helper script.py"),
    Settings = filename:join(Dir, "config.json"),
    Vars = [{"AWS_PROFILE", "work"}, {"AWS_CONFIG_FILE", Config},
            {"AWS_SHARED_CREDENTIALS_FILE", Creds}, {"BEDROCK_HELPER_TEST", "custom-value"},
            {"AWS_ACCESS_KEY_ID", ""}, {"AWS_SECRET_ACCESS_KEY", ""},
            {"AWS_SESSION_TOKEN", ""}, {"AWS_BEARER_TOKEN_BEDROCK", ""}],
    Old = [{K, os:getenv(K)} || {K, _} <- Vars],
    try
        [os:putenv(K, V) || {K, V} <- Vars],
        %% Credentials-only named profile; missing config is not a hard gate.
        ok = file:write_file(Creds, <<"[work]\naws_access_key_id = shared\naws_secret_access_key = shared-secret\n">>),
        {ok, {credentials, <<"shared">>, <<"shared-secret">>, none}} = resolve(),
        %% Shared keys outrank config keys; never blend tokens across sources.
        ok = file:write_file(Config, <<"[profile work]\naws_access_key_id = config\naws_secret_access_key = config-secret\naws_session_token = config-token\n">>),
        {ok, {credentials, <<"shared">>, <<"shared-secret">>, none}} = resolve(),
        ok = file:delete(Creds),
        {ok, {credentials, <<"config">>, <<"config-secret">>, {some, <<"config-token">>}}} = resolve(),
        %% Rewrites are read fresh, not cached.
        ok = file:write_file(Config, <<"[profile work]\naws_access_key_id = refreshed\naws_secret_access_key = new-secret\n">>),
        {ok, {credentials, <<"refreshed">>, <<"new-secret">>, none}} = resolve(),
        %% A quoted script path/argument and custom environment survive argv parsing.
        Python = os:find_executable("python3"),
        true = is_list(Python),
        ok = file:write_file(Helper, <<"import os,sys,json\nprint(json.dumps({'AccessKeyId':os.environ['AWS_PROFILE'], 'SecretAccessKey':os.environ['AWS_CONFIG_FILE'], 'SessionToken':os.environ['BEDROCK_HELPER_TEST'] + ':' + sys.argv[1]}))\n">>),
        Command = iolist_to_binary(["\"", Python, "\" \"", Helper, "\" \"team account\""]),
        ok = file:write_file(Config, ["[profile work]\ncredential_process = ", Command, "\n"]),
        {ok, {credentials, <<"work">>, ConfigBin, {some, <<"custom-value:team account">>}}} = resolve(),
        ConfigBin = unicode:characters_to_binary(Config),
        %% Existing usage-feed API still strips AWS/custom vars.
        {0, <<"filtered\n">>} = albedo_usage_core:run_command(
            unicode:characters_to_binary(Python),
            [<<"-c">>, <<"import os; print('filtered' if 'AWS_PROFILE' not in os.environ and 'BEDROCK_HELPER_TEST' not in os.environ else 'leaked')">>], none, {some, 15000}),
        %% Failed stdout may contain credentials: never display it.
        ok = file:write_file(Helper, <<"import sys\nprint('sensitive-secret')\nsys.exit(2)\n">>),
        {error, <<"credential_process exited 2">>} = resolve(),
        %% Default credentials-only profile also works.
        os:putenv("AWS_PROFILE", ""),
        ok = file:delete(Config),
        ok = file:write_file(Creds, <<"[default]\naws_access_key_id = default-key\naws_secret_access_key = default-secret\n">>),
        {ok, {credentials, <<"default-key">>, <<"default-secret">>, none}} = resolve(),
        %% One resolved upstream must authenticate anew on each model step.
        ok = file:write_file(Settings, <<"{\"providers\":{\"bedrock\":{\"baseUrl\":\"https://bedrock-runtime.us-east-1.amazonaws.com\"}}}">>),
        nil = 'harness@bedrock_test':reused_upstream_refreshes(unicode:characters_to_binary(Dir), fun() ->
            ok = file:delete(Creds), nil
        end),
        %% A partial source fails without borrowing its secret from config.
        os:putenv("AWS_PROFILE", "work"),
        ok = file:write_file(Creds, <<"[work]\naws_access_key_id = partial\n">>),
        ok = file:write_file(Config, <<"[profile work]\naws_secret_access_key = other-secret\n">>),
        {error, <<"profile work has no aws_secret_access_key">>} = resolve(),
        true
    after
        [case V of false -> os:unsetenv(K); _ -> os:putenv(K, V) end || {K, V} <- Old],
        [file:delete(P) || P <- [Config, Creds, Helper, Settings]],
        file:del_dir(Dir)
    end.

resolve() -> 'albedo@harness@extensions@bedrock@aws_profile':resolve().
