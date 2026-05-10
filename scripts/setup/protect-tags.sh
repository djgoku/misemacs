#!/usr/bin/env bash
# protect-tags.sh — install the GitHub repository ruleset that makes all
# tags immutable (no deletion, no force-push). Idempotent: if a ruleset
# named "release-tag-immutability" already exists, exits 0 with no change.
#
# Requires: gh CLI authenticated as a repo admin.
#
# Usage: bash scripts/setup/protect-tags.sh [<owner>/<repo>]
#   default <owner>/<repo>: djgoku/misemacs
set -euo pipefail

REPO="${1:-djgoku/misemacs}"
RULESET_NAME="release-tag-immutability"

# Idempotent check
existing=$(gh api "/repos/${REPO}/rulesets" 2>/dev/null \
    | python3 -c 'import sys, json; rs = json.load(sys.stdin); print(next((r["id"] for r in rs if r["name"] == "'"$RULESET_NAME"'"), ""))' 2>/dev/null)
if [ -n "$existing" ]; then
    echo "protect-tags: ruleset '$RULESET_NAME' already present (id=$existing); no change"
    exit 0
fi

gh api -X POST "/repos/${REPO}/rulesets" --input - <<EOF
{
  "name": "${RULESET_NAME}",
  "target": "tag",
  "enforcement": "active",
  "conditions": {
    "ref_name": { "include": ["~ALL"], "exclude": [] }
  },
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" }
  ]
}
EOF

echo "protect-tags: applied ruleset '$RULESET_NAME' to ${REPO}"
