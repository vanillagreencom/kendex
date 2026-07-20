#!/usr/bin/env bash
# Doc-contract test for the completed-blocker relation rule (#745).
# SKILL.md's "Blocked Label vs Issue Relations" section must state that a
# blocking relation pointing at a Done/Canceled issue is satisfied history
# (Linear already treats the issue as unblocked), that the relation stays for
# provenance, that audits must never classify it as stale metadata or remove
# it, and that the only legitimate audit output is a scheduling signal.

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
assert_file_contains "$skill_md" 'Linear itself already treats the dependent issue as unblocked' "Linear auto-unblock semantics stated"
assert_file_contains "$skill_md" 'never remove or "fix" it, and audits must never classify it as stale' "removal and stale classification forbidden"
assert_file_contains "$skill_md" 'gates cleared, ready to schedule' "scheduling signal is the only legitimate audit output"
assert_file_contains "$skill_md" 'STALE blocked_by METADATA' "observed failure mode kept as cautionary rationale"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
