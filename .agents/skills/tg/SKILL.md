---
name: tg
description: Use the tg CLI for Tangled tasks, including repositories, issues, pull requests, and CI.
---

# tg

Use `tg` for Tangled operations. Consult `tg <command> --help` for other flags. Prefer boolean `--json` for structured results.

Replace the example repository with the task's target. Replace `<key>` with an issue or PR record key, the final segment of its `at://` URI.

## Find and clone a repository

Search, inspect, or clone with these commands:

```bash
tg repo search 'project' --json
tg repo view alice.example.com/project --json
tg repo clone alice.example.com/project
cd project
```

Run the following recipes inside the checkout. tg detects the repository from Git remotes, checking `origin` first.

## Authenticate for writes

If the account is uncertain, check `tg auth status --json`. If login is needed, run `tg auth login <handle>`. Select an existing login per command with `--account <handle-or-did>`.

## Read and file issues

List open issues, then inspect a returned key:

```bash
tg issue list --state open --json
tg issue view <key> --json
```

To file an issue or comment on one, supply the text explicitly:

```bash
tg issue create 'Clone fails' --body 'Steps to reproduce...' --json
tg issue comment <key> --body 'Reproduced on Linux.' --json
```

For multiline create or comment bodies, use `--body-file <path>`. Pass a real file path. `--body-file -` reads a file named `-`.

## Review and submit pull requests

Find a PR and inspect its patch:

```bash
tg pr list --state open --json
tg pr view <key> --json
tg pr diff <key>
```

To submit local commits, write the description to `body.md`, then create the PR:

```bash
tg pr create --title 'Fix clone failure' --body-file body.md --json
```

tg uploads a patch of committed changes. For forks, set `--repo` to the target and `--source-repo` to the fork. Fetch the target branch, then pass that remote-tracking branch as `--base`.

To submit revised commits, run `tg pr update <key>`. It appends a patch round from the PR's recorded source branch. For forks, pass `--base` again.

Issue edits, PR edits, and PR updates address the selected account's records and do not accept `--repo`. For edits, use `--title` or `--body`.

## Inspect CI

Find the pipeline for the intended commit, then inspect its status or logs:

```bash
tg pipeline list --json
tg pipeline view <id> --json
tg pipeline logs <id> --json
```

Parse logs as one JSON event per line. Without an ID, logs select the default branch's latest pipeline. Use `tg pipeline status --json` for that pipeline. Failed or timed-out workflows produce output and an unsuccessful exit.

If a write loses its connection, inspect remote state before retrying. The server may have accepted the request.
