# Context snapshot measurements

The snapshot history closure now retains visible text, tool IDs, image metadata, and replay markers. It releases opaque replay data, inline image bodies, and stored-image reader closures. Text histories still retain the text needed for inspection.

## Run the offline benchmark

Use the same test files and dependencies in isolated baseline and candidate builds. Run each version sequentially with the same Erlang flags:

```sh
ERL_FLAGS="+S 2:2 +sbwt none" gleam run -m manual/context_snapshot_benchmark > baseline.jsonl
ERL_FLAGS="+S 2:2 +sbwt none" gleam run -m manual/context_snapshot_benchmark > candidate.jsonl
python3 test/manual/context_snapshot_benchmark_report.py baseline.jsonl candidate.jsonl summary.json
```

The entry point runs one warm-up and five measured runs per fixture, each in a fresh owner process. Fixture construction precedes capture timing. Replacement timing covers five replacements with the previous snapshot held during the next capture. Output hashes describe observed output; they do not enforce a compatibility contract.

Each phase records wall time, reductions, and peaks sampled at one-millisecond intervals. VM binary peaks are absolute VM measurements. Empty peak records mean the sampler missed a brief phase, not that its memory use was zero. Post-collection binary counts deduplicate `process_info` entries by backing pointer. Snapshot term size excludes off-heap binary bodies.

The offline `history_eviction_collection` phase measures owner collection after history and rendered buffers have been released through tail calls. `idle_retention` and `context_clear` also describe this isolated owner. They do not measure session dispatch, durable-history loading, or kernel shutdown. The E2E probe measures those session operations separately.

## Recorded capture and retention results

Baseline revision: `75f8b53415fbce4184647a501c4d75f506a50a7e`. Both versions used Gleam 1.18.1, OTP 28, two schedulers, and the same manifest. The benchmark does not call the native renderer. Measurements were taken on 2026-10-01.

Capture columns report microseconds as median [minimum, maximum]. Binary columns report median retained bytes after inputs are released and the owner is collected, before any inspector access.

| Fixture | Baseline capture µs | Candidate capture µs | Baseline binary bytes | Candidate binary bytes |
| --- | ---: | ---: | ---: | ---: |
| text, 10 × 256 bytes | 1 [1, 1] | 3 [3, 4] | 3,584 | 2,660 |
| text, 1,000 × 256 bytes | 79 [77, 84] | 145 [95, 156] | 256,000 | 256,000 |
| text, 10,000 × 256 bytes | 1,760 [1,652, 2,427] | 1,758 [1,466, 1,952] | 2,560,000 | 2,560,000 |
| replay, 10 × 4,096 bytes | 83 [54, 101] | 48 [48, 48] | 41,280 | 0 |
| replay, 1,000 × 4,096 bytes | 11,023 [10,251, 19,311] | 5,631 [5,542, 5,706] | 4,128,000 | 0 |
| replay, 10,000 × 4,096 bytes | 112,761 [62,465, 134,728] | 62,681 [60,224, 75,951] | 41,280,000 | 0 |
| replay, 1,000 × 65,536 bytes | 88,079 [87,557, 90,585] | 88,027 [84,605, 94,281] | 65,568,000 | 0 |
| mixed, 1,000 × 4,096 bytes | 9,153 [6,527, 13,370] | 6,671 [6,281, 13,847] | 8,224,256 | 4,096,062 |

Replay-only snapshots release all payload binaries before inspection. The large replay fixture releases about 62.5 MiB. The mixed fixture retains its required visible text. Its stored-image references do not contain base64 bodies, so this fixture cannot demonstrate base64 savings.

Timing regressed in some phases. At 1,000 text entries, capture increased from 79 to 145 µs, and five replacements increased from 279 to 717 µs. At 10,000 text entries, summary increased from 34,192 to 49,860 µs. The 1,000-entry large-replay summary increased from 5,239 to 10,949 µs. These are observations from five runs, not machine-independent performance guarantees. Full medians, ranges, reductions, and sampled peaks are in the generated summary JSON.

Capture still temporarily serializes replay JSON for exact byte counting. The 1,000 × 64 KiB replay capture median remained about 88 ms. Inspection still renders the full history for each summary or page; this benchmark does not introduce incremental rendering or caching.

## Session behavior and retention

`python3 test/e2e/run.py context_retention` exercises a real daemon with `ALBEDO_INSPECT`. The fixture verifies that opaque replay reaches the second provider request, waits for worker termination, calls public history eviction, passes queued collection using actor barriers, and walks closure environments in a short-lived reader. That reader exits before final sampling. The actor has already unloaded its history after the turn, so eviction returns false; the check still verifies that the snapshot does not keep the discarded replay alive.

The baseline actor retained a 262,160-byte replay backing binary and referenced 304,743 binary bytes in total. The candidate retained no replay backing binary and referenced 42,472 binary bytes. Inspector history remained readable. Kernel release cleared the context, and actor shutdown completed. These session figures are one regression scenario, not five-run benchmark medians.

The focused Gleam regression separately constructs distinct replay and inline-image payloads plus a stored-reader sentinel in a producer. After the producer exits, the snapshot owner collects and walks closure environments. Required text remains reachable; all three discarded payloads are absent.

Recorded scratch artifacts:

- `/tmp/albedo-inspector-baseline-benchmark.jsonl`
- `/tmp/albedo-inspector-candidate-benchmark.jsonl`
- `/tmp/albedo-inspector-benchmark-summary.json`
- `/tmp/albedo-inspector-baseline-actor.json`
- `/tmp/albedo-inspector-candidate-actor.json`
- `/tmp/albedo-inspector-gate-final.log`
