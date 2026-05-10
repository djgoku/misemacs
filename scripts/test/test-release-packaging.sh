#!/usr/bin/env bash
# test-release-packaging.sh — end-to-end test of release.sh.
# Requires build/emacs/Emacs.app to already exist (mise run validate first).
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

[ -d "build/emacs/Emacs.app" ] || {
    echo "FAIL: build/emacs/Emacs.app not found — run 'mise run validate' first"
    exit 1
}

VERSION="0.0.0-test"
OUT_DIR="build/release/${VERSION}"
ASSET_BASE="misemacs-${VERSION}-macos-arm64"
TARBALL="${OUT_DIR}/${ASSET_BASE}.tar.gz"

# --- Step 1: produce the release ---
rm -rf "$OUT_DIR"
MISEMACS_RELEASE_ALLOW_DIRTY=1 bash scripts/cli/release.sh "$VERSION" >/dev/null

[ -f "$TARBALL" ]                            || { echo "FAIL: tarball missing"; exit 1; }
[ -f "${OUT_DIR}/SHASUMS256.txt" ]           || { echo "FAIL: SHASUMS256.txt missing"; exit 1; }
[ -f "${OUT_DIR}/build-manifest.org" ]       || { echo "FAIL: build-manifest.org missing"; exit 1; }
[ -f "${OUT_DIR}/RELEASE_NOTES.md" ]         || { echo "FAIL: RELEASE_NOTES.md missing"; exit 1; }
echo "PASS: release.sh produced 4 expected files"

# --- Step 2: SHA256 verifies ---
( cd "$OUT_DIR" && shasum -a 256 -c SHASUMS256.txt >/dev/null ) \
    || { echo "FAIL: SHASUMS256.txt verification failed"; exit 1; }
echo "PASS: SHA256 verifies"

# --- Step 3: extract the tarball ---
DUMP=$(mktemp -d)
trap 'rm -rf "$DUMP" "$OUT_DIR"' EXIT

tar -xzf "$TARBALL" -C "$DUMP"
EXTRACTED_APP="$DUMP/${ASSET_BASE}/Emacs.app"
[ -d "$EXTRACTED_APP" ]                                || { echo "FAIL: extracted Emacs.app not found"; exit 1; }
[ -x "$EXTRACTED_APP/Contents/MacOS/Emacs" ]           || { echo "FAIL: extracted Emacs binary not executable"; exit 1; }
echo "PASS: tarball extracts to runnable bundle"

# --- Step 4: verify-bundle-self-contained.sh against extracted bundle ---
bash scripts/verify-bundle-self-contained.sh "$EXTRACTED_APP" \
    || { echo "FAIL: extracted bundle is not self-contained (xattr or rpath damage)"; exit 1; }
echo "PASS: extracted bundle self-contained"

# --- Step 5: moto-emacs-doctor batch against extracted bundle ---
"$EXTRACTED_APP/Contents/MacOS/Emacs" -Q -batch \
    -L "$EXTRACTED_APP/Contents/Resources/site-lisp" \
    -l moto-emacs-doctor -f moto-emacs-doctor-batch \
    || { echo "FAIL: doctor failed against extracted bundle"; exit 1; }
echo "PASS: doctor 8/8 against extracted bundle"

echo "PASS test-release-packaging.sh"
