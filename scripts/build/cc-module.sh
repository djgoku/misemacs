#!/usr/bin/env bash
# scripts/build/cc-module.sh — port of rules/cc_module.bzl.
#
# Usage: bash scripts/build/cc-module.sh <pkg-dir>
#
# Compiles a single Emacs dynamic module (.so) from C sources, with optional
# static-archive linking and pkg-config integration.
#
# <pkg-dir> contents (relative to repo root):
#   build.toml         Build metadata; see fields below.
#   lockfile.toml      schema_version = 2 (read for src_sha provenance only).
#   src/               Hydrated source tree.
#   <extra-srcs>       Optional: companion .c/.h files outside src/, named
#                      relative to <pkg-dir> (not src/).
#
# build.toml fields:
#   module_name = "<basename>"            (required; produces lib/<basename>.so)
#   module_srcs = ["a.c", "b.c", ...]     (required; basenames in src/, plus any
#                                            extra_srcs basenames)
#   extra_srcs = ["relocate-init.c", ...] (optional; paths relative to <pkg-dir>;
#                                            each gets cp'd into the staged src/)
#   data_files = ["jinx.el", ...]         (optional; basenames in src/; copied
#                                            to <out>/share/<module>/)
#   cflags = ["-O2", "-Wall", ...]        (passed verbatim to cc)
#   link_libs = ["vterm", ...]            (optional; produces -l<name>)
#   pkg_config_modules = ["enchant-2",..] (optional; cflags + libs from pkg-config)
#   static_lib_deps = ["enchant", ...]    (optional; string names — resolved to
#                                            build/<name>/lib/lib<basename>.a
#                                            via parallel static_lib_names list)
#   static_lib_names = ["enchant-2", ...] (parallel to static_lib_deps)
#   lib_deps = ["enchant", "conda-glib"]  (CFLAGS/LDFLAGS/PKG_CONFIG_PATH from build/<name>/)
#   tool_deps = ["conda-pkg-config"]      (PATH/ACLOCAL_PATH from build/<name>/)
#
# Output:
#   build/<basename(pkg-dir)>/lib/<module_name>.so
#   build/<basename(pkg-dir)>/share/<module_name>/<data_files...>   (if any)
# Atomic — the script writes to a tmpdir and `mv`s into place.

set -euo pipefail

PKG_DIR_ARG="${1:?usage: cc-module.sh <pkg-dir>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/_lib.sh"
PREFIX_ROOT="$ROOT/build"

PKG_DIR="$ROOT/${PKG_DIR_ARG#./}"
PKG_DIR="${PKG_DIR%/}"
PKG_NAME="$(basename "$PKG_DIR")"
OUT="$PREFIX_ROOT/$PKG_NAME"

[ -f "$PKG_DIR/build.toml" ] || { echo "cc-module.sh: $PKG_DIR/build.toml missing" >&2; exit 1; }
[ -d "$PKG_DIR/src" ]        || { echo "cc-module.sh: $PKG_DIR/src missing — run \`mise run hydrate $PKG_DIR_ARG\`" >&2; exit 1; }
assert_pkg_coherence "$PKG_DIR"

# --- TOML field readers (same shape as autotools.sh) ---
get_field() {
    awk -F' *= *' -v key="$2" '$1 == key { gsub(/"/, "", $2); print $2; exit }' "$1"
}
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
MODULE_NAME=$(get_field "$PKG_DIR/build.toml" module_name)
[ -n "$MODULE_NAME" ] || { echo "cc-module.sh: build.toml: module_name is required" >&2; exit 1; }

MODULE_SRCS=()
while IFS= read -r s; do MODULE_SRCS+=("$s"); done < <(get_list "$PKG_DIR/build.toml" module_srcs)
[ "${#MODULE_SRCS[@]}" -gt 0 ] || { echo "cc-module.sh: build.toml: module_srcs is required and non-empty" >&2; exit 1; }

EXTRA_SRCS=()
while IFS= read -r s; do EXTRA_SRCS+=("$s"); done < <(get_list "$PKG_DIR/build.toml" extra_srcs)

DATA_FILES=()
while IFS= read -r s; do DATA_FILES+=("$s"); done < <(get_list "$PKG_DIR/build.toml" data_files)

CFLAGS_RAW=()
while IFS= read -r s; do CFLAGS_RAW+=("$s"); done < <(get_list "$PKG_DIR/build.toml" cflags)

LINK_LIBS=()
while IFS= read -r s; do LINK_LIBS+=("$s"); done < <(get_list "$PKG_DIR/build.toml" link_libs)

PC_MODULES=()
while IFS= read -r s; do PC_MODULES+=("$s"); done < <(get_list "$PKG_DIR/build.toml" pkg_config_modules)

STATIC_LIB_DEPS=()
while IFS= read -r s; do STATIC_LIB_DEPS+=("$s"); done < <(get_list "$PKG_DIR/build.toml" static_lib_deps)
STATIC_LIB_NAMES=()
while IFS= read -r s; do STATIC_LIB_NAMES+=("$s"); done < <(get_list "$PKG_DIR/build.toml" static_lib_names)
[ "${#STATIC_LIB_DEPS[@]}" -eq "${#STATIC_LIB_NAMES[@]}" ] || {
    echo "cc-module.sh: static_lib_deps (${#STATIC_LIB_DEPS[@]}) and static_lib_names (${#STATIC_LIB_NAMES[@]}) must be the same length" >&2
    exit 1
}

LIB_DEPS=()
while IFS= read -r d; do LIB_DEPS+=("$d"); done < <(get_list "$PKG_DIR/build.toml" lib_deps)
TOOL_DEPS=()
while IFS= read -r d; do TOOL_DEPS+=("$d"); done < <(get_list "$PKG_DIR/build.toml" tool_deps)

# --- Resolve dep prefixes ---
LIB_PREFIXES=""
[ "${#LIB_DEPS[@]}" -gt 0 ] && LIB_PREFIXES=$(resolve_dep_prefixes "${LIB_DEPS[@]}")
TOOL_PREFIXES=""
[ "${#TOOL_DEPS[@]}" -gt 0 ] && TOOL_PREFIXES=$(resolve_dep_prefixes "${TOOL_DEPS[@]}")

# --- Resolve extra_srcs (paths relative to <pkg-dir>) ---
EXTRA_SRC_PATHS=()
for f in ${EXTRA_SRCS[@]+"${EXTRA_SRCS[@]}"}; do
    abs="$PKG_DIR/$f"
    [ -f "$abs" ] || { echo "cc-module.sh: extra_src $abs missing" >&2; exit 1; }
    EXTRA_SRC_PATHS+=("$abs")
done

# --- Resolve static archives ---
STATIC_ARCHIVES=()
STATIC_NAMES_FLAT=""
for i in ${STATIC_LIB_DEPS[@]+"${!STATIC_LIB_DEPS[@]}"}; do
    sp="$PREFIX_ROOT/${STATIC_LIB_DEPS[$i]}"
    [ -d "$sp" ] || { echo "cc-module.sh: missing static lib prefix $sp — run \`mise deps install ${STATIC_LIB_DEPS[$i]}\`" >&2; exit 1; }
    sp="$(cd "$sp" && pwd)"
    archive="$sp/lib/lib${STATIC_LIB_NAMES[$i]}.a"
    [ -f "$archive" ] || { echo "cc-module.sh: missing static archive $archive" >&2; exit 1; }
    STATIC_ARCHIVES+=("$archive")
    STATIC_NAMES_FLAT="$STATIC_NAMES_FLAT ${STATIC_LIB_NAMES[$i]}"
done

# --- Stage source ---
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
cp -R "$PKG_DIR/src" "$TMPDIR/src"
for abs in ${EXTRA_SRC_PATHS[@]+"${EXTRA_SRC_PATHS[@]}"}; do
    cp "$abs" "$TMPDIR/src/"
done
cd "$TMPDIR/src"

# --- Inject env from dep prefixes ---
# shellcheck disable=SC2086
tool_dep_path_export $TOOL_PREFIXES
# shellcheck disable=SC2086
dep_injection_export $LIB_PREFIXES

# --- pkg-config integration ---
PC_CFLAGS=""
PC_LIBS=""
if [ "${#PC_MODULES[@]}" -gt 0 ]; then
    PC_CFLAGS=$(pkg-config --cflags "${PC_MODULES[@]}")
    PC_LIBS=$(pkg-config --libs --static "${PC_MODULES[@]}")
    # Strip -l flags whose lib basename matches a static_lib_name. The
    # static archive is appended explicitly later; without stripping, the
    # linker would prefer the matching .dylib found via -L<dep_prefix>/lib
    # and the resulting .so would runtime-link against @rpath/<lib>.dylib,
    # defeating the static-link purpose.
    for sn in $STATIC_NAMES_FLAT; do
        PC_LIBS=$(printf '%s' "$PC_LIBS" | sed -E "s/(^| )-l${sn}( |$)/ /g")
    done
fi

# --- Build link flags from link_libs ---
LINK_FLAGS=""
for lib in ${LINK_LIBS[@]+"${LINK_LIBS[@]}"}; do
    LINK_FLAGS="$LINK_FLAGS -l$lib"
done

# --- Compile to .so in a staging dir; mv into place atomically ---
STAGE=$(mktemp -d)
mkdir -p "$STAGE/lib"

# Link order (from cc_module.bzl):
# object/sources first, then explicit static archives (so the linker pulls
# only referenced .o objects from each .a), then -l flags (link_libs +
# pkg-config-derived) which supply transitive symbols referenced by the
# just-pulled archive members.
# shellcheck disable=SC2086
cc -shared -fPIC ${CFLAGS_RAW[*]+${CFLAGS_RAW[*]}} -I. $CFLAGS $PC_CFLAGS $LDFLAGS \
    "${MODULE_SRCS[@]}" \
    ${STATIC_ARCHIVES[@]+"${STATIC_ARCHIVES[@]}"} \
    $LINK_FLAGS $PC_LIBS \
    -o "$STAGE/lib/$MODULE_NAME.so"

# --- Data files ---
if [ "${#DATA_FILES[@]}" -gt 0 ]; then
    mkdir -p "$STAGE/share/$MODULE_NAME"
    for f in "${DATA_FILES[@]}"; do
        cp "$f" "$STAGE/share/$MODULE_NAME/"
    done
fi

# --- Atomic install ---
mkdir -p "$PREFIX_ROOT"
rm -rf "$OUT"
mv "$STAGE" "$OUT"
