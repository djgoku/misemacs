#!/usr/bin/env bash
# scripts/build/conda-prefix.sh — populate build/conda-<TOOL>/ from `mise where`.
#
# Usage: bash scripts/build/conda-prefix.sh <conda-tool-name>
#
# Produces:
#   build/conda-<TOOL>/{lib,include,share,bin}/   — symlinks to the conda env's
#                                                    subdirs (whichever exist)
#   build/conda-<TOOL>/.path                       — one-line file with the conda
#                                                    env's absolute path. Used by
#                                                    downstream [deps.*] sources
#                                                    to detect env relocation.
#
# This is the [deps.conda-<X>] provider's `run` line. Idempotent.
set -euo pipefail

TOOL="${1:?usage: conda-prefix.sh <conda-tool-name>}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/build/conda-$TOOL"

prefix=$(mise where "conda:$TOOL" 2>/dev/null || true)
if [ -z "$prefix" ] || [ ! -d "$prefix" ]; then
    echo "conda-prefix: 'mise where conda:$TOOL' returned empty or non-directory: '$prefix'" >&2
    exit 1
fi

mkdir -p "$OUT"
for sub in lib include share bin; do
    if [ -d "$prefix/$sub" ]; then
        ln -sfn "$prefix/$sub" "$OUT/$sub"
    fi
done

# .path manifest — drives downstream [deps.*] invalidation when the env relocates.
printf '%s\n' "$prefix" > "$OUT/.path"
