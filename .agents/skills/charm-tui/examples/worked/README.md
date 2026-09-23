# Complete example programs

Start with the [worked tasks](../WORKED-EXAMPLES.md), not with copying the entire directory into an application. These programs demonstrate the decisions in the skill through concrete code and regression tests. They have no runtime network calls or credentials; search and log events are simulated locally.

## Try one

From this directory, with a Go toolchain compatible with [go.mod](go.mod):

```sh
go mod tidy
go test -race ./...
go vet ./...
go run ./cmd/picker
```

Run `go run ./cmd/search` or `go run ./cmd/tail` separately for the other demos. Resolve dependencies once; `go.sum` is intentionally not fabricated. Transitive dependency checksums were unavailable in the authoring environment.

**Picker.** An inline selector. Up/Down moves; `/` enters search. Escape/Enter from search returns to the list, keeping the query. Enter opens confirmation; Enter confirms and emits the captured ID on stdout. Escape from confirmation returns to the list. `q` quits only in browse mode. Ctrl+C cancels anywhere. `--list` and `--id prod-eu` never open a terminal. Interactive mode permits stdout redirection but requires terminal stdin/stderr; it does not read candidate data from stdin.

**Search.** An inline text input with a 150 ms cancellable debounce and injected backend. `slow` takes longer, `error` returns a recoverable failure, and `queue` produces a match. Ctrl+R retries with fresh request identity; Escape/Ctrl+C exits. The whole request lifetime, including debounce, has a three-second timeout. Results clear on edit rather than being displayed as stale. A result list larger than the visible area would need navigation/paging before adopting this demo for such a dataset.

**Tail.** A full-screen log monitor with a bounded 16-record transport queue and a 32-record display ring. Up/Down or j/k scrolls; End follows latest; q/Ctrl+C quits. A finite synthetic stream allows testing closure. Retention eviction is disclosed. It is not a persistent logger or a multi-line transcript renderer.

## Where the behavior lives

| Concern | File |
| --- | --- |
| Focus, contextual help, confirmation | [picker/model.go](cmd/picker/model.go) |
| Identity and final-result semantics | [picker/selection.go](cmd/picker/selection.go) |
| TTY detection and stdout/stderr separation | [picker/main.go](cmd/picker/main.go) |
| Request identity and cancellation | [search/request.go](cmd/search/request.go) |
| Tea commands and typed messages | [search/model.go](cmd/search/model.go) |
| Retention, reading anchor, following | [tail/history.go](cmd/tail/history.go) |
| Cancel-aware producer and receiver | [tail/stream.go](cmd/tail/stream.go) |
| One listener and no re-arm on closure | [tail/model.go](cmd/tail/model.go) |
| Actual cell clipping and v2 panels | [display/render.go](internal/display/render.go) |
| Bounds and plain-text control policy | [display/bounds.go](internal/display/bounds.go) |

## Tests and what has actually run

The exact core files used by these demos have 26 executed tests across four groups. This includes genuine context/timer/channel cancellation tests, not a mock of Bubble Tea. The source for all Go files was parsed/formatted by `gofmt`. Full module compilation was not possible here: Go 1.23.2 is installed, the module requests a newer toolchain, and network dependency resolution is blocked. Additional Charm model/render tests are supplied but remain unexecuted.

From the skill root:

```sh
python3 scripts/test_offline_examples.py
```

That script compiles the named dependency-free files directly with module mode disabled. It deliberately does not compile `model.go`, `render.go`, or the CLI entry points. This is not a replacement for `go test -race ./...` after dependency resolution. See [verification](../../VERIFICATION.md) and the [raw core test output](../../verification/worked-offline-tests.txt).

No terminal/PTY session, Unicode display inspection, agent evaluation, or target-project before/after comparison was executed during authoring. Do those before claiming an adapted UI is polished or behavior-equivalent.
