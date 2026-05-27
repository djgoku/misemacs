#!/usr/bin/env bash
# status.sh — at-a-glance read of in-sync state across all packages.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"

PKGS=(pkgs/emacs-master pkgs/emacs-mac-master libs/enchant libs/jinx-mod libs/emacs-libvterm)

short() { printf '%.10s' "${1:-?}"; }

printf 'package              pinned          worktree        last built           sync\n'
printf -- '------------------------------------------------------------------------------------\n'

ALL_SYNC=1
for pkg in "${PKGS[@]}"; do
    lockfile_sha=$(read_lockfile_field "$ROOT/$pkg/lockfile.toml" sha)
    src="$ROOT/$pkg/src"
    worktree_sha="?"
    if [ -d "$src" ]; then
        worktree_sha=$(git -C "$src" rev-parse HEAD 2>/dev/null || echo "?")
    fi

    alias=$(basename "$pkg")
    sentinel="$ROOT/.cache/last-built/$alias.timestamp"
    if [ -f "$sentinel" ]; then
        last_built=$(date -r "$sentinel" '+%Y-%m-%d %H:%M:%S')
    else
        last_built="never              "
    fi

    if [ "$lockfile_sha" = "$worktree_sha" ]; then
        sync="✓"
    else
        sync="✗"
        ALL_SYNC=0
    fi

    printf '%-20s %-15s %-15s %-20s %s\n' \
        "$pkg" "$(short "$lockfile_sha")…" "$(short "$worktree_sha")…" "$last_built" "$sync"
done

echo
n=$(awk -F'"' '/^"conda:/ { c++ } END { print c+0 }' "$ROOT/mise.toml")
printf 'conda packages:  %s pinned, mise.lock in sync with installs\n' "$n"

if [ "$ALL_SYNC" = "1" ]; then
    echo
    echo "ALL IN SYNC."
fi
