#!/usr/bin/env bash
# release.sh — package build/emacs/Emacs.app for a misemacs release.
#
# Usage: release.sh <version>
#
# Produces, under build/release/<version>/:
#   misemacs-<version>-macos-arm64.tar.gz   (the bundle, deterministic gzip-tarball)
#   SHASUMS256.txt                           (sha256 of the tarball)
#   build-manifest.org                       (copy of the in-bundle manifest)
#   RELEASE_NOTES.md                         (auto-generated body for gh release)
set -euo pipefail

VERSION="${1:-}"
[ -n "$VERSION" ] || { echo "release.sh: missing version argument" >&2; exit 1; }

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

APP="build/emacs/Emacs.app"
EMACS_BIN="$APP/Contents/MacOS/Emacs"
MANIFEST="$APP/Contents/Resources/build-manifest.org"

[ -d "$APP" ]                  || { echo "release.sh: $APP not found — run 'mise run validate' first" >&2; exit 2; }
[ -x "$EMACS_BIN" ]            || { echo "release.sh: $EMACS_BIN not executable" >&2; exit 2; }
[ -f "$MANIFEST" ]             || { echo "release.sh: $MANIFEST not found" >&2; exit 2; }

# Dirty-tree gate: CI never bypasses; local opt-in via env var.
if [ -n "$(git status --porcelain)" ]; then
    if [ -n "${GITHUB_ACTIONS:-}" ] || [ -z "${MISEMACS_RELEASE_ALLOW_DIRTY:-}" ]; then
        echo "release.sh: git tree dirty; refusing to release" >&2
        echo "  (set MISEMACS_RELEASE_ALLOW_DIRTY=1 for local dry-runs)" >&2
        exit 2
    fi
fi

# Resolve host os/arch — only macos-arm64 implemented at v0.
case "$(uname -s)/$(uname -m)" in
    Darwin/arm64) ASSET_OS=macos; ASSET_ARCH=arm64 ;;
    *)            echo "release.sh: unsupported host $(uname -s)/$(uname -m); only Darwin/arm64 implemented at v0" >&2; exit 1 ;;
esac

ASSET_BASE="misemacs-${VERSION}-${ASSET_OS}-${ASSET_ARCH}"
OUT_DIR="build/release/${VERSION}"
TARBALL="${OUT_DIR}/${ASSET_BASE}.tar.gz"

mkdir -p "$OUT_DIR"

echo "release.sh: preconditions OK (version=$VERSION, asset_base=$ASSET_BASE)"

# --- Stage Emacs.app under a wrapper directory matching ASSET_BASE ---
# (aqua's {{.AssetWithoutExt}} template expects this top-level layout.)
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$STAGE/$ASSET_BASE"
# COPYFILE_DISABLE=1 prevents AppleDouble (._*) sidecar files in the copy.
COPYFILE_DISABLE=1 cp -R "$APP" "$STAGE/$ASSET_BASE/Emacs.app"

# --- Deterministic tarball with GNU tar from conda:tar ---
# GNU tar (gtar) supports --sort=name; macOS BSD tar does not.
GTAR="$(mise where conda:tar)/bin/tar"
[ -x "$GTAR" ] || { echo "release.sh: GNU tar from conda:tar not found at $GTAR" >&2; exit 1; }

# Produce the .tar uncompressed first, then gzip with -n (no embedded mtime/filename).
COPYFILE_DISABLE=1 "$GTAR" \
    --create \
    --file - \
    --directory "$STAGE" \
    --mtime=@0 \
    --sort=name \
    --owner=0 --group=0 --numeric-owner \
    --format=ustar \
    "$ASSET_BASE" \
    | gzip -n > "$TARBALL"

echo "release.sh: produced $TARBALL ($(du -h "$TARBALL" | cut -f1))"

# --- SHA256 checksums ---
# `shasum -a 256` emits two-space-separated <hash><sp><sp><filename>.
# We invoke from inside OUT_DIR so the filename is bare (no path prefix).
( cd "$OUT_DIR" && shasum -a 256 "${ASSET_BASE}.tar.gz" ) > "${OUT_DIR}/SHASUMS256.txt"
echo "release.sh: wrote ${OUT_DIR}/SHASUMS256.txt"

# --- Build manifest (verbatim copy from inside the bundle) ---
cp "$MANIFEST" "${OUT_DIR}/build-manifest.org"
echo "release.sh: copied build-manifest.org"
