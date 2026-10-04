-module(albedo_active_output_probe).
-export([stats/1, expire/2, sweep/1]).

stats(Id) ->
    {some, Subject} = 'albedo@daemon@session':live(Id),
    {ok, Owner} = 'gleam@erlang@process':subject_owner(Subject),
    erlang:garbage_collect(Owner),
    Info = process_info(Owner, [memory, binary, reductions, message_queue_len]),
    Binaries = maps:from_list([{Ref, Size} || {Ref, Size, _} <- proplists:get_value(binary, Info)]),
    json:encode(#{actor_heap_bytes => proplists:get_value(memory, Info),
        actor_binary_bytes => lists:sum(maps:values(Binaries)),
        actor_reductions => proplists:get_value(reductions, Info),
        mailbox => proplists:get_value(message_queue_len, Info)}).

expire(Home, Id) ->
    Path = filename:join([Home, <<"active-output">>, <<Id/binary, ".meta">>]),
    {ok, Binary} = file:read_file(Path),
    Meta = binary_to_term(Binary),
    ok = file:write_file(Path, term_to_binary(Meta#{expires => 0})),
    <<"true">>.

sweep(Home) ->
    albedo_active_output:maintenance(Home),
    <<"true">>.
