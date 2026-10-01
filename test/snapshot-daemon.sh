#!/usr/bin/env bash
# Compile the daemon and copy its code into $1 beside a launcher, then print the
# launcher's path for ALBEDO_DAEMON. Test daemons boot from the copy instead of
# `gleam run`: none of them takes the build lock, so they boot side by side and
# beside a running `gleam test`, and a rebuild during the run cannot change the
# code under a daemon that is still loading modules.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
out="$1"
(cd "$root" && gleam build) >&2
mkdir -p "$out"
for ebin in "$root"/build/dev/erlang/*/ebin; do
  package="$(dirname "$ebin")"
  name="$(basename "$package")"
  mkdir -p "$out/$name"
  cp -R "$ebin" "$out/$name/ebin"
  # priv keeps pointing at the source tree, as under `gleam run`.
  if [ -e "$package/priv" ]; then
    ln -s "$(cd "$package/priv" && pwd -P)" "$out/$name/priv"
  fi
done
cat >"$out/albedo-daemon" <<EOF
#!/bin/sh
exec erl -pa "$out"/*/ebin -eval 'albedo@@main:run(albedo)' -noshell -extra
EOF
chmod +x "$out/albedo-daemon"
echo "$out/albedo-daemon"
