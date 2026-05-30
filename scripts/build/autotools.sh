#!/usr/bin/env bash
# scripts/build/autotools.sh — port of rules/autotools.bzl (from-git mode).
#
# Usage: bash scripts/build/autotools.sh <pkg-dir>
#
# <pkg-dir> contents (relative to repo root):
#   build.toml         Build metadata; see fields below.
#   lockfile.toml      sha = "..." (used as VERSION).
#   src/               Hydrated git worktree pinned at the recorded sha.
#   <pre-autogen.sh>   Optional companion script (named in build.toml).
#   <bootstrap.sh>     Optional companion script.
#   <post-install.sh>  Optional companion script (rare).
#
# build.toml fields:
#   linkage = "static" | "shared" | "both"        (required)
#   configure_args = ["--foo", "--bar=...", ...]  (passed verbatim after the linkage flags)
#   lib_deps = ["conda-glib", "enchant", ...]     (resolved to build/<name>/, contributes
#                                                   to CFLAGS/LDFLAGS/PKG_CONFIG_PATH)
#   tool_deps = ["conda-pkg-config", ...]         (resolved to build/<name>/, contributes
#                                                   to PATH and ACLOCAL_PATH)
#   pre_autogen_script = "pre-autogen.sh"         (optional; runs before autogen)
#   bootstrap_script = "bootstrap.sh"             (optional; runs after autogen)
#   post_install_script = "post-install.sh"       (optional; runs after `make install`,
#                                                   passed the staging prefix as $1)
#
# Output:
#   build/<basename(pkg-dir)>/{bin,include,lib,share,...}/
#     The install prefix. Atomic — the script writes to a tmpdir and `mv`s into place.

set -euo pipefail

PKG_DIR_ARG="${1:?usage: autotools.sh <pkg-dir>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/_lib.sh"
PREFIX_ROOT="$ROOT/build"

PKG_DIR="$ROOT/${PKG_DIR_ARG#./}"
PKG_DIR="${PKG_DIR%/}"
PKG_NAME="$(basename "$PKG_DIR")"
OUT="$PREFIX_ROOT/$PKG_NAME"

[ -f "$PKG_DIR/build.toml" ]    || { echo "autotools.sh: $PKG_DIR/build.toml missing" >&2; exit 1; }
[ -f "$PKG_DIR/lockfile.toml" ] || { echo "autotools.sh: $PKG_DIR/lockfile.toml missing" >&2; exit 1; }
[ -d "$PKG_DIR/src" ]           || { echo "autotools.sh: $PKG_DIR/src missing — run \`mise run hydrate $PKG_DIR_ARG\`" >&2; exit 1; }
assert_pkg_coherence "$PKG_DIR"

# --- TOML field readers ---
# get_field <toml-path> <key>  → echoes the value (stripped of quotes), or empty.
get_field() {
    awk -F' *= *' -v key="$2" '$1 == key { gsub(/"/, "", $2); print $2; exit }' "$1"
}
# get_list <toml-path> <key>  → echoes one entry per line for `key = ["a", "b", ...]`
# or a multiline `key = [\n  "a",\n  "b",\n]` form. Empty if the key is missing or empty.
get_list() {
    awk -v key="$2" '
        $0 ~ "^[[:space:]]*"key"[[:space:]]*=[[:space:]]*\\[" {
            in_arr = 1
            sub(/.*\[/, "")
        }
        in_arr {
            line = $0
            while (match(line, /"[^"]*"/)) {
                s = substr(line, RSTART + 1, RLENGTH - 2)
                if (s != "") print s
                line = substr(line, RSTART + RLENGTH)
            }
            if (index($0, "]")) in_arr = 0
        }
    ' "$1"
}

# --- Read build.toml ---
LINKAGE=$(get_field "$PKG_DIR/build.toml" linkage)
[ -n "$LINKAGE" ] || { echo "autotools.sh: build.toml: linkage is required" >&2; exit 1; }

CONFIGURE_ARGS=()
while IFS= read -r a; do CONFIGURE_ARGS+=("$a"); done < <(get_list "$PKG_DIR/build.toml" configure_args)

LIB_DEPS=()
while IFS= read -r d; do LIB_DEPS+=("$d"); done < <(get_list "$PKG_DIR/build.toml" lib_deps)
TOOL_DEPS=()
while IFS= read -r d; do TOOL_DEPS+=("$d"); done < <(get_list "$PKG_DIR/build.toml" tool_deps)

PRE_AUTOGEN_SCRIPT=$(get_field "$PKG_DIR/build.toml" pre_autogen_script)
BOOTSTRAP_SCRIPT=$(get_field "$PKG_DIR/build.toml" bootstrap_script)
POST_INSTALL_SCRIPT=$(get_field "$PKG_DIR/build.toml" post_install_script)

# --- Linkage flags (before configure_args, matching helpers.bzl's linkage_configure_flags) ---
case "$LINKAGE" in
    static) LINKAGE_FLAGS=(--disable-shared --enable-static) ;;
    shared) LINKAGE_FLAGS=(--disable-static --enable-shared) ;;
    both)   LINKAGE_FLAGS=(--enable-shared --enable-static) ;;
    *)      echo "autotools.sh: invalid linkage '$LINKAGE' (expected static|shared|both)" >&2; exit 1 ;;
esac

# --- Read VERSION from lockfile.toml ---
VERSION=$(get_field "$PKG_DIR/lockfile.toml" sha)
[ -n "$VERSION" ] || { echo "autotools.sh: failed to parse sha from $PKG_DIR/lockfile.toml" >&2; exit 1; }

# --- Resolve dep prefixes (errors if any are missing) ---
LIB_PREFIXES=""
[ "${#LIB_DEPS[@]}" -gt 0 ] && LIB_PREFIXES=$(resolve_dep_prefixes "${LIB_DEPS[@]}")
TOOL_PREFIXES=""
[ "${#TOOL_DEPS[@]}" -gt 0 ] && TOOL_PREFIXES=$(resolve_dep_prefixes "${TOOL_DEPS[@]}")

# --- Stage source into a tmpdir (preserve worktree as side-effect-free) ---
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
cp -R "$PKG_DIR/src" "$TMPDIR/src"
SRCDIR="$TMPDIR/src"

# Write VERSION markers so configure --version-script pickups (gnulib's
# .tarball-version / .version) embed the recorded sha.
printf '%s\n' "$VERSION" > "$SRCDIR/.tarball-version"
printf '%s\n' "$VERSION" > "$SRCDIR/.version"
export VERSION

# --- Inject env from dep prefixes ---
# shellcheck disable=SC2086
tool_dep_path_export $TOOL_PREFIXES
# shellcheck disable=SC2086
dep_injection_export $LIB_PREFIXES

cd "$SRCDIR"

# --- Pre-autogen companion script ---
# Sourced (not run as subprocess) so its `export FOO=...` calls and PATH
# changes propagate into the autogen + make steps that follow. The original
# rules/autotools.bzl inlined this fragment into a single bash invocation,
# which had the same effect.
if [ -n "$PRE_AUTOGEN_SCRIPT" ]; then
    [ -f "$PKG_DIR/$PRE_AUTOGEN_SCRIPT" ] || { echo "autotools.sh: $PKG_DIR/$PRE_AUTOGEN_SCRIPT missing" >&2; exit 1; }
    # shellcheck disable=SC1090
    source "$PKG_DIR/$PRE_AUTOGEN_SCRIPT"
fi

# --- Autogen dispatch chain (matches autotools.bzl's order) ---
if [ -f ./autogen.sh ]; then
    ./autogen.sh
elif [ -x ./bootstrap ]; then
    ./bootstrap
elif [ -f ./configure.ac ] || [ -f ./configure.in ]; then
    autoreconf -fi
fi

# --- Bootstrap companion script (post-autogen patches/shims) ---
# Also sourced — bootstrap.sh typically prepends a shim dir to PATH (e.g.,
# enchant's groff shim) which must persist through make.
if [ -n "$BOOTSTRAP_SCRIPT" ]; then
    [ -f "$PKG_DIR/$BOOTSTRAP_SCRIPT" ] || { echo "autotools.sh: $PKG_DIR/$BOOTSTRAP_SCRIPT missing" >&2; exit 1; }
    # shellcheck disable=SC1090
    source "$PKG_DIR/$BOOTSTRAP_SCRIPT"
fi

# --- configure with --prefix=$OUT, install with DESTDIR=$STAGE ---
# Bake the final $OUT path into Makefiles, .pc.in expansion, etc. so
# pkg-config consumers later see correct -I/-L flags. DESTDIR redirects
# the actual file copies to $STAGE/$OUT/, leaving us free to atomically
# `mv` into place. Without DESTDIR we'd have to either (a) build
# directly into $OUT and risk partial state on failure, or (b) sed-fix
# every absolute path baked into .pc/.la files post-install.
STAGE=$(mktemp -d)
./configure --prefix="$OUT" "${LINKAGE_FLAGS[@]}" "${CONFIGURE_ARGS[@]}"
make -j"$(sysctl -n hw.ncpu)"
make install DESTDIR="$STAGE"

# After DESTDIR install, the staged tree lives at $STAGE/$OUT/. Pull that
# subtree out into $STAGED_PREFIX and operate on it directly.
STAGED_PREFIX="$STAGE$OUT"
[ -d "$STAGED_PREFIX" ] || { echo "autotools.sh: expected $STAGED_PREFIX to exist after make install DESTDIR=$STAGE" >&2; exit 1; }

# Strip libtool archives — they embed absolute paths that would poison
# downstream libtool consumers. Modern flows rely on pkg-config.
rm -f "$STAGED_PREFIX/lib"/*.la 2>/dev/null || true

# --- Post-install companion script (rare; receives the staged prefix as $1) ---
if [ -n "$POST_INSTALL_SCRIPT" ]; then
    [ -f "$PKG_DIR/$POST_INSTALL_SCRIPT" ] || { echo "autotools.sh: $PKG_DIR/$POST_INSTALL_SCRIPT missing" >&2; exit 1; }
    bash "$PKG_DIR/$POST_INSTALL_SCRIPT" "$STAGED_PREFIX"
fi

# --- Make top-level dylibs relocatable ---
rpath_install_name "$STAGED_PREFIX/lib"

# --- Atomic install: replace any prior $OUT with the freshly built tree ---
mkdir -p "$PREFIX_ROOT"
rm -rf "$OUT"
mv "$STAGED_PREFIX" "$OUT"
