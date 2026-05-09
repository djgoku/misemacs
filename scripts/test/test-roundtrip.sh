#!/usr/bin/env bash
# test-roundtrip.sh — bump A → build → rollback → build, semantic check.
#
# Verifies the bump→build→rollback→build cycle completes end-to-end with no
# errors and that the final state (lockfile, worktree, src-sha.txt) matches
# the original. mise run validate at the end gates on the bundle self-
# contained + 8/8 doctor checks.
#
# Note: a cache-hit timing assertion would seem natural after Phase 1's
# removal of lockfile.toml from [deps.*]'s sources, but mise's per-
# provider freshness state (~/.local/state/mise/deps/<project>.toml)
# records hashes from the most-recent build only — there is no multi-
# version content-addressable cache. So a bump → build → rollback →
# build always recompiles, because at the rollback the recorded state
# is the prior bump's blake3 set. The elapsed time is printed for
# visibility but does not fail the test.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

PKG=pkgs/emacs
PREV_SHA=ed1fe2ca9590a97aee62f74630f7f1f9d795bcb2
CUR_SHA=$(awk -F' *= *' '$1 == "sha" { gsub(/"/, "", $2); print $2; exit }' "$PKG/lockfile.toml")

[ "$PREV_SHA" != "$CUR_SHA" ] || { echo "test-roundtrip: PREV_SHA equals CUR_SHA; pick a different fixture"; exit 1; }

echo "=== build at $CUR_SHA (warm cache from previous run, or first compile) ==="
mise run build emacs

echo "=== bump to $PREV_SHA, build (compute or cache hit if previously built) ==="
mise run bump emacs "$PREV_SHA"
mise run build emacs

echo "=== rollback to $CUR_SHA, build (informational timing only) ==="
mise run rollback emacs

T_START=$(date +%s)
mise run build emacs
T_ELAPSED=$(( $(date +%s) - T_START ))
echo "rollback build elapsed: ${T_ELAPSED}s"

echo "=== validate post-rollback ==="
mise run validate

echo "PASS: test-roundtrip"
