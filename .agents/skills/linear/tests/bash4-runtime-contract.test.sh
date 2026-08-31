#!/usr/bin/env bash
# Regression test for #557: the Linear CLI has an explicit Bash 4+ contract.
# Under Bash 3 this delegates to the full hierarchy regression, which proves
# the clear preflight diagnostic and that no API request is attempted.
#
# This is the opposite of what `tools/bash32-lint` asserts everywhere else, so
# skills/linear/scripts is that lint's one NO_SCAN entry: the set it enforces
# would forbid the runtime this skill demands.

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
