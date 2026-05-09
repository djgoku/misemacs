#!/usr/bin/env bash
# rollback.sh — restore a from-source pkg to its previous lockfile state.
#
# Usage: mise run rollback <pkg>
#
# Walks `git log` for <pkg>/lockfile.toml; reads the previous commit's
# content; calls bump.sh with the previous sha. Conda rollback is v2 —
# v1 documents `git revert + mise install` as the manual recipe.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"

[ "$#" -ge 1 ] || die "usage: mise run rollback <pkg>"
target="$1"

if [[ "$target" == conda:* ]]; then
    die "conda rollback not implemented in v1; run: git revert <commit-touching-mise-files> && mise install"
fi

pkg=$(resolve_pkg "$target")
lockfile="$pkg/lockfile.toml"

# Find the second-most-recent commit that touched the lockfile.
prev_commit=$(git -C "$ROOT" log --format=%H -- "$lockfile" | sed -n '2p')
[ -n "$prev_commit" ] || die "$pkg: no previous version on record (lockfile has only one commit)"

# Read the previous lockfile content from that commit.
prev_content=$(git -C "$ROOT" show "$prev_commit:$lockfile")
prev_sha=$(echo "$prev_content" | awk -F' *= *' '$1 == "sha" { gsub(/"/, "", $2); print $2; exit }')
[ -n "$prev_sha" ] || die "$pkg: could not parse sha from previous lockfile (commit $prev_commit)"

prev_subject=$(git -C "$ROOT" log -1 --format=%s "$prev_commit")
say "rolling back $pkg to ${prev_sha:0:10}… (from $prev_commit: $prev_subject)"
exec bash "$SCRIPT_DIR/bump.sh" "$pkg" "$prev_sha"
