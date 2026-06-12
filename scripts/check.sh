#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

echo "==> zig build test"
zig build test

echo "==> zig build run -- help"
zig build run -- help >/dev/null

echo "==> scripts/smoke-fake-remote.sh"
scripts/smoke-fake-remote.sh

echo "==> git diff --check"
git diff --check

echo "==> public function comment check"
missing="$(
  find src -name '*.zig' -print | sort | xargs awk 'BEGIN{prev=""} /^[[:space:]]*pub fn / { if (prev !~ /^[[:space:]]*\/\//) print FILENAME ":" FNR ":" $0 } {prev=$0}'
)"
if [[ -n "$missing" ]]; then
  printf '%s\n' "$missing"
  exit 1
fi

echo "all checks passed"
