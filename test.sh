#!/usr/bin/env bash
# Every check that must pass before a commit.
#
# The daemon tests start a daemon with `gleam run`, so they stay outside
# `gleam test`: a nested build would wait on the build lock this suite holds.
# test/manual is opt-in and not run here; those harnesses need a provider,
# a PTY, or artifacts from an earlier benchmark run.
set -euo pipefail
cd "$(dirname "$0")"
export ALBEDO_NO_BROWSER=1

gleam format --check src test
cargo test --release --locked --manifest-path native/render/Cargo.toml
native/render/install.sh
gleam test
python3 test/harness/api_docs_test.py
python3 test/harness/job_wake_test.py
python3 test/harness/run_plugin_test.py
python3 test/harness/remote_kernel_test.py
python3 test/harness/remote_plugin_test.py

(cd cli && go vet ./...)
(cd cli && go test ./...)
# the daemon suites drive the CLI through this binary
go -C cli build -o bin/albedo ./cmd/albedo

python3 test/e2e/run.py
