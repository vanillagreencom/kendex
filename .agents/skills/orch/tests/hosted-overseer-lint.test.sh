#!/usr/bin/env bash
# Pins the hosted-fleet rule to one place: ../SKILL.md § The Cycle carries it as
# its own bullet, once, and the toolchain list, the workflows and the
# references point at that bullet rather than restating the rule or a scope of
# their own.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/md.sh"

SKILL="$SKILL_DIR/SKILL.md"
CONF="$SKILL_DIR/references/control-host-toolchain.conf"
RULE="On a hosted fleet the overseer's session does no item work"

echo "=== orch hosted overseer lint ==="

rule "the Cycle carries the hosted-fleet rule as its own bullet" "$SKILL" \
  "## The Cycle" '**Item work stays in lanes.**' "$RULE" \
  'Every round of an item goes to the lane that owns the branch'
rule "the overseer's results bullet points at the rule" "$SKILL" \
  "## The Cycle" '**The overseer reads results.**' 'Item work stays in lanes, below'

# rule_once FILE — true when exactly one line of FILE carries the rule.
rule_once() {
  local n rc=0
  n="$(grep -cF -- "$RULE" "$1")" || rc=$?
  [ "$rc" -le 1 ] || return 2
  [ "$n" = 1 ]
}

if rule_once "$SKILL"; then
  pass "SKILL.md states the rule once"
else
  fail "SKILL.md must state the rule on exactly one line"
fi
# Control: a second copy of the bullet must fail the once check.
cp "$SKILL" "$MD_TMP/rule-twice.md"
grep -F -- "$RULE" "$SKILL" >>"$MD_TMP/rule-twice.md"
if [ "$(grep -cF -- "$RULE" "$MD_TMP/rule-twice.md" || true)" != 2 ]; then
  fail "control: the mutant does not carry the rule twice"
elif rule_once "$MD_TMP/rule-twice.md"; then
  fail "control: a rule stated twice passes the once check"
else
  pass "control: a rule stated twice fails the once check"
fi

forbid "the toolchain list carries neither the rule nor a scope of its own" \
  'does no item work|rule covers item work|not yet covered' \
  '# train is not yet covered and belongs to a follow-up.' "$CONF"
forbid "no workflow or reference restates the rule" 'does no item work' \
  "$RULE." "$SKILL_DIR/workflows"/*.md "$SKILL_DIR/references"/*.md

md_report
