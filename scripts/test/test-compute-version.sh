#!/usr/bin/env bash
# test-compute-version.sh — verify compute-version.sh emits VERSION=<resolved>
# correctly for: explicit input, today's date, collision suffix.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/cli/compute-version.sh"

# Run in an isolated git repo so existing tags don't pollute results.
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
cd "$SCRATCH"
git init -q
# -c commit.gpgsign=false: scratch fixture commit, no YubiKey ceremony.
# Without this, a global commit.gpgsign=true setup blocks the test on
# pinentry in CI / non-interactive runs.
git -c commit.gpgsign=false commit --allow-empty -q -m "init"

today=$(date -u +%Y.%m.%d)

# 1. Explicit valid version → echoed back.
out=$(bash "$SCRIPT" "2026.05.09")
[ "$out" = "VERSION=2026.05.09" ] || { echo "FAIL explicit valid: got '$out'"; exit 1; }

# 2. Explicit valid version with suffix.
out=$(bash "$SCRIPT" "2026.05.09.3")
[ "$out" = "VERSION=2026.05.09.3" ] || { echo "FAIL explicit suffix: got '$out'"; exit 1; }

# 3. Explicit invalid version → exit nonzero.
if bash "$SCRIPT" "v1.0.0" >/dev/null 2>&1; then
    echo "FAIL invalid: should have rejected v1.0.0"; exit 1
fi

# 4. No input, no existing tags → today's date.
out=$(bash "$SCRIPT")
[ "$out" = "VERSION=$today" ] || { echo "FAIL no-input: got '$out', expected VERSION=$today"; exit 1; }

# 5. No input, today's tag exists → today.1
git tag "$today"
out=$(bash "$SCRIPT")
[ "$out" = "VERSION=$today.1" ] || { echo "FAIL collision-1: got '$out'"; exit 1; }

# 6. No input, today and today.1 exist → today.2
git tag "$today.1"
out=$(bash "$SCRIPT")
[ "$out" = "VERSION=$today.2" ] || { echo "FAIL collision-2: got '$out'"; exit 1; }

echo "PASS test-compute-version.sh (6/6)"
