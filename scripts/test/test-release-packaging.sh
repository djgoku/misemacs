#!/usr/bin/env bash
# test-release-packaging.sh — end-to-end test of release.sh.
# Requires build/<flavor>/Emacs.app to already exist (mise run build <flavor> first).
#
# Asserts:
#   1. release.sh succeeds and produces 4 expected files.
#   2. SHASUMS256.txt verifies (shasum -a 256 -c).
#   3. Tarball extraction yields a runnable Emacs.app at the expected path.
#   4. verify-bundle-self-contained.sh passes against the extracted bundle.
#   5. moto-emacs-doctor batch reports 8/8 PASS against the extracted bundle.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

FLAVORS=(emacs-master emacs-mac-master)
ran=0
for FLAVOR in "${FLAVORS[@]}"; do
    [ -d "build/$FLAVOR/Emacs.app" ] || continue
    ran=1
    VERSION="$FLAVOR-0.0.0-test"
    OUT_DIR="build/release/${VERSION}"
    ASSET_BASE="misemacs-${VERSION}-macos-arm64"
    TARBALL="${OUT_DIR}/${ASSET_BASE}.tar.gz"

    rm -rf "$OUT_DIR"
    MISEMACS_RELEASE_ALLOW_DIRTY=1 bash scripts/cli/release.sh "$FLAVOR" "$VERSION" >/dev/null
    [ -f "$TARBALL" ] && [ -f "${OUT_DIR}/SHASUMS256.txt" ] \
        && [ -f "${OUT_DIR}/build-manifest.org" ] && [ -f "${OUT_DIR}/RELEASE_NOTES.md" ] \
        || { echo "FAIL[$FLAVOR]: missing release files"; exit 1; }
    ( cd "$OUT_DIR" && shasum -a 256 -c SHASUMS256.txt >/dev/null ) \
        || { echo "FAIL[$FLAVOR]: SHASUMS256 verify"; exit 1; }

    DUMP=$(mktemp -d)
    trap 'rm -rf "$DUMP" "$OUT_DIR"' EXIT   # safety net for any unguarded set -e exit
    tar -xzf "$TARBALL" -C "$DUMP"
    APP="$DUMP/${ASSET_BASE}/Emacs.app"
    [ -x "$APP/Contents/MacOS/Emacs" ] || { echo "FAIL[$FLAVOR]: no runnable Emacs"; rm -rf "$DUMP"; exit 1; }
    bash scripts/verify-bundle-self-contained.sh "$APP" \
        || { echo "FAIL[$FLAVOR]: not self-contained"; rm -rf "$DUMP"; exit 1; }
    "$APP/Contents/MacOS/Emacs" -Q -batch -L "$APP/Contents/Resources/site-lisp" \
        -l moto-emacs-doctor -f moto-emacs-doctor-batch \
        || { echo "FAIL[$FLAVOR]: doctor"; rm -rf "$DUMP"; exit 1; }
    rm -rf "$DUMP" "$OUT_DIR"
    echo "PASS[$FLAVOR]: release packaging"
done
[ "$ran" = 1 ] || { echo "FAIL: no built flavor found — run 'mise run build <flavor>' first"; exit 1; }
echo "PASS test-release-packaging.sh"
