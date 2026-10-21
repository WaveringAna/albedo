#!/usr/bin/env bash
# The default profile is the commit check; review, audit and the albedo rules
# with existing findings are opt-in. albedo-lint is glinter plus tools/lint.
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
--albedo)
  profile="albedo"
  shift
  ;;
esac
if [[ -n $profile ]]; then
  scratch="$(mktemp -d)"
  project="$scratch"
  if [[ $profile == albedo ]]; then
    sed -e 's/^albedo_text_scalars = "off"/albedo_text_scalars = "error"/' \
      -e 's/^albedo_table_ownership = "off"/albedo_table_ownership = "error"/' \
      "$root/gleam.toml" >"$project/gleam.toml"
  else
    cp "$root/test/manual/$profile" "$project/gleam.toml"
  fi
  ln -s "$root/src" "$project/src"
  ln -s "$root/test" "$project/test"
fi
albedo-lint --project "$project" "$@"
