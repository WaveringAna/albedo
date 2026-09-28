%% The table half of albedo/harness/languages: github linguist's
%% languages.yml, shipped in priv/linguist, parsed with yamerl the first time
%% a language is asked for and kept in a persistent term from then on.
-module(albedo_languages).

-export([detect/1, named/1]).

-define(KEY, {?MODULE, table}).

%% A file's language by its exact name, else by its longest known extension,
%% compared lowercased.
detect(FileName) ->
    {Names, Filenames, Extensions} = table(),
    case maps:find(FileName, Filenames) of
        {ok, Name} -> maps:get(Name, Names, none);
        error -> by_extension(string:lowercase(FileName), Names, Extensions)
    end.

named(Name) -> maps:get(Name, element(1, table()), none).

by_extension(Lower, Names, Extensions) ->
    Suffixes = [binary:part(Lower, Start, byte_size(Lower) - Start)
                || {Start, _} <- binary:matches(Lower, <<".">>)],
    case [Name || Suffix <- Suffixes, {ok, Name} <- [maps:find(Suffix, Extensions)]] of
        [Name | _] -> maps:get(Name, Names, none);
        [] -> none
    end.

table() ->
    case persistent_term:get(?KEY, undefined) of
        undefined ->
            %% A table that will not load is not retried for every file.
            Table = case load() of
                {ok, Loaded} -> Loaded;
                error -> {#{}, #{}, #{}}
            end,
            persistent_term:put(?KEY, Table),
            Table;
        Table -> Table
    end.

%% Several languages can claim one extension (`.h` is C, C++ and
%% Objective-C), and linguist settles that with heuristics over the content.
%% Here a fixed ranking settles it instead, the same way every time: a
%% popular language (linguist's popular.yml) whose primary (first-listed)
%% extension it is, then a language named like it (`.yaml` is YAML), then any
%% primary claim, then popular languages, then the language listing more
%% extensions, then file order.
load() ->
    _ = application:ensure_all_started(yamerl),
    Dir = case code:priv_dir(albedo) of
        {error, _} -> "";
        Priv -> filename:join(Priv, "linguist")
    end,
    Options = [{schema, failsafe}, {node_mods, []}],
    try {yamerl_constr:file(filename:join(Dir, "languages.yml"), Options),
         yamerl_constr:file(filename:join(Dir, "popular.yml"), Options)} of
        {[Document], [Popular0]} when is_list(Document), is_list(Popular0) ->
            Popular = [text(Name) || Name <- Popular0],
            Languages = [language(Name, Fields) || {Name, Fields} <- Document, is_list(Fields)],
            Names = maps:from_list([{element(2, L), {some, L}} || {L, _, _} <- Languages]),
            Filenames = claim([{F, element(2, L)} || {L, Fs, _} <- Languages, F <- Fs]),
            Candidates = lists:sort(
                [{E, rank(element(2, L), E, E =:= hd(Es), Popular, length(Es), Index), element(2, L)}
                 || {Index, {L, _, Es}} <- lists:enumerate(Languages), E <- Es]),
            {ok, {Names, Filenames, claim([{E, Name} || {E, _, Name} <- Candidates])}};
        _ -> error
    catch
        _:_ -> error
    end.

%% Smaller ranks first; `false` sorts before `true`.
rank(Name, Extension, Primary, Popular0, Count, Index) ->
    Popular = lists:member(Name, Popular0),
    Named = Extension =:= <<".", (string:lowercase(Name))/binary>>,
    {not (Popular andalso Primary), not Named, not Primary, not Popular, -Count, Index}.

%% First claim wins: from_list keeps the last of a repeated key.
claim(Pairs) -> maps:from_list(lists:reverse(Pairs)).

%% The gleam Language record, with its filenames and lowercased extensions.
language(Name0, Fields) ->
    Name = text(Name0),
    Kind = case proplists:get_value("type", Fields) of
        "programming" -> programming;
        "markup" -> markup;
        "prose" -> prose;
        _ -> data
    end,
    Language = {language, Name, Kind, optional(Fields, "color"), optional(Fields, "group")},
    Filenames = [text(F) || F <- proplists:get_value("filenames", Fields, [])],
    Extensions = [string:lowercase(text(E)) || E <- proplists:get_value("extensions", Fields, [])],
    {Language, Filenames, Extensions}.

optional(Fields, Key) ->
    case proplists:get_value(Key, Fields) of
        undefined -> none;
        Value -> {some, text(Value)}
    end.

text(Chars) -> unicode:characters_to_binary(Chars).
