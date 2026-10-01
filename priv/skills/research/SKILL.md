---
name: research
description: Investigate a library, tool, API, another project's implementation, or an approach, and report a recommendation backed by evidence, without editing anything. Use when the user asks how something works or how another project does it, what to use for a job, to compare options, or to look into something before deciding. Not for applying the choice.
---

# Research

Find what produces the best result for the user's actual need, then report it so they can decide quickly. Research ends in a recommendation and evidence. It does not edit the project unless the user asks.

## Frame the decision

Name only the criteria that could change the answer: the use-site you want (the code or command a maintainer would write), the constraints that really apply (language, runtime, version, platform, licence, size), and what must be preserved (behavior, streaming, errors, performance). "It can compute the same result" is not enough; ergonomics and fit are real criteria.

## Look at the right thing

- Pin what you read. Record the version, or for a repository the branch and commit (`git rev-parse HEAD`). Compare against the version the user actually runs, not the newest docs. Checking the wrong branch or a stale copy is the commonest way to be confidently wrong.
- To study another project, clone it shallowly into the user's research directory if they keep one (for example `~/.research`), otherwise into `/tmp`, instead of reading it through a browser, so you can search it and run it.
- Local code, the platform, the standard library, existing dependencies, new dependencies, and other projects' solutions are all peers. Start with what the project already uses, so the answer fits its language.
- Treat other projects as inspiration, not reference. They may be wrong or slow at exactly the thing you are looking at. Take mechanisms and their tradeoffs, not designs.

## Search narrowly, then stop

1. Skim the project's own manifests, helpers, and similar code to learn its constraints.
2. Search a small, credible set of options, including ones not yet installed. Do not catalogue the whole ecosystem.
3. Read the public surface at the version that matters: official docs, generated types, examples, or source. Read internals only when behavior is unclear or the decision depends on it.
4. When API shape decides it, prototype the one decisive call site. A small program that runs answers faster than a feature matrix.
5. Stop when the ranking is stable. Do not keep browsing to prove no better option exists.

## Test what you will claim

If a statement can be checked, check it before you make it: run the command, the example, the build, the request. A claim you only inferred ("that account is out of quota", "this library can't stream") has been wrong before. Say which statements you ran and which you inferred.

## Report

Lead with the answer. Then give only what bears on the decision:

```text
Need:      <the use-site and requirements>
Use:       <option and version, or the mechanism to port>
Why:       <fit, behavior, evidence with file:line or doc links at the pinned version>
Tradeoff:  <only a cost that could reverse the choice>
Unverified: <what you inferred rather than ran>
```

Give exact paths and lines for anything the user may want to read. Mention an alternative only when its tradeoff could change the decision.

For broad questions, split the reading across read-only helpers, one report file each. A small, fast model is enough for reading and summarizing; keep the judgment for yourself, and check their claims against the source before relaying them.
