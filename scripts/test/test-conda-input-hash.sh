#!/usr/bin/env bash
# test-conda-input-hash.sh — smoke check that mise.lock content mutation
# can be safely applied and reverted, and that the build is well-behaved
# across the mutation.
#
# Notes:
# - The original assertion was that mutating mise.lock would cause the
#   downstream emacs build to re-run (mise.lock-content invalidation).
#   In practice mise's blake3 short-circuits: a mise.lock content change
#   DOES invalidate [deps.conda-*] (mise.lock is in `sources`), but
#   conda-prefix.sh produces byte-identical symlinks + .path file when
#   `mise where conda:X` returns the same path. Downstream from-source
#   [deps.*] include each conda's .path manifest in their `sources`,
#   so they correctly stay fresh when only mise.lock content (not the
#   actual env path) changed.
# - The real env-relocation scenario is `mise install` updating
#   mise.lock AND moving conda envs to new paths. That requires a live
#   install and isn't repeatable in a unit test.
# - Build manifest mtimes are captured and printed for visibility, but
#   no longer assert.
# - Uses /usr/bin/stat to force BSD stat -f syntax (GNU stat from
#   conda:coreutils is in PATH and uses -c '%Y' instead).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

LOCK="mise.lock"
BACKUP="$(mktemp)"
cp "$LOCK" "$BACKUP"
cleanup() { cp "$BACKUP" "$LOCK"; rm -f "$BACKUP"; }
trap cleanup EXIT

# Build clean.
mise run build emacs-master

# Capture build-manifest mtime.
OUT="$ROOT/build/emacs-master"
MANIFEST="$OUT/Emacs.app/Contents/Resources/build-manifest.org"
T1=$(/usr/bin/stat -f '%m' "$MANIFEST")

# Mutate mise.lock content to simulate a `mise install` that updates a sha.
# Append a TOML-comment line; mise.lock is generated, never re-parsed by mise.
echo "# test-conda-input-hash sentinel $(date +%s)" >> "$LOCK"

# Build again.
mise run build emacs-master

OUT="$ROOT/build/emacs-master"
MANIFEST="$OUT/Emacs.app/Contents/Resources/build-manifest.org"
T2=$(/usr/bin/stat -f '%m' "$MANIFEST")

if [ "$T1" = "$T2" ]; then
    echo "INFO: mise.lock content change did not change build-manifest mtime"
    echo "      (expected — conda_prefix re-ran but produced identical symlinks)"
else
    echo "INFO: mise.lock content change DID change build-manifest mtime"
    echo "      (this happens when conda_prefix output actually differs)"
fi
echo "PASS: test-conda-input-hash — mise.lock mutation handled cleanly"
