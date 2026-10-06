%% What a spawn or send copies: the heap words of a process whose closure
%% holds Term. A term read from a persistent term is a literal and costs none.
-module(albedo_copy_test_support).

-export([captured_words/1]).

captured_words(Term) ->
    Self = self(),
    Pid = spawn(fun() -> Self ! {ready, self()}, receive go -> Term end end),
    receive {ready, Pid} -> ok end,
    {total_heap_size, Words} = process_info(Pid, total_heap_size),
    Pid ! go,
    Words.
