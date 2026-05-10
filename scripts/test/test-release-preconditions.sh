#!/usr/bin/env bash
# test-release-preconditions.sh — verify release.sh refuses to run when
# Emacs.app missing, manifest missing, or git tree dirty (without override).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/cli/release.sh"
cd "$ROOT"

# Save and stub build/emacs/Emacs.app for tests
ORIG="$(mktemp -d)"
[ -d build/emacs ] && mv build/emacs "$ORIG/" || true
trap '[ -d "$ORIG/emacs" ] && { rm -rf build/emacs; mv "$ORIG/emacs" build/; }; rm -rf "$ORIG"' EXIT

# 1. Missing Emacs.app → exit 2
mkdir -p build/emacs
if bash "$SCRIPT" 0.0.0-test 2>/dev/null; then
    echo "FAIL: should reject missing Emacs.app"; exit 1
fi

# 2. Emacs.app present but no Contents/MacOS/Emacs → exit 2
mkdir -p build/emacs/Emacs.app/Contents/MacOS
if bash "$SCRIPT" 0.0.0-test 2>/dev/null; then
    echo "FAIL: should reject missing Emacs binary"; exit 1
fi

# 3. Binary present but not executable → exit 2
touch build/emacs/Emacs.app/Contents/MacOS/Emacs
chmod -x build/emacs/Emacs.app/Contents/MacOS/Emacs
if bash "$SCRIPT" 0.0.0-test 2>/dev/null; then
    echo "FAIL: should reject non-executable Emacs binary"; exit 1
fi

# 4. Binary executable, manifest missing → exit 2
chmod +x build/emacs/Emacs.app/Contents/MacOS/Emacs
mkdir -p build/emacs/Emacs.app/Contents/Resources
if bash "$SCRIPT" 0.0.0-test 2>/dev/null; then
    echo "FAIL: should reject missing build-manifest.org"; exit 1
fi

# 5. All file preconditions met, but git tree dirty (synthetic dirty file)
echo "stub" > build/emacs/Emacs.app/Contents/Resources/build-manifest.org
echo "dirty" > .release-test-dirty
if [ -z "${GITHUB_ACTIONS:-}" ]; then
    if bash "$SCRIPT" 0.0.0-test 2>/dev/null; then
        echo "FAIL: should reject dirty tree (no override)"; rm -f .release-test-dirty; exit 1
    fi
fi

# 6. Override env var permits dirty tree (local only) — should not fail at preconditions.
# (release.sh is currently a stub that may exit nonzero further down for other reasons;
# we only assert it gets PAST preconditions when override is set.)
out=$(MISEMACS_RELEASE_ALLOW_DIRTY=1 bash "$SCRIPT" 0.0.0-test 2>&1) || true
echo "$out" | grep -q "preconditions OK" \
    || { echo "FAIL: override should let preconditions pass; output was:"; echo "$out"; rm -f .release-test-dirty; exit 1; }
rm -f .release-test-dirty

echo "PASS test-release-preconditions.sh"
