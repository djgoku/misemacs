#!/usr/bin/env bash
# compute-version.sh — emit `VERSION=<resolved>` to stdout.
#
#   $1 (or $VERSION_INPUT)  explicit version. Validated against
#                            ^[0-9]{4}\.[0-9]{2}\.[0-9]{2}(\.[0-9]+)?$.
#   no arg                   today (UTC) as YYYY.MM.DD; if any matching git
#                            tag exists, append .1, .2, … until free.
set -euo pipefail

VERSION_RE='^[0-9]{4}\.[0-9]{2}\.[0-9]{2}(\.[0-9]+)?$'

input="${1:-${VERSION_INPUT:-}}"

if [ -n "$input" ]; then
    [[ "$input" =~ $VERSION_RE ]] || {
        echo "compute-version: invalid version '$input' (expected YYYY.MM.DD or YYYY.MM.DD.N)" >&2
        exit 1
    }
    printf 'VERSION=%s\n' "$input"
    exit 0
fi

today=$(date -u +%Y.%m.%d)
candidate="$today"
n=0
while git rev-parse -q --verify "refs/tags/$candidate" >/dev/null; do
    n=$((n + 1))
    candidate="$today.$n"
done
printf 'VERSION=%s\n' "$candidate"
