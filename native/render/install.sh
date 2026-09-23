#!/usr/bin/env bash
# Build albedo-render into priv/bin, where the files plugin looks for it.
set -euo pipefail
cd "$(dirname "$0")"
cargo build --release --locked
mkdir -p ../../priv/bin
install -m 755 target/release/albedo-render ../../priv/bin/albedo-render
