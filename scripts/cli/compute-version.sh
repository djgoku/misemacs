#!/usr/bin/env bash
# compute-version.sh — emit `VERSION=<flavor>-<calver>` to stdout.
#
#   $1                       flavor (required), e.g. emacs-master.
#   $2 (or $VERSION_INPUT)   explicit calver. Validated against
#                            ^[0-9]{4}\.[0-9]{2}\.[0-9]{2}(\.[0-9]+)?$.
#   no calver                today (UTC) as YYYY.MM.DD; if a tag
#                            <flavor>-<calver> exists, append .1, .2, … free.
set -euo pipefail

CALVER_RE='^[0-9]{4}\.[0-9]{2}\.[0-9]{2}(\.[0-9]+)?$'

flavor="${1:-}"
[ -n "$flavor" ] || { echo "compute-version: missing flavor argument" >&2; exit 1; }
input="${2:-${VERSION_INPUT:-}}"

if [ -n "$input" ]; then
    [[ "$input" =~ $CALVER_RE ]] || {
        echo "compute-version: invalid calver '$input' (expected YYYY.MM.DD or YYYY.MM.DD.N)" >&2
        exit 1
    }
    printf 'VERSION=%s-%s\n' "$flavor" "$input"
    exit 0
fi

today=$(date -u +%Y.%m.%d)
candidate="$today"
n=0
while git rev-parse -q --verify "refs/tags/${flavor}-${candidate}" >/dev/null; do
    n=$((n + 1))
    candidate="$today.$n"
done
printf 'VERSION=%s-%s\n' "$flavor" "$candidate"
