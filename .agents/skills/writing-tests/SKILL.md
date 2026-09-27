---
name: writing-tests
description: Decide what test to write, keep, or delete in albedo. Use when adding tests for a change, reviewing test coverage, or pruning the suite. Default to an end-to-end scenario through the real daemon on the shared harness in test/e2e; write a unit test only for a cross-cutting invariant or bug-prone logic that E2E cannot reach.
---

# Writing tests

albedo's tests are mostly end-to-end: the real daemon, driven through the real CLI and HTTP API, with a scripted fake model provider standing in for the network. Unit tests are the exception. Each one has to catch a real bug that the E2E suite would miss.

## Where a test goes

1. **E2E scenario (default).** If the behaviour can be seen from outside the daemon (a turn, a tool call, the Python namespace, history, events, agents and mail, extensions, MCP, webhooks, compaction, restart, or teardown), add a test method to `test/e2e/<area>_test.py` using `test/e2e/harness.py`. Script the provider's replies, drive the daemon, and assert on what a user or the model would observe. Read the harness module docstring for its API. Don't copy its plumbing into your test.
2. **Invariant unit test.** Write one for a whole-system rule that no single run exercises. The model is exposed to an API, so it must be documented. A registry must be complete. Two lists that must agree actually agree.
3. **Logic unit test.** Write one for a small piece of logic that is easy to get wrong and that E2E can't reach, or would only reach flakily. Examples are a wire-format parser, a tricky state machine, clock- or race-dependent code, or a regression that came back once. Test it through the public function, with real inputs.

When a behaviour matters and isn't covered end to end, move it into an E2E scenario rather than keep or write a unit test.

## The model unit test

`test/harness/api_docs_test.py` is the example to follow. It builds the model's real Python namespace. It collects every string literal the harness can show the model. It then fails for each public call the model is never told about. That rule spans every plugin, and a normal run can't notice when it breaks. The bug has actually happened before (`files.write`, `cells.last_id`, and bash's `timeout` were all real but undocumented). The test is cheap, uses no mocks of the thing under test, and says why it exists in its docstring.

## Delete, or don't write

- The test restates the implementation, so any refactor breaks it and no bug does.
- It asserts on constants, copy, formatting, or default values.
- It covers trivial getters, constructors, record plumbing, or JSON round trips of our own types.
- It mocks the unit under test until the assertion is a tautology.
- It duplicates another test, or a behaviour an E2E scenario already exercises.
- It's a snapshot of rendered output with no rule behind it.

## Conventions

- Start each test module with a docstring that says which bug it catches and why E2E can't.
- The whole E2E run shares one daemon. Never start a daemon per test or per file. Isolate tests with their own session, workspace, and provider route; restore any global state you change; and restart the shared daemon only when the behaviour under test is a restart.
- One area per E2E file, and one behaviour per test method, with a name that states the behaviour.
- No live network or credentials. Anything that needs them belongs in `test/manual`, which is opt-in.
- Every check that must pass is listed in `test.sh`. Add new suites there, and run the affected suite and report real results before calling the work done.
- When you delete a test module, also delete the test-only support modules only it used, such as `test/**/albedo_*_test_support.erl` and fake servers.
