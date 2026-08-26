#!/usr/bin/env bash
# Regression test for #557: the Linear CLI has an explicit Bash 4+ contract.
# Under Bash 3 this delegates to the full hierarchy regression, which proves
# the clear preflight diagnostic and that no API request is attempted.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  exec bash "$SCRIPT_DIR/issues-add-relation-hierarchy.test.sh"
fi

SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
help_output=$(bash "$SKILL_DIR/scripts/linear.sh" --help)
grep -q "Bash 4.0 or newer. macOS system Bash 3.2 is unsupported." <<<"$help_output"

echo "all pass"
