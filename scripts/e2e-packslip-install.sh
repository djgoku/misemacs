#!/usr/bin/env bash
# scripts/e2e-packslip-install.sh <owner/repo> <tag>
# Install the release through mise with fresh data and cache directories, launch the
# app, and check per-Mach-O signatures and quarantine state on the local Mac.
set -euo pipefail

REPO="${1:?usage: e2e-packslip-install.sh <owner/repo> <tag>}"
TAG="${2:?missing tag}"
[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "FATAL: expected a Packslip SemVer tag, got $TAG"; exit 1; }
TOOL="packslip:github.com/$REPO@${TAG#v}"
export MISE_DATA_DIR; MISE_DATA_DIR="$(mktemp -d)"
export MISE_CACHE_DIR; MISE_CACHE_DIR="$(mktemp -d)"   # separate from DATA — both must be fresh (P8 gotcha)
export MISE_GLOBAL_CONFIG_FILE; MISE_GLOBAL_CONFIG_FILE="$(mktemp -d)/config.toml"
: > "$MISE_GLOBAL_CONFIG_FILE"
export MISE_YES=1
cd "$(mktemp -d)"

echo ">> [1] mise use $TOOL"
mise use "$TOOL"

echo ">> [2] --batch launch through mise (PATH from the signed Packslip bin entries)"
mise exec -- Emacs --batch --eval '(princ (format "E2E-BATCH-OK %s\n" emacs-version))'

echo ">> [3] GUI frame smoke (best-effort; requires a display session)"
if mise exec -- Emacs -Q --eval '(run-with-timer 1 nil (lambda () (kill-emacs 0)))' 2>/dev/null; then
  echo "E2E-GUI-OK"
else
  echo "E2E-GUI-SKIPPED (no display) — batch is the hard gate"
fi

INSTALL="$(mise where "$TOOL")"
echo ">> [4] per-Mach-O sentinel signatures (E7: bundle-level verify is build-time-only)"
codesign --verify --strict "$INSTALL/Emacs.app/Contents/Frameworks/libgnutls.30.dylib"
codesign --verify --strict "$INSTALL/Emacs.app/Contents/MacOS/bin/emacsclient"
echo "E2E-EMBEDDED-SIGS-OK"

echo ">> [4b] installed app path (open/~/Applications contract: latest/Emacs.app)"
[ -d "$INSTALL/Emacs.app" ] || { echo "FATAL: installed Emacs.app missing"; exit 1; }
[ -x "$INSTALL/Emacs.app/Contents/MacOS/bin/emacs-app" ] || { echo "FATAL: emacs-app launcher missing/non-executable"; exit 1; }
[ -x "$INSTALL/Emacs.app/Contents/MacOS/bin/emacs-cli" ] || { echo "FATAL: emacs-cli launcher missing/non-executable"; exit 1; }
echo "E2E-STABLE-DIR-OK"

echo ">> [5] quarantine-free install"
qcount="$(find "$INSTALL" -exec xattr -l {} + 2>/dev/null | grep -c com.apple.quarantine || true)"
[ "$qcount" = "0" ] || { echo "FATAL: $qcount quarantine xattrs in the install tree"; exit 1; }
echo "E2E-NO-QUARANTINE"

echo ">> e2e: PASS — $REPO@$TAG installs and runs with fresh mise data and cache"
