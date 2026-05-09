#!/usr/bin/env bash
# _lib.sh — shared helpers for scripts/cli/*.sh.
#
# Sourced, not executed. Provides:
#   resolve_pkg <alias-or-path>          → echoes canonical "pkgs/emacs"-style
#                                            path, or exits 1 with error.
#   read_lockfile_field <toml> <key>     → echoes "..." value or empty.
#   write_lockfile_field <toml> <key> <v>→ atomically replaces `key = "..."`
#                                            line in toml; preserves all else.
#   require_clean_worktree <pkg>         → exits 1 if <pkg>/src has dirty git
#                                            state; otherwise silent.
#   say <msg>                            → echo to stderr (consistent prefix).
#   die <msg>                            → say + exit 1.

set -euo pipefail

# --- Constants ---
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PKG_ALIASES=(
    "emacs:pkgs/emacs"
    "emacs-mac:pkgs/emacs-mac"
    "enchant:libs/enchant"
    "jinx-mod:libs/jinx-mod"
    "emacs-libvterm:libs/emacs-libvterm"
)

# --- Output ---
say() { printf 'mise: %s\n' "$*" >&2; }
die() { say "$@"; exit 1; }

# --- Package path resolution ---
resolve_pkg() {
    local input="$1"
    [ -n "$input" ] || die "resolve_pkg: empty input"

    # Try alias first.
    for entry in "${PKG_ALIASES[@]}"; do
        local alias="${entry%%:*}"
        local path="${entry##*:}"
        if [ "$input" = "$alias" ]; then
            echo "$path"; return 0
        fi
    done

    # Otherwise, normalize and verify the path exists with versions.toml.
    local norm="${input#./}"
    norm="${norm%/}"
    if [ -f "$ROOT/$norm/versions.toml" ]; then
        echo "$norm"; return 0
    fi

    die "resolve_pkg: '$input' is not a known package alias or a path with versions.toml"
}

# --- Lockfile field I/O ---
read_lockfile_field() {
    local toml="$1" key="$2"
    [ -f "$toml" ] || die "read_lockfile_field: $toml: missing"
    awk -F' *= *' -v key="$key" '$1 == key { gsub(/"/, "", $2); print $2; exit }' "$toml"
}

write_lockfile_field() {
    local toml="$1" key="$2" value="$3"
    [ -f "$toml" ] || die "write_lockfile_field: $toml: missing"
    local tmp
    tmp=$(mktemp)
    if grep -qE "^[[:space:]]*${key}[[:space:]]*=" "$toml"; then
        # Replace existing line.
        awk -v key="$key" -v val="$value" '
            $0 ~ "^[[:space:]]*"key"[[:space:]]*=" {
                printf "%s = \"%s\"\n", key, val; next
            }
            { print }
        ' "$toml" > "$tmp"
    else
        # Append.
        cat "$toml" > "$tmp"
        printf '%s = "%s"\n' "$key" "$value" >> "$tmp"
    fi
    mv "$tmp" "$toml"
}

# --- Worktree cleanliness ---
require_clean_worktree() {
    local pkg="$1"
    local worktree="$ROOT/$pkg/src"
    [ -d "$worktree" ] || die "require_clean_worktree: $pkg/src does not exist"
    local dirty
    dirty=$(git -C "$worktree" status --porcelain)
    if [ -n "$dirty" ]; then
        say "$pkg/src has uncommitted changes:"
        echo "$dirty" >&2
        die "commit or discard before continuing, or run \`mise run hydrate $pkg\` to discard"
    fi
}
