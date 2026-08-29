#!/usr/bin/env bash
# Doc-contract test for the completed-blocker relation rule (#745).
# SKILL.md's "Blocked Label vs Issue Relations" section states that a blocking
# relation pointing at a Done/Canceled issue is satisfied history, that the
# relation stays for provenance, that audits must never classify it as stale
# metadata or remove it, and that the only legitimate audit output is a
# scheduling signal. What this test pins is the two ANCHORS in that section:
# the bolded term the rule defines and the quoted signal string it names.

#
# What this pins is the bolded term the rule defines and the quoted signal
# string it names. review-bots.md: a token pin establishes that a structural
# element is present, never that a behavioral claim written in prose is true,
# so the sentences around them have no lint — that Linear already treats the
# dependent issue as unblocked, and that the relation is never removed or
# classified as stale.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0

assert_file_contains() {
  local file="$1" pattern="$2" name="$3"
  if grep -Fq -- "$pattern" "$file"; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        missing pattern: %s\n        file: %s\n' "$name" "$pattern" "$file"
  fi
}

echo "=== linear SKILL.md completed-blocker relation contract ==="

skill_md="$SKILL_DIR/SKILL.md"

assert_file_contains "$skill_md" 'satisfied history, not stale metadata' "completed blockers framed as satisfied history, not stale metadata"
assert_file_contains "$skill_md" 'gates cleared, ready to schedule' "scheduling signal is the only legitimate audit output"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
