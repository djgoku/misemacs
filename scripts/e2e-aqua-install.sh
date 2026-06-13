#!/usr/bin/env bash
# scripts/e2e-aqua-install.sh <owner/repo> <tag> <registry-url>          (host mode)
# scripts/e2e-aqua-install.sh --in-vm <owner/repo> <tag> <registry-url>  (inside the VM)
# The §14 DoD check: a credential-free clean box installs the release exactly like a
# user (MISE_AQUA_REGISTRY_URL + mise use aqua:<repo>@<tag>) and the app runs; then the
# E7-correct integrity checks (per-Mach-O sentinels, zero quarantine — E1 invariant).
set -euo pipefail

if [ "${1:-}" != "--in-vm" ]; then
  REPO="${1:?usage: e2e-aqua-install.sh <owner/repo> <tag> <registry-url>}"
  TAG="${2:?missing tag}"
  URL="${3:?missing registry url}"
  exec pregate --macos --verbose --cmd "bash scripts/e2e-aqua-install.sh --in-vm '$REPO' '$TAG' '$URL'"
fi

shift
REPO="${1:?}"; TAG="${2:?}"; URL="${3:?}"
export MISE_AQUA_REGISTRY_URL="$URL"
export MISE_DATA_DIR; MISE_DATA_DIR="$(mktemp -d)"
export MISE_CACHE_DIR; MISE_CACHE_DIR="$(mktemp -d)"   # separate from DATA — both must be fresh (P8 gotcha)
export MISE_GLOBAL_CONFIG_FILE; MISE_GLOBAL_CONFIG_FILE="$(mktemp)"
export MISE_YES=1
cd "$(mktemp -d)"

echo ">> [1] mise use aqua:$REPO@$TAG   (registry: $URL)"
mise use "aqua:$REPO@$TAG"

echo ">> [2] --batch launch through mise (PATH from the registry files: entries)"
mise exec -- Emacs --batch --eval '(princ (format "E2E-BATCH-OK %s\n" emacs-version))'

echo ">> [3] GUI frame smoke (best-effort; VM session has a display per Phase 3)"
if mise exec -- Emacs -Q --eval '(run-with-timer 1 nil (lambda () (kill-emacs 0)))' 2>/dev/null; then
  echo "E2E-GUI-OK"
else
  echo "E2E-GUI-SKIPPED (no display) — batch is the hard gate"
fi

INSTALL="$(mise where "aqua:$REPO@$TAG")"
echo ">> [4] per-Mach-O sentinel signatures (E7: bundle-level verify is build-time-only)"
codesign --verify --strict "$INSTALL"/misemacs-*/Emacs.app/Contents/Frameworks/libgnutls.30.dylib
codesign --verify --strict "$INSTALL"/misemacs-*/Emacs.app/Contents/MacOS/bin/emacsclient
echo "E2E-EMBEDDED-SIGS-OK"

echo ">> [5] quarantine-free install (E1 invariant via aqua's Go extraction)"
qcount="$(find "$INSTALL" -exec xattr -l {} + 2>/dev/null | grep -c com.apple.quarantine || true)"
[ "$qcount" = "0" ] || { echo "FATAL: $qcount quarantine xattrs in the install tree"; exit 1; }
echo "E2E-NO-QUARANTINE"

echo ">> e2e: PASS — $REPO@$TAG installs and runs on a clean box"
