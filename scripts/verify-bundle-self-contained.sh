#!/usr/bin/env bash
# scripts/verify-bundle-self-contained.sh — fails if any dylib in the
# bundle has an LC_LOAD_DYLIB or LC_RPATH that resolves outside the
# bundle (excluding macOS system frameworks).
#
# Catches both classes of relocatability leak the bundler can hit:
#   1. LC_RPATH entries pointing at conda env install paths
#      (~/.local/share/mise/installs/conda-*/<ver>/lib).
#   2. LC_LOAD_DYLIB absolute paths baked into conda-built dylibs at
#      conda-forge's build time (e.g., libncurses → libtinfo from
#      conda-glib's install dir).
#
# Usage:
#   scripts/verify-bundle-self-contained.sh /path/to/Emacs.app
#
# Exits 0 if every Mach-O file in the bundle's load chain references
# only @-relative paths or system paths. Non-zero if any external
# absolute reference is found, with a diagnostic listing the offenders.

set -euo pipefail

BUNDLE="${1:?usage: $0 <Emacs.app path>}"
if [ ! -d "$BUNDLE" ]; then
    echo "verify-bundle-self-contained: not a directory: $BUNDLE" >&2
    exit 2
fi

LEAKS=""

scan_loads() {
    # otool -L output: first line is filename:, subsequent tab-prefixed
    # lines are deps (path + version annotations). Extract paths.
    local target="$1"
    otool -L "$target" 2>/dev/null \
        | awk '/^\t/ {print $1}' \
        | grep -vE '^@(rpath|loader_path|executable_path)' \
        | grep -vE '^/(System|usr/lib)' \
        | grep -vE '^[^/]' \
        || true
}

scan_rpaths() {
    local target="$1"
    otool -l "$target" 2>/dev/null \
        | awk '/LC_RPATH/{flag=1;next} flag && /path /{print $2; flag=0}' \
        | grep -vE '^@(executable_path|loader_path)' \
        || true
}

scan_file() {
    local f="$1"
    local LOADS RPATHS
    LOADS=$(scan_loads "$f")
    RPATHS=$(scan_rpaths "$f")
    if [ -n "$LOADS" ] || [ -n "$RPATHS" ]; then
        LEAKS="$LEAKS\n--- $f"
        [ -n "$LOADS" ]  && LEAKS="$LEAKS\nLC_LOAD_DYLIB:\n$LOADS"
        [ -n "$RPATHS" ] && LEAKS="$LEAKS\nLC_RPATH:\n$RPATHS"
    fi
}

# Scan all dylibs and .so files. Use -print0 / read -d '' to handle
# bundle paths that contain spaces (e.g., "My Emacs.app").
while IFS= read -r -d '' f; do
    scan_file "$f"
done < <(find "$BUNDLE" -type f \( -name "*.dylib" -o -name "*.so" \) -print0)

# Plus the Emacs binary and any non-script binaries under MacOS/.
while IFS= read -r -d '' f; do
    scan_file "$f"
done < <(find "$BUNDLE/Contents/MacOS" -type f -perm +111 ! -name "*.sh" -print0 2>/dev/null || true)

if [ -n "$LEAKS" ]; then
    printf 'FAIL: %s contains external (non-@*, non-system) Mach-O references:\n' "$BUNDLE" >&2
    printf '%b\n' "$LEAKS" >&2
    exit 1
fi

printf 'PASS: %s — every LC_LOAD_DYLIB and LC_RPATH resolves either @-relative or under /System or /usr/lib\n' "$BUNDLE"
