#!/usr/bin/env bash
# Every check that must pass before a commit.
#
# The daemon tests start a daemon with `gleam run`, so they stay outside
# `gleam test`: a nested build would wait on the build lock this suite holds.
# test/manual is opt-in and not run here; those harnesses need a provider,
# a PTY, or artifacts from an earlier benchmark run.
set -euo pipefail
cd "$(dirname "$0")"

gleam format --check src test
gleam test

[ -d cli/node_modules ] || npm --prefix cli install
npm --prefix cli run typecheck
npm --prefix cli test

python3 test/daemon/integration.py
python3 test/daemon/kernel_reset_integration.py
python3 test/daemon/idle_reap_integration.py
