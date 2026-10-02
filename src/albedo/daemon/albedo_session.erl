-module(albedo_session).
-export([kill/1, now_ms/0, discard/1, collect/0, collect_over/1, decode_submission/1, fingerprint/1]).
kill(Pid) -> exit(Pid,kill), nil.
%% Monotonic: idle time must not move when the wall clock does.
now_ms() -> erlang:monotonic_time(millisecond).
discard(Path) -> file:delete(Path), nil.
collect() -> erlang:garbage_collect(), nil.
%% Collects only when the heap has grown past Words, so a steady stream of small
%% messages never pays for a collection.
collect_over(Words) ->
    case erlang:process_info(self(), total_heap_size) of
        {total_heap_size, Size} when Size > Words -> erlang:garbage_collect(), nil;
        _ -> nil
    end.

decode_submission(Payload) -> binary_to_term(Payload, [safe]).

fingerprint(Value) -> binary:encode_hex(crypto:hash(sha256, term_to_binary(Value))).
