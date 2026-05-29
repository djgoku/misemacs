#!/usr/bin/env bash
# inputs-hash.sh — print a stable sha256 of everything that determines a
# flavor's built Emacs.app. CI records this on each release and compares it on
# the next run, so an unchanged flavor skips the (~11-min) rebuild + re-release.
#
# Usage: inputs-hash.sh <flavor>
#
# Inputs hashed: the flavor's lockfile + build.toml, every lib's lockfile +
# build.toml, mise.lock (conda pins), and the from-source build scripts. The
# src worktree is derived from the lockfile sha, so the lockfile stands in for it.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

flavor="${1:?usage: inputs-hash.sh <flavor>}"
[ -f "pkgs/$flavor/lockfile.toml" ] || { echo "inputs-hash: unknown flavor '$flavor'" >&2; exit 1; }

# Per-file sha256 lines, sorted (so the result is order-independent), then
# hashed together into a single digest.
{
    shasum -a 256 \
        "pkgs/$flavor/lockfile.toml" \
        "pkgs/$flavor/build.toml" \
        libs/*/lockfile.toml \
        libs/*/build.toml \
        mise.lock \
        scripts/build/*.sh
} | sort | shasum -a 256 | cut -d' ' -f1
