#!/usr/bin/env bash
# Every check that must pass before a commit.
#
# The quick checks run first, in order. Then the daemon is compiled once and
# every suite runs at the same time, each into its own log, which is printed
# only if that suite fails. The e2e suites boot their daemons from that one
# snapshot (ALBEDO_TEST_DAEMON) instead of through gleam, so none of them waits
# on the build lock `gleam test` holds for its whole run. test/manual is opt-in
# and not run here; those harnesses need a provider, a PTY, or artifacts from
# an earlier benchmark run.
set -euo pipefail
cd "$(dirname "$0")"
export ALBEDO_NO_BROWSER=1
# a detached kernel a suite left behind ends soon after, not in an hour
export ALBEDO_KERNEL_GRACE_SECONDS=20

ruff check
ruff format --check priv/python test cli/internal/storage/maintenance.py
ty check
gleam format --check src test
test/gleam-lint.sh
cargo test --quiet --release --locked --manifest-path native/render/Cargo.toml
native/render/install.sh
go -C cli vet ./...
# the Python e2e suite drives the CLI through this binary
go -C cli build -o bin/albedo ./cmd/albedo

scratch="${ALBEDO_TEST_TMP:-/tmp/albedo-tests}/gate-$$"
mkdir -p "$scratch"
trap 'rm -rf "$scratch"' EXIT
ALBEDO_TEST_DAEMON="$(test/snapshot-daemon.sh "$scratch/daemon")"
export ALBEDO_TEST_DAEMON

names=()
pids=()
log() {
  echo "$scratch/${1//[\/ ]/-}.log"
}
suite() {
  local name="$1"
  shift
  "$@" >"$(log "$name")" 2>&1 &
  names+=("$name")
  pids+=("$!")
}

suite "gleam test" gleam test
for test in test/harness/*_test.py; do
  suite "$test" python3 "$test"
done
suite "go test" go -C cli test ./internal/... ./cmd/...
# the Go e2e suite builds its own CLI and boots a hermetic daemon, so it must
# never reuse a cached run
suite "go e2e" go -C cli test -count=1 ./test/e2e
suite "python e2e" python3 test/e2e/run.py

failed=0
for i in "${!pids[@]}"; do
  if wait "${pids[$i]}"; then
    echo "ok      ${names[$i]}"
  else
    failed=1
    echo "FAILED  ${names[$i]}"
    cat "$(log "${names[$i]}")"
  fi
done
exit "$failed"
