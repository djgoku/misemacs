#!/usr/bin/env bash
# test-build-lib.sh — unit smoke test for scripts/build/_lib.sh helpers.
#
# Constructs a synthetic prefix tree under a tmpdir, sources _lib.sh, and
# asserts each function does the right thing. No conda env required.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Build a fake build/ tree with two prefixes: "alpha" and "beta".
mkdir -p "$TMPDIR/build/alpha/lib" "$TMPDIR/build/alpha/include" "$TMPDIR/build/alpha/bin"
mkdir -p "$TMPDIR/build/beta/lib/pkgconfig" "$TMPDIR/build/beta/share/aclocal"

# Override PREFIX_ROOT before sourcing.
PREFIX_ROOT_OVERRIDE="$TMPDIR/build"

# Source _lib.sh under a wrapper that overrides PREFIX_ROOT.
source scripts/build/_lib.sh
PREFIX_ROOT="$PREFIX_ROOT_OVERRIDE"

# --- resolve_dep_prefixes ---
out=$(resolve_dep_prefixes alpha beta)
expected="$TMPDIR/build/alpha $TMPDIR/build/beta"
[ "$out" = "$expected" ] || { echo "FAIL resolve_dep_prefixes: got [$out] want [$expected]"; exit 1; }
echo "PASS resolve_dep_prefixes"

# Missing prefix should fail.
if resolve_dep_prefixes nonexistent 2>/dev/null; then
    echo "FAIL resolve_dep_prefixes: nonexistent should have errored"; exit 1
fi
echo "PASS resolve_dep_prefixes (missing-prefix error)"

# --- tool_dep_path_export ---
PATH_BEFORE="$PATH"
unset ACLOCAL_PATH
tool_dep_path_export "$TMPDIR/build/alpha" "$TMPDIR/build/beta"
case "$PATH" in
    "$TMPDIR/build/beta/bin:$TMPDIR/build/alpha/bin:"*) ;;
    *) echo "FAIL tool_dep_path_export: PATH not extended correctly: $PATH"; exit 1 ;;
esac
echo "PASS tool_dep_path_export (PATH)"
[ "$ACLOCAL_PATH" = "$TMPDIR/build/beta/share/aclocal" ] || \
    { echo "FAIL tool_dep_path_export: ACLOCAL_PATH=[$ACLOCAL_PATH]"; exit 1; }
echo "PASS tool_dep_path_export (ACLOCAL_PATH)"
PATH="$PATH_BEFORE"

# --- dep_injection_export ---
unset CFLAGS LDFLAGS PKG_CONFIG_PATH
dep_injection_export "$TMPDIR/build/alpha" "$TMPDIR/build/beta"
[ "$CFLAGS" = "-I$TMPDIR/build/alpha/include -I$TMPDIR/build/beta/include" ] || \
    { echo "FAIL CFLAGS=[$CFLAGS]"; exit 1; }
[ "$LDFLAGS" = "-L$TMPDIR/build/alpha/lib -L$TMPDIR/build/beta/lib" ] || \
    { echo "FAIL LDFLAGS=[$LDFLAGS]"; exit 1; }
[ "$PKG_CONFIG_PATH" = "$TMPDIR/build/beta/lib/pkgconfig" ] || \
    { echo "FAIL PKG_CONFIG_PATH=[$PKG_CONFIG_PATH]"; exit 1; }
echo "PASS dep_injection_export"

# --- rpath_install_name (no dylibs — should no-op) ---
rpath_install_name "$TMPDIR/build/alpha/lib"
echo "PASS rpath_install_name (empty libdir)"

echo "PASS: test-build-lib"
