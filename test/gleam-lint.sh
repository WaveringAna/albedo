#!/usr/bin/env bash
# The default profile is the commit check; review and audit are opt-in.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
project="$root"
scratch=""
trap 'if [[ -n "$scratch" ]]; then rm -rf "$scratch"; fi' EXIT
profile=""
case "${1:-}" in
--review)
  profile="glinter-review.toml"
  shift
  ;;
--all)
  profile="glinter-all.toml"
  shift
  ;;
esac
if [[ -n $profile ]]; then
  scratch="$(mktemp -d)"
  project="$scratch"
  cp "$root/test/manual/$profile" "$project/gleam.toml"
  ln -s "$root/src" "$project/src"
  ln -s "$root/test" "$project/test"
fi
glinter --project "$project" "$@"
