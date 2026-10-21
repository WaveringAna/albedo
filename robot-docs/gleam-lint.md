# Run the Gleam commit check

The Nix development shell supplies `albedo-lint`: glinter 2.19.2 plus albedo's
own rules, built from `tools/lint` (its own Gleam project, locked by
`tools/lint/manifest.toml`, separate from the daemon's dependencies). The dev
shell is cached until its nix files change, so after editing `tools/lint` run
`nix build .#albedo-lint` and put its `bin` first on `PATH`.
Run the commit check with:

```sh
nix develop -c test/gleam-lint.sh
```

The default uses the focused policy in `gleam.toml`. `--review` adds checks that
need caller and failure-contract inspection, using `test/manual/glinter-review.toml`.
`--all` uses `test/manual/glinter-all.toml`. `--albedo` is the default profile with the two albedo rules
that still have findings turned on (below). Both optional profiles run through a
temporary project with symlinks to this checkout. The commit hook runs the default
profile when Gleam files or lint configuration change; it checks all source and
test modules. `test.sh` runs the same profile before the build and test suites.
Neither optional profile is a commit requirement.

For manual review and audit reports, run:

```sh
nix develop -c test/gleam-lint.sh --review --format json > /tmp/albedo-review.json
nix develop -c test/gleam-lint.sh --all --format json > /tmp/albedo-audit.json
```

Keep generated reports under `/tmp`. Do not commit CSV inventories or
retrospective cleanup reports.

The default enables eleven rules as errors:

| Purpose | Rules |
| --- | --- |
| Explicit signatures and existing labels | `missing_type_annotation`, `missing_labels` |
| Imports and redundant bindings | `unqualified_import`, `duplicate_import`, `unnecessary_variable` |
| Debug and unfinished code | `echo`, `avoid_todo`, `todo_without_message` |
| Invalid arithmetic | `division_by_zero` |
| Suppression hygiene | `nolint_unused`, `nolint_inline` |

Of albedo's own rules, `albedo_clock` is part of the default profile. Rule files
are in `tools/lint/src/albedo_lint/rules/`, each tied to a sentence in a
robot-docs page, and `test/harness/albedo_lint_test.py` feeds each one small
modules it must flag and ones it must leave alone.

| Rule | Invariant | Findings today |
| --- | --- | --- |
| `albedo_clock` | No clock external or `gleam/time/timestamp` outside `albedo/clock` (runtime.md, clocks). | 0, in the default profile |
| `albedo_text_scalars` | No `string.length`, `slice`, `drop_start` or `drop_end` in `src/` outside `albedo/text_scalars` (runtime.md, Unicode scalar limits). | 64 in 31 files, `--albedo` only |
| `albedo_table_ownership` | A table an extension creates is named in SQL only by that extension (extensions.md). Core tables are not checked. | 8, all `cells` and `cell_traces` read by the daemon, `--albedo` only |

glinter hands a module rule the source and not the path, so `albedo-lint` reads
every file once and finds a module's path by its source text; a rule that
depends on the path (the owner is exempt) relies on that. Add a rule by copying
one of the three; the project's config names it in `gleam.toml` like a
built-in. A rule goes in the default profile once its findings are fixed or
annotated.

A default run promotes all findings to errors and exits unsuccessfully when it
finds one.

These checks catch accidental debug or unfinished code and keep signatures,
imports, and existing labels consistent. Acceptance requires zero findings,
without a warning allowance or a growing baseline. Keep a rule in the commit
profile only when its findings warrant a concrete fix across production and
tests. Rules that need application context belong in manual review.

`--review` retains those errors and adds warnings for production assertions and
panics, discarded values and errors, lost error context, unused exports, and
single-branch cases. Inspect these against their callers and failure contracts.
A warning alone does not establish a defect. In particular, the discarded-value rule also flags
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
