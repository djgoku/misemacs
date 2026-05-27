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

flavor="emacs-mac-master"

# 1. Explicit valid calver -> <flavor>-<calver>.
out=$(bash "$SCRIPT" "$flavor" "2026.05.09")
[ "$out" = "VERSION=$flavor-2026.05.09" ] || { echo "FAIL explicit valid: got '$out'"; exit 1; }

# 2. Explicit calver with suffix.
out=$(bash "$SCRIPT" "$flavor" "2026.05.09.3")
[ "$out" = "VERSION=$flavor-2026.05.09.3" ] || { echo "FAIL explicit suffix: got '$out'"; exit 1; }

# 3. Invalid calver -> nonzero.
if bash "$SCRIPT" "$flavor" "v1.0.0" >/dev/null 2>&1; then
    echo "FAIL invalid: should have rejected v1.0.0"; exit 1
fi

# 3b. Missing flavor -> nonzero.
if bash "$SCRIPT" >/dev/null 2>&1; then
    echo "FAIL: should require a flavor"; exit 1
fi

# 4. No calver, no tags -> <flavor>-today.
out=$(bash "$SCRIPT" "$flavor")
[ "$out" = "VERSION=$flavor-$today" ] || { echo "FAIL no-input: got '$out'"; exit 1; }

# 5. <flavor>-today tag exists -> <flavor>-today.1
git tag "$flavor-$today"
out=$(bash "$SCRIPT" "$flavor")
[ "$out" = "VERSION=$flavor-$today.1" ] || { echo "FAIL collision-1: got '$out'"; exit 1; }

# 6. plus <flavor>-today.1 -> <flavor>-today.2
git tag "$flavor-$today.1"
out=$(bash "$SCRIPT" "$flavor")
[ "$out" = "VERSION=$flavor-$today.2" ] || { echo "FAIL collision-2: got '$out'"; exit 1; }

# 7. A DIFFERENT flavor's tag does not collide.
git tag "emacs-master-$today"
out=$(bash "$SCRIPT" "emacs-master")
[ "$out" = "VERSION=emacs-master-$today.1" ] || { echo "FAIL cross-flavor: got '$out'"; exit 1; }

echo "PASS test-compute-version.sh (8/8)"
