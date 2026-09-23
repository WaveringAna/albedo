# Source ledger

Research date: **2026-09-22**. Read selected source paths in **16 repositories**, covering **36 distinct implementation/example/test files**, plus official language/runtime documentation. A file listed with ranges was read in those ranges, not in full. Five test files were inspected; none were executed.

Use [repository studies](repository-studies.md) for interpretation, and [the machine-readable ledger](source-ledger.json) for exact reading scopes and hashes.

## Version and evidence rules

Branch URLs may move. The recorded Git blob SHA identifies the observed file content; it is **not** a commit SHA. Each entry includes an immutable GitHub blob API reference. Commit-pinned URLs are used where that commit was explicitly fetched. Do not assume these independent repositories resolve the same library versions.

Separate observations from recommendations. These are selected design precedents, not a security audit, benchmark, endorsement of every line, or claim that all repository code was read. The environment had no Gleam compiler or Erlang runtime: neither upstream tests nor the bundled original Gleam example were run.

## Repository index

- **gleam-lang/packages**: [S01](#s01), [S02](#s02), [S03](#s03), [S04](#s04), [S05](#s05)
- **lpil/cell**: [S06](#s06), [S07](#s07), [S08](#s08)
- **gleam-lang/otp**: [S09](#s09), [S10](#s10), [S11](#s11)
- **gleam-lang/erlang**: [S12](#s12)
- **rawhat/glisten**: [S13](#s13), [S14](#s14)
- **gleam-wisp/wisp**: [S15](#s15), [S16](#s16)
- **rawhat/mist**: [S17](#s17), [S18](#s18)
- **lpil/pog**: [S19](#s19), [S36](#s36)
- **lpil/sqlight**: [S20](#s20)
- **lustre-labs/lustre**: [S21](#s21), [S22](#s22), [S23](#s23)
- **ghivert/gloogle**: [S24](#s24), [S25](#s25), [S26](#s26), [S27](#s27)
- **gleam-lang/http**: [S28](#s28), [S35](#s35)
- **gleam-lang/stdlib**: [S29](#s29), [S30](#s30)
- **gleam-lang/json**: [S31](#s31)
- **giacomocavalieri/squirrel**: [S32](#s32), [S33](#s33)
- **giacomocavalieri/birdie**: [S34](#s34)

## Exact code reads

<a id="s01"></a>
### S01 - gleam-lang/packages

[src/packages.gleam](https://github.com/gleam-lang/packages/blob/main/src/packages.gleam)

Read: whole file. Focus: Composition, captured context, index and periodic-worker startup.

Ref: `main`. Git blob: `5e503e854bf4cd419259b75ba66c819b82d7241e` ([exact blob](https://api.github.com/repos/gleam-lang/packages/git/blobs/5e503e854bf4cd419259b75ba66c819b82d7241e)).

<a id="s02"></a>
### S02 - gleam-lang/packages

[src/packages/text_search.gleam](https://github.com/gleam-lang/packages/blob/main/src/packages/text_search.gleam)

Read: whole file via raw source; header and metadata rechecked. Focus: Opaque index, direct reads, ordinary search logic, multi-operation updates.

Ref: `main`. Git blob: `897fa795428d6e8562a5491cd9752420e11f9c8f` ([exact blob](https://api.github.com/repos/gleam-lang/packages/git/blobs/897fa795428d6e8562a5491cd9752420e11f9c8f)).

<a id="s03"></a>
### S03 - gleam-lang/packages

[src/packages/storage.gleam](https://github.com/gleam-lang/packages/blob/main/src/packages/storage.gleam)

Read: partial implementation excerpt; tool response truncated; metadata rechecked. Focus: Typed collections, domain operations, codecs, search outcomes.

Ref: `main`. Git blob: `99ea69b143fbf233bdf141a502ee843f1d1cdbcc` ([exact blob](https://api.github.com/repos/gleam-lang/packages/git/blobs/99ea69b143fbf233bdf141a502ee843f1d1cdbcc)).

<a id="s04"></a>
### S04 - gleam-lang/packages

[src/packages/periodic.gleam](https://github.com/gleam-lang/packages/blob/main/src/packages/periodic.gleam)

Read: whole file. Focus: Callback-driven actor and schedule-after-completion.

Ref: `main`. Git blob: `ca5c5c7ebaa7f8a814bb16be33bcc97b98a60c4f` ([exact blob](https://api.github.com/repos/gleam-lang/packages/git/blobs/ca5c5c7ebaa7f8a814bb16be33bcc97b98a60c4f)).

<a id="s05"></a>
### S05 - gleam-lang/packages

[src/ethos_ffi.erl](https://github.com/gleam-lang/packages/blob/main/src/ethos_ffi.erl)

Read: whole file. Focus: Public ETS bag implementation beneath typed index.

Ref: `main`. Git blob: `57999df8706dcc0fa0715e81e18af07fa5417c08` ([exact blob](https://api.github.com/repos/gleam-lang/packages/git/blobs/57999df8706dcc0fa0715e81e18af07fa5417c08)).

<a id="s06"></a>
### S06 - lpil/cell

[src/cell.gleam](https://github.com/lpil/cell/blob/main/src/cell.gleam)

Read: whole file. Focus: Generic opaque cells, empty values and table lifetime.

Ref: `main`. Git blob: `c650ce4c8a657dad169b15a89b87fc0ec0a19e72` ([exact blob](https://api.github.com/repos/lpil/cell/git/blobs/c650ce4c8a657dad169b15a89b87fc0ec0a19e72)).

<a id="s07"></a>
### S07 - lpil/cell

[src/cell_ffi.erl](https://github.com/lpil/cell/blob/main/src/cell_ffi.erl)

Read: whole file. Focus: Public ETS set, error conversion, individual operations.

Ref: `main`. Git blob: `e5fa057cce532c92dbc42b97174843576274189e` ([exact blob](https://api.github.com/repos/lpil/cell/git/blobs/e5fa057cce532c92dbc42b97174843576274189e)).

<a id="s08"></a>
### S08 - lpil/cell

[test/cell_test.gleam](https://github.com/lpil/cell/blob/main/test/cell_test.gleam)

Read: whole file. Focus: Sequential create/read/write/delete/drop behavior.

Ref: `main`. Git blob: `4b60954c28c464946ccd55ce6243a8109173b9cc` ([exact blob](https://api.github.com/repos/lpil/cell/git/blobs/4b60954c28c464946ccd55ce6243a8109173b9cc)).

<a id="s09"></a>
### S09 - gleam-lang/otp

[src/gleam/otp/actor.gleam](https://github.com/gleam-lang/otp/blob/main/src/gleam/otp/actor.gleam)

Read: lines 1-560. Focus: Started data vs PID, custom initialization, Next, selectors, runtime loop.

Ref: `main`. Git blob: `950b153570d544c0e89cc6577b5d68c81ab8b47c` ([exact blob](https://api.github.com/repos/gleam-lang/otp/git/blobs/950b153570d544c0e89cc6577b5d68c81ab8b47c)).

<a id="s10"></a>
### S10 - gleam-lang/otp

[test/gleam/otp/actor_test.gleam](https://github.com/gleam-lang/otp/blob/3702798d922763a3cd2bb73094236995d41f69ca/test/gleam/otp/actor_test.gleam)

Read: lines 1-240. Focus: Initialization failure/timeouts, system messages, selector replacement.

Ref: `3702798d922763a3cd2bb73094236995d41f69ca`. Git blob: `4f7ebb48a10921cac4515577475d4a2b83a95df5` ([exact blob](https://api.github.com/repos/gleam-lang/otp/git/blobs/4f7ebb48a10921cac4515577475d4a2b83a95df5)).

<a id="s11"></a>
### S11 - gleam-lang/otp

[test/gleam/otp/static_supervisor_test.gleam](https://github.com/gleam-lang/otp/blob/3702798d922763a3cd2bb73094236995d41f69ca/test/gleam/otp/static_supervisor_test.gleam)

Read: whole file. Focus: Actual OneForOne, RestForOne, OneForAll restart assertions.

Ref: `3702798d922763a3cd2bb73094236995d41f69ca`. Git blob: `efc8ddfbc984a24f2121e8a1f2ecc71b6eeedc51` ([exact blob](https://api.github.com/repos/gleam-lang/otp/git/blobs/efc8ddfbc984a24f2121e8a1f2ecc71b6eeedc51)).

<a id="s12"></a>
### S12 - gleam-lang/erlang

[src/gleam/erlang/process.gleam](https://github.com/gleam-lang/erlang/blob/dfa7cd705d8e97fe3af48754307130ecc14b5a45/src/gleam/erlang/process.gleam)

Read: lines 1-250, 300-570, 650-880. Focus: Subject ownership, names/atoms, selectors, monitors, call, timers.

Ref: `dfa7cd705d8e97fe3af48754307130ecc14b5a45`. Git blob: `4e9c0ef140601bf8e055df18019f79d848146785` ([exact blob](https://api.github.com/repos/gleam-lang/erlang/git/blobs/4e9c0ef140601bf8e055df18019f79d848146785)).

<a id="s13"></a>
### S13 - rawhat/glisten

[src/glisten/internal/handler.gleam](https://github.com/rawhat/glisten/blob/930b772c98958ac4a4d139da5ce9b48b74887016/src/glisten/internal/handler.gleam)

Read: whole file. Focus: Per-connection state, typed internal/user events, socket activation.

Ref: `930b772c98958ac4a4d139da5ce9b48b74887016`. Git blob: `a5a4ab4beca36cf9f505f4171536d1e7fac73e34` ([exact blob](https://api.github.com/repos/rawhat/glisten/git/blobs/a5a4ab4beca36cf9f505f4171536d1e7fac73e34)).

<a id="s14"></a>
### S14 - rawhat/glisten

[src/glisten/internal/acceptor.gleam](https://github.com/rawhat/glisten/blob/930b772c98958ac4a4d139da5ce9b48b74887016/src/glisten/internal/acceptor.gleam)

Read: whole file. Focus: Accept loop, controlling-process handoff, temporary connection children.

Ref: `930b772c98958ac4a4d139da5ce9b48b74887016`. Git blob: `8bd85887f8796b375fbee42d3ab565459386597c` ([exact blob](https://api.github.com/repos/rawhat/glisten/git/blobs/8bd85887f8796b375fbee42d3ab565459386597c)).

<a id="s15"></a>
### S15 - gleam-wisp/wisp

[src/wisp.gleam](https://github.com/gleam-wisp/wisp/blob/main/src/wisp.gleam)

Read: lines 1-240. Focus: Public response/body types and ordinary transformation functions.

Ref: `main`. Git blob: `65b23db622b516fbf0e90d146695a13d17c8f140` ([exact blob](https://api.github.com/repos/gleam-wisp/wisp/git/blobs/65b23db622b516fbf0e90d146695a13d17c8f140)).

<a id="s16"></a>
### S16 - gleam-wisp/wisp

[examples/src/using_a_database/app.gleam](https://github.com/gleam-wisp/wisp/blob/f6e70b460f318d3308f9810f090315f575cbab24/examples/src/using_a_database/app.gleam)

Read: whole file. Focus: One database handle passed through captured application context.

Ref: `f6e70b460f318d3308f9810f090315f575cbab24`. Git blob: `be93efbc5d6bdf9b96db82460355c673798c1c02` ([exact blob](https://api.github.com/repos/gleam-wisp/wisp/git/blobs/be93efbc5d6bdf9b96db82460355c673798c1c02)).

<a id="s17"></a>
### S17 - rawhat/mist

[src/mist.gleam](https://github.com/rawhat/mist/blob/master/src/mist.gleam)

Read: lines 1-260. Focus: Public facade, opaque Next, response variants, body type transition.

Ref: `master`. Git blob: `b10e3fd6fb55686d21a20d93f6142dbac5176a32` ([exact blob](https://api.github.com/repos/rawhat/mist/git/blobs/b10e3fd6fb55686d21a20d93f6142dbac5176a32)).

<a id="s18"></a>
### S18 - rawhat/mist

[src/mist/internal/handler.gleam](https://github.com/rawhat/mist/blob/master/src/mist/internal/handler.gleam)

Read: whole file. Focus: Http1/Http2 state, closure-based integration, protocol transitions.

Ref: `master`. Git blob: `ddf00ee4d823241cc33e6171c6f9e86aecb7fcb9` ([exact blob](https://api.github.com/repos/rawhat/mist/git/blobs/ddf00ee4d823241cc33e6171c6f9e86aecb7fcb9)).

<a id="s19"></a>
### S19 - lpil/pog

[src/pog.gleam](https://github.com/lpil/pog/blob/main/src/pog.gleam)

Read: lines 1-270, 370-690. Focus: Pool vs checked-out connection, transaction cleanup, decoder-bearing queries.

Ref: `main`. Git blob: `7549db44c37c57232da959c874e59aa95daa7339` ([exact blob](https://api.github.com/repos/lpil/pog/git/blobs/7549db44c37c57232da959c874e59aa95daa7339)).

<a id="s20"></a>
### S20 - lpil/sqlight

[src/sqlight.gleam](https://github.com/lpil/sqlight/blob/main/src/sqlight.gleam)

Read: lines 1-560, through end. Focus: Cross-target FFI, typed rows, callback scope and normal-path close.

Ref: `main`. Git blob: `0adcfcac7e3d9fe395d859e45dfaba5fc3b99489` ([exact blob](https://api.github.com/repos/lpil/sqlight/git/blobs/0adcfcac7e3d9fe395d859e45dfaba5fc3b99489)).

<a id="s21"></a>
### S21 - lustre-labs/lustre

[src/lustre.gleam](https://github.com/lustre-labs/lustre/blob/e5ca4d8b647c2c13f2f42f51d500c2198a7a4d19/src/lustre.gleam)

Read: lines 1-260. Focus: MVU public contract, App parameters, runtime/domain message distinction.

Ref: `e5ca4d8b647c2c13f2f42f51d500c2198a7a4d19`. Git blob: `4d992edfa9e458fc763316656da917d6fdf18ab3` ([exact blob](https://api.github.com/repos/lustre-labs/lustre/git/blobs/4d992edfa9e458fc763316656da917d6fdf18ab3)).

<a id="s22"></a>
### S22 - lustre-labs/lustre

[src/lustre/runtime/server/runtime.gleam](https://github.com/lustre-labs/lustre/blob/e5ca4d8b647c2c13f2f42f51d500c2198a7a4d19/src/lustre/runtime/server/runtime.gleam)

Read: lines 1-540, through end. Focus: Model inside actor, typed runtime events, subscriber monitors, effect execution.

Ref: `e5ca4d8b647c2c13f2f42f51d500c2198a7a4d19`. Git blob: `aa5465dcc95093d7c78205f505fbbe23a1dfe0eb` ([exact blob](https://api.github.com/repos/lustre-labs/lustre/git/blobs/aa5465dcc95093d7c78205f505fbbe23a1dfe0eb)).

<a id="s23"></a>
### S23 - lustre-labs/lustre

[src/lustre/effect.gleam](https://github.com/lustre-labs/lustre/blob/e5ca4d8b647c2c13f2f42f51d500c2198a7a4d19/src/lustre/effect.gleam)

Read: lines 1-210. Focus: Opaque effect representation, callback actions, synchronous effect construction.

Ref: `e5ca4d8b647c2c13f2f42f51d500c2198a7a4d19`. Git blob: `dd46686371b9d1be5ad9722cff68fea18e89202b` ([exact blob](https://api.github.com/repos/lustre-labs/lustre/git/blobs/dd46686371b9d1be5ad9722cff68fea18e89202b)).

<a id="s24"></a>
### S24 - ghivert/gloogle

[apps/jupiter/src/jupiter/gleam/type_search.gleam](https://github.com/ghivert/gloogle/blob/d2d7e99b544af96631ccc48fb8cecdb61cc05ef4/apps/jupiter/src/jupiter/gleam/type_search.gleam)

Read: whole file. Focus: Actor-coordinated writes and direct cell snapshot reads.

Ref: `d2d7e99b544af96631ccc48fb8cecdb61cc05ef4`. Git blob: `8c515d92691bd9e7fccd5fe0cd8c7ff8d0202c45` ([exact blob](https://api.github.com/repos/ghivert/gloogle/git/blobs/8c515d92691bd9e7fccd5fe0cd8c7ff8d0202c45)).

<a id="s25"></a>
### S25 - ghivert/gloogle

[apps/jupiter/src/jupiter/context.gleam](https://github.com/ghivert/gloogle/blob/d2d7e99b544af96631ccc48fb8cecdb61cc05ef4/apps/jupiter/src/jupiter/context.gleam)

Read: whole file. Focus: Table creation location, shared handles, request-specific record updates.

Ref: `d2d7e99b544af96631ccc48fb8cecdb61cc05ef4`. Git blob: `9b820b0068bcda77c9b351a882dab1a6e3991463` ([exact blob](https://api.github.com/repos/ghivert/gloogle/git/blobs/9b820b0068bcda77c9b351a882dab1a6e3991463)).

<a id="s26"></a>
### S26 - ghivert/gloogle

[apps/jupiter/src/jupiter/gleam/type_search/search.gleam](https://github.com/ghivert/gloogle/blob/d2d7e99b544af96631ccc48fb8cecdb61cc05ef4/apps/jupiter/src/jupiter/gleam/type_search/search.gleam)

Read: lines 1-250. Focus: Recursive immutable index updates; lookup can also consult database.

Ref: `d2d7e99b544af96631ccc48fb8cecdb61cc05ef4`. Git blob: `8289db085fd5b2adbd78763e5f81e619e43d2015` ([exact blob](https://api.github.com/repos/ghivert/gloogle/git/blobs/8289db085fd5b2adbd78763e5f81e619e43d2015)).

<a id="s27"></a>
### S27 - ghivert/gloogle

[apps/jupiter/src/jupiter.gleam](https://github.com/ghivert/gloogle/blob/d2d7e99b544af96631ccc48fb8cecdb61cc05ef4/apps/jupiter/src/jupiter.gleam)

Read: whole file. Focus: Composition, startup order, nested periodic supervisors.

Ref: `d2d7e99b544af96631ccc48fb8cecdb61cc05ef4`. Git blob: `8e6e7d192d650ec0e0c4b147f1536ce4db7546b5` ([exact blob](https://api.github.com/repos/ghivert/gloogle/git/blobs/8e6e7d192d650ec0e0c4b147f1536ce4db7546b5)).

<a id="s28"></a>
### S28 - gleam-lang/http

[src/gleam/http/request.gleam](https://github.com/gleam-lang/http/blob/main/src/gleam/http/request.gleam)

Read: lines 1-220. Focus: Public generic records and type-changing body transformations.

Ref: `main`. Git blob: `4b801d12811a3acd93d0ffb394d931a6e9ff0c30` ([exact blob](https://api.github.com/repos/gleam-lang/http/git/blobs/4b801d12811a3acd93d0ffb394d931a6e9ff0c30)).

<a id="s29"></a>
### S29 - gleam-lang/stdlib

[src/gleam/dict.gleam](https://github.com/gleam-lang/stdlib/blob/main/src/gleam/dict.gleam)

Read: lines 1-210. Focus: Immutable public API and encapsulated JavaScript mutable transients.

Ref: `main`. Git blob: `710b469c0cc45824a177e580cc459e30a0a2a7bb` ([exact blob](https://api.github.com/repos/gleam-lang/stdlib/git/blobs/710b469c0cc45824a177e580cc459e30a0a2a7bb)).

<a id="s30"></a>
### S30 - gleam-lang/stdlib

[src/gleam/dynamic/decode.gleam](https://github.com/gleam-lang/stdlib/blob/main/src/gleam/dynamic/decode.gleam)

Read: lines 1-250, 350-600. Focus: Composable decoders, field errors, final run boundary.

Ref: `main`. Git blob: `bffb9d84ac781bd0530e48ae7feebe45dba3d492` ([exact blob](https://api.github.com/repos/gleam-lang/stdlib/git/blobs/bffb9d84ac781bd0530e48ae7feebe45dba3d492)).

<a id="s31"></a>
### S31 - gleam-lang/json

[src/gleam/json.gleam](https://github.com/gleam-lang/json/blob/main/src/gleam/json.gleam)

Read: lines 1-230. Focus: Syntax vs shape errors, typed parse, target-specific FFI.

Ref: `main`. Git blob: `e3a3cae5566f7ccd8db19fb6f4213e8cba00fe88` ([exact blob](https://api.github.com/repos/gleam-lang/json/git/blobs/e3a3cae5566f7ccd8db19fb6f4213e8cba00fe88)).

<a id="s32"></a>
### S32 - giacomocavalieri/squirrel

[src/squirrel/internal/gleam.gleam](https://github.com/giacomocavalieri/squirrel/blob/5b6407d14a7c83af102944f2c86f52a521a74d57/src/squirrel/internal/gleam.gleam)

Read: lines 1-240. Focus: Opaque validated identifier types, structured type representation.

Ref: `5b6407d14a7c83af102944f2c86f52a521a74d57`. Git blob: `f7b8c68909c61acb35d77a2983ae7ebf18a58a12` ([exact blob](https://api.github.com/repos/giacomocavalieri/squirrel/git/blobs/f7b8c68909c61acb35d77a2983ae7ebf18a58a12)).

<a id="s33"></a>
### S33 - giacomocavalieri/squirrel

[src/squirrel/internal/database/postgres.gleam](https://github.com/giacomocavalieri/squirrel/blob/5b6407d14a7c83af102944f2c86f52a521a74d57/src/squirrel/internal/database/postgres.gleam)

Read: lines 1-195, 320-495. Focus: Connection/cache context, state threading, typed query inference flow.

Ref: `5b6407d14a7c83af102944f2c86f52a521a74d57`. Git blob: `73262e7a6bd7ce858a08acb69d213b859f441ec9` ([exact blob](https://api.github.com/repos/giacomocavalieri/squirrel/git/blobs/73262e7a6bd7ce858a08acb69d213b859f441ec9)).

<a id="s34"></a>
### S34 - giacomocavalieri/birdie

[src/birdie.gleam](https://github.com/giacomocavalieri/birdie/blob/main/src/birdie.gleam)

Read: lines 1-255, 270-470. Focus: Phantom snapshot states, typed outcomes, IO boundaries and delayed analysis.

Ref: `main`. Git blob: `e23f741f624831582e7d88d4daaaa858704d23b8` ([exact blob](https://api.github.com/repos/giacomocavalieri/birdie/git/blobs/e23f741f624831582e7d88d4daaaa858704d23b8)).

<a id="s35"></a>
### S35 - gleam-lang/http

[test/gleam/http/request_test.gleam](https://github.com/gleam-lang/http/blob/main/test/gleam/http/request_test.gleam)

Read: lines 1-165. Focus: Direct value tests, missing/malformed input, request transformations.

Ref: `main`. Git blob: `6eebc292e7d5ae71e434fe7bdf384c4254bf6ea8` ([exact blob](https://api.github.com/repos/gleam-lang/http/git/blobs/6eebc292e7d5ae71e434fe7bdf384c4254bf6ea8)).

<a id="s36"></a>
### S36 - lpil/pog

[test/pog_test.gleam](https://github.com/lpil/pog/blob/1260e90168cba09acdab3a226ca026c9afb69285/test/pog_test.gleam)

Read: lines 320-620. Focus: Decoder mismatch, timeouts, commit, returned-error rollback, panic rollback.

Ref: `1260e90168cba09acdab3a226ca026c9afb69285`. Git blob: `3a6f7adc6d5fec1e4c357ffbb1f39404831666e6` ([exact blob](https://api.github.com/repos/lpil/pog/git/blobs/3a6f7adc6d5fec1e4c357ffbb1f39404831666e6)).

## Official semantic references

<a id="e01"></a>
### E01 - Erlang/OTP ETS reference (OTP 28 documentation)

[Erlang/OTP ETS reference (OTP 28 documentation)](https://www.erlang.org/docs/28/apps/stdlib/ets.html). Used for: Atomicity scope, access modes, owner lifetime, copying, transfer and table traversal.

<a id="e02"></a>
### E02 - Erlang efficiency guide: processes

[Erlang efficiency guide: processes](https://www.erlang.org/doc/system/eff_guide_processes.html). Used for: Message copying, refcounted binaries/literals, loss of sharing, measurement.

<a id="e03"></a>
### E03 - Erlang persistent_term reference

[Erlang persistent_term reference](https://www.erlang.org/doc/apps/erts/persistent_term.html). Used for: Read-mostly use and update/garbage-collection costs.

<a id="e04"></a>
### E04 - Gleam language tour: use

[Gleam language tour: use](https://gleam.run/book/tour/use.html). Used for: Use expression desugars to a callback.

<a id="e05"></a>
### E05 - Gleam language tour

[Gleam language tour](https://tour.gleam.run/everything/). Used for: Opaque types and smart-constructor semantics.

