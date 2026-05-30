#!/usr/bin/env bash
# build.sh — self-healing precheck + mise deps install dispatch.
#
# Usage: mise run build [target]
#   target := emacs-master (default) | emacs-mac-master | enchant | jinx-mod | emacs-libvterm
#
# The precheck is a stripped-down doctor: exits at first failure with a
# `→ run X` hint. On success, invokes `mise deps install <provider>`
# and writes a sentinel for `mise run status`'s "last built" column.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"

# --- Resolve target ---
target="${1:-emacs-master}"
case "$target" in
    emacs-master)       dep_name="pkgs-emacs-master" ;;
    emacs-mac-master)   dep_name="pkgs-emacs-mac-master" ;;
    enchant)            dep_name="libs-enchant" ;;
    jinx-mod)           dep_name="libs-jinx-mod" ;;
    emacs-libvterm)     dep_name="libs-emacs-libvterm" ;;
    *)                  die "unknown target '$target'; expected one of: emacs-master, emacs-mac-master, enchant, jinx-mod, emacs-libvterm" ;;
esac

# --- Precheck (first-failure exit) ---
PKGS=(pkgs/emacs-master pkgs/emacs-mac-master libs/enchant libs/jinx-mod libs/emacs-libvterm)

precheck_fail() {
    say "mise run build: precheck failed."
    say "  $1"
    say ""
    say "→ run: $2"
    exit 1
}

# 1. Per-pkg coherence: lockfile sha == git src HEAD == src-sha.txt.
#    On drift, auto-hydrate and re-verify.
for pkg in "${PKGS[@]}"; do
    lockfile_sha=$(read_lockfile_field "$ROOT/$pkg/lockfile.toml" sha)
    src="$ROOT/$pkg/src"
    worktree_sha=$([ -d "$src" ] && git -C "$src" rev-parse HEAD 2>/dev/null || echo "?")
    src_sha_txt=$([ -f "$ROOT/$pkg/src-sha.txt" ] && tr -d '[:space:]' < "$ROOT/$pkg/src-sha.txt" || echo "?")
    if [ "$lockfile_sha" != "$worktree_sha" ] || [ "$lockfile_sha" != "$src_sha_txt" ]; then
        say "mise run build: $pkg: drift (lockfile=$lockfile_sha src=$worktree_sha sha-txt=$src_sha_txt) — auto-hydrating …"
        bash "$ROOT/scripts/hydrate.sh" "$pkg" || precheck_fail "$pkg: hydrate failed" "investigate $pkg/src + lockfile"
        worktree_sha=$([ -d "$src" ] && git -C "$src" rev-parse HEAD 2>/dev/null || echo "?")
        src_sha_txt=$([ -f "$ROOT/$pkg/src-sha.txt" ] && tr -d '[:space:]' < "$ROOT/$pkg/src-sha.txt" || echo "?")
        if [ "$lockfile_sha" != "$worktree_sha" ] || [ "$lockfile_sha" != "$src_sha_txt" ]; then
            precheck_fail "$pkg: still drifted after hydrate (lockfile=$lockfile_sha src=$worktree_sha sha-txt=$src_sha_txt)" "manually run scripts/hydrate.sh $pkg and inspect output"
        fi
    fi
done

# 2. Conda layer presence.
while IFS= read -r tool; do
    [ -n "$tool" ] || continue
    mise where "conda:$tool" >/dev/null 2>&1 || \
        precheck_fail "conda:$tool: not installed" "mise install"
done < <(awk -F'"' '/^"conda:/ { print $2 }' "$ROOT/mise.toml" | sed 's/^conda://')

# --- Build ---
# pkgs-emacs-master / pkgs-emacs-mac-master depend on the libs-* providers, which are
# auto=false. `mise deps install <X>` runs X plus its auto=true (conda-*)
# deps, but does NOT cascade through auto=false depends — so on a clean
# build/ the libs never build and the emacs compile dies on a missing
# build/enchant. Build the shared libs explicitly before the selected pkg
# (naming one flavor's pkg avoids building the other); content-addressed
# freshness skips libs that are already current.
case "$target" in
    emacs-master|emacs-mac-master)
        for lib in libs-enchant libs-jinx-mod libs-emacs-libvterm; do
            mise deps install "$lib"
        done
        mise deps install "$dep_name"
        ;;
    *)
        mise deps install "$dep_name"
        ;;
esac

# --- Sentinel for `mise run status` "last built" ---
mkdir -p "$ROOT/.cache/last-built"
touch "$ROOT/.cache/last-built/$target.timestamp"
