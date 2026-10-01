# Run the Gleam commit check

The Nix development shell supplies glinter at commit
`2141f5b431040b2a4b126a98276e59028cd945ec`, with its upstream dependencies locked
separately from the daemon. The cleanup audit used Gleam 1.18.1.
Run the commit check with:

```sh
nix develop -c test/gleam-lint.sh
```

The default uses the focused policy in `gleam.toml`. `--review` adds checks that
need caller and failure-contract inspection, using `test/manual/glinter-review.toml`.
`--all` uses `test/manual/glinter-all.toml`. Both optional profiles run through a
temporary project with symlinks to this checkout. The commit hook runs the default
profile when Gleam files or lint configuration change; it checks all source and
test modules. `test.sh` runs the same profile before the build and test suites.
Neither optional profile is a commit requirement.

For manual review and audit reports, run:

```sh
nix develop -c test/gleam-lint.sh --review --format json > /tmp/albedo-review.json
nix develop -c test/gleam-lint.sh --all --format json > /tmp/albedo-audit.json
```

The default enables eleven rules as errors:

| Purpose | Rules |
| --- | --- |
| Explicit signatures and existing labels | `missing_type_annotation`, `missing_labels` |
| Imports and redundant bindings | `unqualified_import`, `duplicate_import`, `unnecessary_variable` |
| Debug and unfinished code | `echo`, `avoid_todo`, `todo_without_message` |
| Invalid arithmetic | `division_by_zero` |
| Suppression hygiene | `nolint_unused`, `nolint_inline` |

A default run promotes all findings to errors and exits unsuccessfully when it
finds one. The cleanup left this profile with zero findings.

These checks catch accidental debug or unfinished code and keep signatures,
imports, and existing labels consistent. Acceptance requires zero findings,
without a warning allowance or a growing baseline. Keep a rule in the commit
profile only when its findings warrant a concrete fix across production and
tests. Rules that need application context belong in manual review.

`--review` retains those errors and adds warnings for production assertions and
panics, discarded values and errors, lost error context, unused exports, and
single-branch cases. Inspect these against their callers and failure contracts.
The cleanup left 267 warnings in this profile. A warning alone
does not establish a defect. In particular, the discarded-value rule also flags
`Nil`, `Bool`, timer handles, monitor handles, and process handles.

Keep tests exported for discovery. Test assertions and deliberate failure
sentinels are exempt from assertion, panic, and unused-export checks. Annotations
and existing-label checks still apply to tests.

Both focused and review profiles disable short-name and trailing-underscore
preferences, blanket labels, guard preferences, string-error
bans, unwrap bans, literal-concatenation bans, complexity thresholds, and
inspection bans. Keep diagnostic inspection and readable SQL construction. Keep
JS FFI checking disabled for the Erlang target.

In the audited glinter version, findings can retain their default severity even
when configuration enables them as errors. A debug `echo` probe confirmed this;
the focused profile uses `warnings_as_errors` to enforce its failure status.
The review profile is for inspection, so its exit status is not an acceptance
check. Unwrap and complexity findings retain `off` in the all-rules JSON report.
`off` therefore does not mean that the all-rules run skipped those checks.
Compare findings by rule, function, and expression as well as line number;
annotations and removed definitions move source lines.

See [the cleanup review](gleam-cleanup-review.md) for dispositions and the
before/after counts.
