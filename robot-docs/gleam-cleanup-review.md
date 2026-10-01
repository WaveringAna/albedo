# Gleam cleanup review

The baseline at `db307c370655b9679b44757bd8cc67504826d1fc` contained 4,563 findings. They were review prompts, including test
assertions, deliberate fallbacks, and style preferences. This cleanup adds the
missing function annotations and existing labels, qualifies `option.unwrap`,
removes the redundant binding, and names the two ambiguous test keys.

The error review covered the 404 baseline
production assertion, unwrap, discarded-value, discarded-error, and
lost-context findings, distinguishing defects from intentional invariants,
fallbacks, and best-effort operations.

The export review covered the 124 baseline production
export findings and additional exports exposed by removing their callers. The
review checks Gleam imports and aliases, Erlang calls, registered callbacks,
dynamic dispatch, and public type contracts. Same-module helpers are private;
unused definitions are removed. Native callers in `albedo_cache_ttl`,
`albedo_settings_store`, and `albedo_models` retain their Gleam exports. Extension
embedding constructors, framework entrypoints, inferred public type contracts,
and discovered tests retain their exports. FFI tuple representations do not
change when a type becomes private.

## Behavior fixes

Session initialization now requires the default reasoning effort to be saved
before it publishes that effort. Failure leaves the session unavailable until a
later activation succeeds. Initialization diagnostics retain the failure reason
in the daemon log; HTTP errors keep their existing shape and generic message.

Parent deletion and subtree collection now return child-query failures before
attempting deletion. The tree walk still deletes children before parents and
retains the existing partial-deletion behavior for failures after the walk starts.

Mail dispatch reports failures to save delivery errors. Scheduling reports
failures to advance an occurrence. Both retain their existing durable retry
policy. Schedule submission and occurrence advancement remain separate effects,
so an advance failure can lead to another delivery on a later tick.

Provider decoding errors retain JSON error categories or decoder types and field
paths. The shared helpers omit unexpected JSON bytes and sequences, and never
include provider values. Existing string errors remain at compatibility
boundaries. No persisted format, actor protocol, HTTP response shape, or schema
changes.

Source-page folding binds the last row from a nonempty pattern. LCM summary
chunks explicitly reject an empty list and fold from the first row to obtain the
last. Other assertions retain documented programmer or native-boundary invariants.

## Verification

The daemon E2E regressions reject an unsaved startup effort, recover after the
write succeeds, refuse direct and tree deletion when child queries fail, and
report/retry a failed schedule advance. The Claude parser regression checks
malformed event diagnostics without reaching its authenticated endpoint and
verifies that provider values do not appear in the diagnostic.

Formatting, `gleam check`, the 186 Gleam tests, and the full existing `test.sh`
gate pass. The curated manual lint run reports no mechanical errors. Remaining
review warnings include intentional invariants, fallbacks, and best-effort operations.

## All-rules comparison

The table counts source and test findings together. Regenerate the current
column with the `--all --format json` command in [the lint guide](gleam-lint.md).
The baseline used the same rules on the pre-cleanup source. New parser assertions
and inferred signatures can add findings to diagnostic-only rules.

| Rule | Baseline | After cleanup |
| --- | ---: | ---: |
| `assert_ok_pattern` | 622 | 621 |
| `avoid_panic` | 13 | 13 |
| `deep_nesting` | 77 | 79 |
| `discarded_result` | 83 | 80 |
| `error_context_lost` | 13 | 0 |
| `function_complexity` | 26 | 26 |
| `label_possible` | 2105 | 2049 |
| `missing_labels` | 19 | 0 |
| `missing_type_annotation` | 376 | 0 |
| `module_complexity` | 4 | 4 |
| `prefer_guard_clause` | 45 | 45 |
| `short_variable_name` | 2 | 0 |
| `string_inspect` | 24 | 24 |
| `stringly_typed_error` | 472 | 473 |
| `thrown_away_error` | 164 | 162 |
| `unnecessary_string_concatenation` | 34 | 34 |
| `unnecessary_variable` | 1 | 0 |
| `unqualified_import` | 1 | 0 |
| `unused_exports` | 310 | 200 |
| `unwrap_used` | 172 | 171 |
| Total | 4563 | 3981 |
