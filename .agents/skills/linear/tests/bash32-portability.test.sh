#!/usr/bin/env bash
# Regression test for #557: the Linear CLI has an explicit Bash 4+ contract.
# Under Bash 3 this delegates to the full hierarchy regression, which proves
# the clear preflight diagnostic and that no API request is attempted.
#
# The name it shares with the other bash32-portability suites is the whole of
# what it shares. Those forbid Bash 4 syntax; this one asserts linear.sh
# demands it. So it must never take the shared bash32 pattern set those suites
# carry, and tools/tests/bash32-pattern-parity.test.sh reds if it ever does.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  exec bash "$SCRIPT_DIR/issues-add-relation-hierarchy.test.sh"
fi

# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

help_output=$(bash "$SKILL_DIR/scripts/linear.sh" --help)

assert_contains "--help states the Bash 4+ runtime contract" \
  "$help_output" "Bash 4.0 or newer. macOS system Bash 3.2 is unsupported."
