---
name: design-preflight
description: Decide where a change belongs and what it must not break before writing it. Use before adding a feature or changing behavior in a subsystem you have not worked in, before choosing where new code lives, or when a change touches shared state, a hot path, stored data, or an interface other code relies on.
---

# Design preflight

Passing tests do not show that a design fits. The costly mistakes are placement and side effects that the tests never look at, and they are expensive because they surface after the change is merged. Spend a few minutes before the first edit.

## 1. Read what the project says about this area

Read the project's instructions (`AGENTS.md`, a contributing guide) and the doc or README for the subsystem you are about to change, then the neighbouring code. Find the rule that applies and keep it in view. If a doc exists for the area, skipping it is the commonest cause of a rework.

## 2. Name the owner

Say which module, package, or layer owns this behavior, and which way dependencies are allowed to point. Put the code where its owner lives, not where it is convenient. Look for something that already does a similar job and reuse it. If two places could own it, that is a decision for the user, not a coin flip.

## 3. Place the work on the right path

State how often it runs and what triggers it. Work that only matters when something changes belongs where the change happens, not in a loop that runs every turn, request, or render. Check that nothing it needs to scan grows with history or file size.

## 4. List what it must not disturb

Go through the ones that apply and write the answer down:

- caches and prompt or request prefixes that must stay stable
- stored data and its format: old data, migrations, rollbacks
- public interfaces, commands, and settings others rely on
- concurrency, locks, and ordering
- trust boundaries and secrets
- startup time and memory

## 5. Decide growth and failure

For anything stored or retained: its cap, what removes it, and what happens at the cap. For anything that can fail: what the user or caller sees, and whether the failure can lose or delete data. A cleanup that deletes data deserves a test that shows it keeps what it should keep.

## 6. Plan the test that would catch a wrong design

Name the scenario, through the real program, that would fail if the design were wrong, including one unhappy path. A test that only exercises the code you just wrote does not.

## Then say it

Before coding, write the design in a few lines: the owner, where it runs, what it must not disturb, the test. If any of it is a choice the user might want a say in (ownership, interface shape, a data migration, behavior change), put that to them before the work, not after the push. There is time to do this properly; finishing fast is not the goal.
