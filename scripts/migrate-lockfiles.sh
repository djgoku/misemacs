#!/usr/bin/env bash
# migrate-lockfiles.sh — one-shot v1 → v2 lockfile migration.
#
# v1 shape: schema_version = 1; current = "key"; [versions."key"] sha = "..."
# v2 shape: schema_version = 2; sha = "..."
#
# Idempotent: a v2 lockfile is left unchanged.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

migrate_one() {
    local lockfile="$1"
    [ -f "$lockfile" ] || { echo "migrate: $lockfile: missing"; return 0; }

    local schema
    schema=$(awk -F' *= *' '$1 == "schema_version" { gsub(/"/, "", $2); print $2; exit }' "$lockfile")
    if [ "$schema" = "2" ]; then
        echo "migrate: $lockfile: already v2, skipping"
        return 0
    fi

    local current
    current=$(awk -F' *= *' '$1 == "current" { gsub(/"/, "", $2); print $2; exit }' "$lockfile")
    if [ -z "$current" ]; then
        echo "migrate: $lockfile: no 'current' field — not a v1 lockfile?" >&2
        return 1
    fi

    local sha
    sha=$(awk -v want="$current" '
        /^\[versions\./ { in_section = ($0 ~ "\""want"\"\\]$") }
        in_section && /^sha[[:space:]]*=/ {
            if (match($0, /"[^"]*"/)) { print substr($0, RSTART+1, RLENGTH-2); exit }
        }
    ' "$lockfile")
    if [ -z "$sha" ]; then
        echo "migrate: $lockfile: no sha for version '$current'" >&2
        return 1
    fi

    cat > "$lockfile" <<EOF
schema_version = 2
sha = "$sha"
EOF
    echo "migrate: $lockfile: rewritten to v2 (sha=$sha)"
}

for pkg in pkgs/emacs-master pkgs/emacs-mac-master libs/enchant libs/jinx-mod libs/emacs-libvterm; do
    migrate_one "$pkg/lockfile.toml"
done

echo "migrate: done"
