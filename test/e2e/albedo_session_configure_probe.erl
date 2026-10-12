%% Invoke the real registered command state seam without booting a kernel.
-module(albedo_session_configure_probe).
-export([model/4, effort/2]).

model(Id, Model, Provider, Effort) ->
    answer(albedo_commands:call(Id, {model_select, Model, optional(Provider), optional(Effort)})).

effort(Id, Level) -> answer(albedo_commands:call(Id, {effort_select, Level})).

optional(null) -> none;
optional(Value) -> {some, Value}.

answer({ok, Value}) ->
    Json = 'gleam@json':to_string(Value),
    json:encode(#{ok => json:decode(Json)});
answer({error, Error}) -> json:encode(#{error => Error}).
