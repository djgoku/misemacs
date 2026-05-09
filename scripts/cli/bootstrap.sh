#!/usr/bin/env bash
# bootstrap.sh — fresh-clone setup. Idempotent.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"

say "running mise install …"
(cd "$ROOT" && mise install)

say "hydrating all packages …"
(cd "$ROOT" && bash scripts/hydrate.sh)

say "bootstrap complete. Run \`mise run build\` to build."
