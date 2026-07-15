#!/usr/bin/env bash
# Regression test for #557 (reopened): the skill's scripts run under
# `#!/usr/bin/env bash` with no Bash 4 guarantee (macOS ships system Bash
# 3.2), so Bash-4-only builtins and declarations must not appear in shell
# code. jq programs may use their own [-1]/negative indexing — this scans
# for shell constructs only.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

violations="$(grep -rnE 'mapfile|readarray|declare -A|local -A' \
  "$SKILL_DIR/scripts/lib" "$SKILL_DIR/scripts/commands" || true)"

if [ -n "$violations" ]; then
  echo "FAIL Bash-4-only constructs found (macOS system bash is 3.2):"
  echo "$violations"
  exit 1
fi

echo "all pass"
