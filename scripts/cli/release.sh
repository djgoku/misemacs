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
# subsequent steps (tarball, checksums, notes) added in later tasks
