#!/usr/bin/env bash
# doctor.sh — cross-layer invariant check.
#
# Walks each from-source pkg + the conda layer, runs each invariant check,
# prints PASS/FAIL with a remedy line. Exits non-zero on any failure.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*"; FAILED=1; }
remedy() { printf '       → %s\n' "$*"; }

FAILED=0
PKGS=(pkgs/emacs-master pkgs/emacs-mac-master libs/enchant libs/jinx-mod libs/emacs-libvterm)

# --- Per-package coherence ---
for pkg in "${PKGS[@]}"; do
    lockfile="$ROOT/$pkg/lockfile.toml"
    src="$ROOT/$pkg/src"
    sha_file="$ROOT/$pkg/src-sha.txt"

    schema=$(read_lockfile_field "$lockfile" schema_version)
    if [ "$schema" != "2" ]; then
        fail "$pkg  schema_version=$schema (expected 2)"
        remedy "run: mise run migrate-lockfiles"
        continue
    fi

    lockfile_sha=$(read_lockfile_field "$lockfile" sha)
    [ -d "$src" ] || { fail "$pkg  $src missing"; remedy "run: mise run hydrate $pkg"; continue; }
    worktree_sha=$(git -C "$src" rev-parse HEAD 2>/dev/null || echo "?")
    src_sha_txt=$([ -f "$sha_file" ] && tr -d '[:space:]' < "$sha_file" || echo "?")

    short() { printf '%.10s' "${1:-?}"; }
    if [ "$lockfile_sha" = "$worktree_sha" ] && [ "$lockfile_sha" = "$src_sha_txt" ]; then
        pass "$(printf '%-22s lockfile=%s  src=%s  src-sha.txt=%s' \
            "$pkg" "$(short "$lockfile_sha")" "$(short "$worktree_sha")" "$(short "$src_sha_txt")")"
    else
        fail "$(printf '%-22s lockfile=%s  src=%s  src-sha.txt=%s' \
            "$pkg" "$(short "$lockfile_sha")" "$(short "$worktree_sha")" "$(short "$src_sha_txt")")"
        remedy "run: mise run hydrate $pkg"
    fi
done

# --- Conda layer ---
# Check: every entry in mise.lock's conda-packages section has a corresponding
# install dir under `mise where conda:<X>`. We don't recompute sha256s (slow
# on a 29-package tree); we trust mise's own list/lock invariant.
miss=0
while IFS= read -r tool; do
    [ -n "$tool" ] || continue
    if ! mise where "conda:$tool" >/dev/null 2>&1; then
        miss=$((miss+1))
        say "  conda:$tool — not installed"
    fi
done < <(awk -F'"' '/^"conda:/ { print $2 }' "$ROOT/mise.toml" | sed 's/^conda://')

if [ "$miss" -eq 0 ]; then
    n=$(awk -F'"' '/^"conda:/ { c++ } END { print c+0 }' "$ROOT/mise.toml")
    pass "mise.lock vs installed conda envs ($n pkgs)"
else
    fail "mise.lock vs installed conda envs ($miss missing)"
    remedy "run: mise install"
fi

# --- Schema consistency ---
all_v2=1
for pkg in "${PKGS[@]}"; do
    s=$(read_lockfile_field "$ROOT/$pkg/lockfile.toml" schema_version)
    [ "$s" = "2" ] || all_v2=0
done
if [ "$all_v2" = "1" ]; then
    pass "all lockfiles schema_version=2"
else
    fail "some lockfiles still v1"
    remedy "run: mise run migrate-lockfiles"
fi

exit "$FAILED"
