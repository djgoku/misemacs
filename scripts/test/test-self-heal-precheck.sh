#!/usr/bin/env bash
# test-self-heal-precheck.sh — manually edit pkgs/emacs-master/lockfile.toml's sha
# (without invoking bump.sh or hydrate.sh), then mise run build must
# auto-hydrate and produce a working Emacs.app at the new sha.
#
# Replaces test-refuse.sh, which asserted the old refuse-and-tell behavior.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

LOCKFILE="pkgs/emacs-master/lockfile.toml"
BACKUP="$(mktemp)"
cp "$LOCKFILE" "$BACKUP"

ORIG_SHA=$(awk -F' *= *' '$1 == "sha" { gsub(/"/, "", $2); print $2; exit }' "$LOCKFILE")
TEST_SHA="ed1fe2ca9590a97aee62f74630f7f1f9d795bcb2"
[ "$TEST_SHA" = "$ORIG_SHA" ] && TEST_SHA="876a1db6ee00f1d1b2af0329236acc8bdcceda5b"

cleanup() {
    cp "$BACKUP" "$LOCKFILE"
    rm -f "$BACKUP" /tmp/self-heal-build.out
    bash scripts/hydrate.sh pkgs/emacs-master >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Manual edit: rewrite sha WITHOUT bumping or hydrating. Mirrors what a
# user does with `vim pkgs/emacs-master/lockfile.toml`.
awk -v new="$TEST_SHA" '/^sha = / { print "sha = \""new"\""; next } { print }' "$LOCKFILE" > "$LOCKFILE.tmp"
mv "$LOCKFILE.tmp" "$LOCKFILE"

# Verify drift exists pre-build (src/ still at ORIG_SHA).
SRC_HEAD=$(git -C pkgs/emacs-master/src rev-parse HEAD 2>/dev/null || echo "?")
if [ "$SRC_HEAD" = "$TEST_SHA" ]; then
    echo "FAIL setup: src already at TEST_SHA — pick a different fixture"
    exit 1
fi

# Run build. Self-heal precheck must auto-hydrate then build successfully.
if ! mise run build emacs-master >/tmp/self-heal-build.out 2>&1; then
    echo "FAIL: mise run build did not self-heal + build (exit non-zero)"
    tail -50 /tmp/self-heal-build.out
    exit 1
fi

# Verify post-build state: src/ now matches lockfile.
NEW_SRC_HEAD=$(git -C pkgs/emacs-master/src rev-parse HEAD)
if [ "$NEW_SRC_HEAD" != "$TEST_SHA" ]; then
    echo "FAIL: src not at TEST_SHA after build (got $NEW_SRC_HEAD, expected $TEST_SHA)"
    exit 1
fi

# Verify auto-hydrate emitted its diagnostic line in the build log.
if ! grep -q 'auto-hydrating' /tmp/self-heal-build.out; then
    echo "FAIL: build log doesn't show 'auto-hydrating' message — precheck may not have engaged"
    exit 1
fi

echo "PASS: test-self-heal-precheck — manual lockfile edit + mise run build → auto-hydrate + build"
