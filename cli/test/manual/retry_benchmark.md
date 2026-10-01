# Operation recovery benchmark

Baseline: `23e4018`. Candidate: task 1a based on that revision, measured before rebasing onto main.

Go 1.26.7, linux/amd64, AMD Ryzen 5 5600X, 12 logical CPUs. Each revision ran sequentially: one 300 ms warm-up, then five 500 ms measurements per scenario. The fixture is a local HTTP server, not the daemon; E2E tests establish real admission and durable effects.

| Scenario | Baseline µs/op, median [range] | Candidate µs/op, median [range] | B/op, baseline → candidate | Allocs/op, baseline → candidate | Requests/effects per op, baseline → candidate | Health probes/op, baseline → candidate |
| --- | --- | --- | --- | --- | --- | --- |
| healthy-read | 67.45 [66.87–68.87] | 69.40 [67.37–70.25] | 7760 → 7761 | 91 → 91 | 1/0 → 1/0 | 0 → 0 |
| healthy-mutation | 72.82 [71.84–75.83] | 72.22 [70.95–72.39] | 9037 → 9027 | 108 → 107 | 1/1 → 1/1 | 0 → 0 |
| read-recovery | 442.25 [437.67–456.81] | 450.95 [447.11–454.75] | 54897 → 55523 | 371 → 381 | 2/0 → 2/0 | 1 → 1 |
| auth-recovery | 348.45 [348.41–351.60] | 239.84 [239.53–249.63] | 39921 → 27802 | 358 → 316 | 2/1 → 2/1 | 1 → 1 |
| lost-mutation-ack | 361.61 [358.29–367.90] | 181.22 [179.24–183.84] | 46341 → 28751 | 338 → 148 | 2/2 → 1/1 | 1 → 0 |

Healthy-read median overhead is 1.95 µs (2.9%); healthy mutations are 0.60 µs faster, with no allocation increase in either case. A lost mutation acknowledgement now returns uncertainty after one execution; the baseline acknowledged a second execution. Its table latency is the time until that return, not daemon execution time. Auth recovery still rejects once and admits once.

The read-recovery fixture closes successful responses, forcing the next dropped request onto a fresh socket. Both revisions perform one discovery health probe per operation, establishing that this scenario measures application recovery rather than Go’s pooled-connection retry.

Policy and snapshot work is O(1); bounded encoding/decoding remains O(payload bytes). Recovery costs include discovery, health validation, request construction, and a second connection when needed. Explicit read recovery costs 10 additional allocations and 626 additional bytes per operation; the healthy path does not.

Reproduce from the repository root:

```sh
go -C cli test ./test/manual -run '^$' -bench BenchmarkOperation -benchtime=300ms -count=1
go -C cli test ./test/manual -run '^$' -bench BenchmarkOperation -benchmem -benchtime=500ms -count=5
```

For a baseline measurement, archive its `cli` tree into `/tmp`, copy `retry_benchmark_test.go` unchanged, and replace only `benchmarkRequest` with `daemon.RequestMethod[map[string]any](ctx, connection, method, "/operation", body)`. This adapter is measurement setup, not a retained compatibility test.

Raw measurements: `/tmp/albedo-retry-baseline.txt`, `/tmp/albedo-retry-candidate.txt`; toolchain: `/tmp/albedo-retry-go-version.txt`; parsed values: `/tmp/albedo-retry-benchmark-results.json`.
