#!/usr/bin/env bash
# test-cheap-verbs-fast.sh — verify cheap mise verbs do NOT trigger heavy
# builders. Forces pkgs-emacs stale via a content change to build.toml
# (a deps source not touched by hydrate.sh), then runs each cheap verb
# under a 60-second timeout. If the auto-prelude were still firing the
# pkgs-emacs builder (auto = true), the verb would either time out
# compiling Emacs (~5 min) or exit non-zero from assert_pkg_coherence.
# Both fail the test.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

BUILD_TOML="pkgs/emacs/build.toml"
BACKUP="$(mktemp)"
cp "$BUILD_TOML" "$BACKUP"

cleanup() { cp "$BACKUP" "$BUILD_TOML"; rm -f "$BACKUP" /tmp/cheap-verb-*.out; }
trap cleanup EXIT

# Force pkgs-emacs stale by appending a no-op trailing newline. blake3
# of build.toml changes; pkgs-emacs (which lists build.toml in sources)
# becomes stale. hydrate.sh does not touch build.toml, so the body of
# `mise run hydrate` does not unintentionally restore freshness.
printf '\n' >> "$BUILD_TOML"

# Confirm setup: --dry-run reports pkgs-emacs would install.
if ! mise deps install --dry-run 2>&1 | grep -q 'Would install: pkgs-emacs'; then
    echo "FAIL setup: pkgs-emacs not stale after build.toml mutation"
    exit 1
fi

# hydrate and status must each complete cleanly within 60s.
for verb in hydrate status; do
    if ! timeout 60 mise run "$verb" >"/tmp/cheap-verb-$verb.out" 2>&1; then
        rc=$?
        echo "FAIL: mise run $verb exited $rc (likely auto-prelude fired pkgs-emacs builder)"
        cat "/tmp/cheap-verb-$verb.out"
        exit 1
    fi
done

# doctor exits non-zero on coherence drift but should still complete fast.
# Our setup didn't cause coherence drift (only build.toml changed), so
# doctor should exit 0 too.
if ! timeout 60 mise run doctor >/tmp/cheap-verb-doctor.out 2>&1; then
    rc=$?
    echo "FAIL: mise run doctor exited $rc within 60s timeout"
    cat /tmp/cheap-verb-doctor.out
    exit 1
fi

echo "PASS: test-cheap-verbs-fast — hydrate, status, doctor each completed without firing pkgs-emacs builder"
