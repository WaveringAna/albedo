# Manual checks

These tools are opt-in. The full test gate excludes them because they require
credentials, a real SSH host, an installed package, or benchmark artifacts.
Run commands from the repository root inside `nix develop`.

| Tool | Invocation and prerequisites | Result |
| --- | --- | --- |
| Packaged binary | `python3 test/manual/nix_package_smoke.py /absolute/path/to/bin/albedo` | Checks the installed client and daemon outside the checkout with a restricted PATH. Fails on an invalid package. |
| Remote kernel | `python3 test/manual/remote_ssh.py user@host` | Requires key authentication and remote Python 3.11 or newer. Exercises staging, kernel boot, tool calls, and connection reuse. |
| Kernel memory | `python3 test/manual/kernel_memory_benchmark.py --scale 1 10 --output /tmp/kernel-memory.json` | Measures boot and workload memory. Writes measurements for comparison, rather than imposing a universal memory threshold. |
| Active output | `python3 test/manual/active_output_benchmark.py --baseline /tmp/baseline/albedo-daemon --candidate /tmp/candidate/albedo-daemon --output /tmp/active-output-results.json` | Requires two exported daemon builds and Linux `/proc` for memory measurements. Compares attachment and hydration performance using a gated local provider. |
| Interval implementation | `python3 test/manual/verify_intervals.py /directory/containing/interval_set.py` | Runs five unittest scenarios, including randomized interval algebra. Exits unsuccessfully when the candidate violates the contract. |
| Provider benchmark | `gleam run -m manual/benchmark` | Requires `ALBEDO_BENCH_URL`, `ALBEDO_BENCH_MODEL`, and `ALBEDO_BENCH_KEY`. Optional `ALBEDO_BENCH_PROTOCOL` selects a protocol. Prints request timings and memory measurements. |
| Stream benchmark | `gleam run -m manual/stream_benchmark` | Offline. Frames and reduces synthetic Responses and Chat Completions streams and encodes a 1 MB request, printing time per run and throughput. Compare before and after a change to `openai_api`. |
| Live coding | `gleam run -m manual/coding` | Requires the benchmark URL, model, and key, plus `ALBEDO_LIVE_WORKSPACE` and `ALBEDO_LIVE_DATABASE`. Optional `ALBEDO_LIVE_PROTOCOL` selects a protocol. Runs a real model-driven coding scenario. |

`albedo_openai_bench.erl` supports the provider benchmark and live coding tool.
`albedo_live_coding.erl` supports the live coding tool. They are native helpers,
not independent suites.

The `glinter-review.toml` and `glinter-all.toml` files configure advisory lint
profiles. Run `test/gleam-lint.sh --review` or `test/gleam-lint.sh --all`.
See [the lint documentation](../../robot-docs/gleam-lint.md) for interpretation.

Do not bulk-import these scripts as a smoke check. Some consume command-line
arguments or execute immediately on import. Ruff and ty cover their source in
the normal gate; exercise their documented commands when changing them.
