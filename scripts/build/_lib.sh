#!/usr/bin/env bash
# scripts/build/_lib.sh — shared helpers for scripts/build/<target>.sh.
#
# Sourced, not executed. Provides four bash functions that were previously
# string-template fragments in rules/helpers.bzl:
#
#   resolve_dep_prefixes <name>...    echoes space-separated absolute prefix
#                                     paths under $PREFIX_ROOT. Errors out
#                                     if any named prefix is missing.
#   tool_dep_path_export <prefix>...  prepends each <prefix>/bin to PATH;
#                                     prepends each <prefix>/share/aclocal
#                                     (if present) to ACLOCAL_PATH.
#   dep_injection_export <prefix>...  exports CFLAGS, LDFLAGS, PKG_CONFIG_PATH
#                                     from each <prefix>/{include,lib,
#                                     lib/pkgconfig}.
#   rpath_install_name <libdir>       install_name_tool -id @rpath/<base>
#                                     on every top-level .dylib in <libdir>.
#                                     Idempotent; no-op if no dylibs.
#   assert_pkg_coherence <pkg-dir>    on drift (lockfile sha != src HEAD or
#                                     != src-sha.txt), auto-runs
#                                     scripts/hydrate.sh <pkg-dir> and
#                                     re-verifies. Refuses only if hydrate
#                                     itself fails or drift persists.
#                                     Mirrors the precheck in
#                                     scripts/cli/build.sh.

set -euo pipefail

# Repo root, computed relative to THIS file (scripts/build/_lib.sh).
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PREFIX_ROOT="$ROOT/build"

resolve_dep_prefixes() {
    local out=""
    for name in "$@"; do
        local p="$PREFIX_ROOT/$name"
        if [ ! -d "$p" ]; then
            echo "_lib.sh: missing prefix: $p — run \`mise deps install $name\`" >&2
            return 1
        fi
        out="$out $(cd "$p" && pwd)"
    done
    printf '%s' "${out# }"
}

tool_dep_path_export() {
    for tp in "$@"; do
        export PATH="$tp/bin:$PATH"
        if [ -d "$tp/share/aclocal" ]; then
            ACLOCAL_PATH="$tp/share/aclocal:${ACLOCAL_PATH:-}"
        fi
    done
    export ACLOCAL_PATH="${ACLOCAL_PATH%:}"
}

dep_injection_export() {
    local cflags="" ldflags="" pcpath=""
    for dp in "$@"; do
        cflags="$cflags -I$dp/include"
        ldflags="$ldflags -L$dp/lib"
        if [ -d "$dp/lib/pkgconfig" ]; then
            pcpath="$pcpath:$dp/lib/pkgconfig"
        fi
    done
    export CFLAGS="${cflags# }" LDFLAGS="${ldflags# }" PKG_CONFIG_PATH="${pcpath#:}"
}

rpath_install_name() {
    local libdir="$1"
    [ -d "$libdir" ] || return 0
    for dylib in "$libdir"/*.dylib; do
        [ -f "$dylib" ] || continue
        install_name_tool -id "@rpath/$(basename "$dylib")" "$dylib" 2>/dev/null || true
    done
}

assert_pkg_coherence() {
    local pkg_dir="$1"
    local lockfile="$pkg_dir/lockfile.toml"
    local sha_file="$pkg_dir/src-sha.txt"
    local src="$pkg_dir/src"

    [ -f "$lockfile" ] || { echo "_lib.sh: assert_pkg_coherence: $lockfile missing" >&2; return 1; }

    local lockfile_sha worktree_sha src_sha_txt
    lockfile_sha=$(awk -F' *= *' '$1 == "sha" { gsub(/"/, "", $2); print $2; exit }' "$lockfile")

    worktree_sha=$([ -d "$src" ] && git -C "$src" rev-parse HEAD 2>/dev/null || echo "?")
    src_sha_txt=$([ -f "$sha_file" ] && tr -d '[:space:]' < "$sha_file" || echo "?")

    if [ "$lockfile_sha" = "$worktree_sha" ] && [ "$lockfile_sha" = "$src_sha_txt" ]; then
        return 0
    fi

    echo "_lib.sh: $pkg_dir: drift detected (lockfile=$lockfile_sha src=$worktree_sha sha-txt=$src_sha_txt) — auto-hydrating…" >&2
    if ! bash "$ROOT/scripts/hydrate.sh" "$pkg_dir"; then
        echo "_lib.sh: $pkg_dir: hydrate failed; refusing build" >&2
        return 1
    fi

    worktree_sha=$([ -d "$src" ] && git -C "$src" rev-parse HEAD 2>/dev/null || echo "?")
    src_sha_txt=$([ -f "$sha_file" ] && tr -d '[:space:]' < "$sha_file" || echo "?")

    if [ "$lockfile_sha" = "$worktree_sha" ] && [ "$lockfile_sha" = "$src_sha_txt" ]; then
        return 0
    fi

    echo "_lib.sh: $pkg_dir: still drifted after hydrate (lockfile=$lockfile_sha src=$worktree_sha sha-txt=$src_sha_txt); refusing" >&2
    return 1
}
