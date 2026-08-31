#!/usr/bin/env bash
# Doc-contract test for the completed-blocker relation rule (#745).
# SKILL.md's "Blocked Label vs Issue Relations" section states that a blocking
# relation pointing at a Done/Canceled issue is satisfied history, that the
# relation stays for provenance, that audits must never classify it as stale
# metadata or remove it, and that the only legitimate audit output is a
# scheduling signal. What this test pins is the two ANCHORS in that section:
# the bolded term the rule defines and the quoted signal string it names.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

skill_md="$SKILL_DIR/SKILL.md"

assert_file_contains "completed blockers framed as satisfied history, not stale metadata" \
  "$skill_md" 'satisfied history, not stale metadata'
assert_file_contains "scheduling signal is the only legitimate audit output" \
  "$skill_md" 'gates cleared, ready to schedule'
