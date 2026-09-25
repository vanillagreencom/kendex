#!/usr/bin/env bash
# Pins the hosted-fleet rule to one place: ../SKILL.md § The Cycle carries it as
# its own bullet, once, and the toolchain list, the workflows and the
# references point at that bullet rather than restating the rule or a scope of
# their own. On a hosted fleet the consumer train does not run, and nothing
# routes it to a hosted lane.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/md.sh"

SKILL="$SKILL_DIR/SKILL.md"
CONF="$SKILL_DIR/references/control-host-toolchain.conf"
OVERSEE="$SKILL_DIR/workflows/oversee.md"
EVENTS="$SKILL_DIR/references/oversee-events.md"
TRAIN="$SKILL_DIR/workflows/consumer-train.md"
RULE="On a hosted fleet the overseer's session does no item work"
POINTER='Item work stays in lanes'

echo "=== orch hosted overseer lint ==="

rule "the Cycle carries the hosted-fleet rule as its own bullet" "$SKILL" \
  "## The Cycle" "**$POINTER.**" 'does no item work' 'no worktree' \
  'no item branch' 'no dev, review or fix agent' \
  'no validation, build, install or test run' 'the lane that owns the branch' \
  '`lane-host resolve`' '(references/control-host-toolchain.conf)'
rule "the overseer's results bullet points at the rule" "$SKILL" \
  "## The Cycle" '**The overseer reads results.**' "$POINTER, below"

# --- Every pointer names the bullet -------------------------------------------
rule "micro's control-host refusal points at the rule" \
  "$SKILL_DIR/workflows/micro.md" "## 1. Open The Session" \
  'Any answer but `local` refuses the run here' "$POINTER"
rule "start's control-host refusal points at the rule" \
  "$SKILL_DIR/workflows/start.md" "# Start Workflow" \
  'Any answer but `local` refuses the run here' "$POINTER"
rule "the no-parallel surface points at the rule" "$OVERSEE" \
  "## 1. Resolve The Launch Surface" '3. Neither → no parallel surface' "$POINTER"
rule "a micro item's launch points at the rule" "$OVERSEE" "### Item Tier" \
  'A `micro` item launches as a lane like any other' "$POINTER"
rule "Placement points at the rule" "$OVERSEE" "### Lane directive" \
  'Placement:' "$POINTER"
rule "a hosted merge runs no train and mails each consumer's overseer" \
  "$EVENTS" "## Event kinds" '- `merged` →' "$POINTER" \
  '`lane-mail peer send --repo [NAME_OR_PATH] --file [PATH]`' 'D003'
rule "the train says it does not run on a hosted fleet" "$TRAIN" \
  "# Consumer train" 'On a hosted fleet it does not run' "$POINTER"

# The conf's comment lines read as headings to the markdown reader, so its
# pointer is checked here, with its own control.
conf_points() { grep -Fq -- "$POINTER" "$1"; }
if conf_points "$CONF"; then
  pass "the toolchain list points at the rule"
else
  fail "the toolchain list must point at the rule"
fi
awk -v p="$POINTER" '{ i = index($0, p); if (i) $0 = substr($0, 1, i - 1) substr($0, i + length(p)); print }' \
  "$CONF" >"$MD_TMP/conf-no-pointer"
if cmp -s "$CONF" "$MD_TMP/conf-no-pointer"; then
  fail "control: the mutant does not drop the toolchain list's pointer"
elif conf_points "$MD_TMP/conf-no-pointer"; then
  fail "control: a toolchain list with no pointer passes"
else
  pass "control: a toolchain list with no pointer fails"
fi

# --- The rule is stated once ----------------------------------------------------
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

forbid "the toolchain list does not restate the rule" 'does no item work' \
  "# $RULE." "$CONF"
forbid "the toolchain list states no scope of its own" 'rule covers item work' \
  '# The rule covers item work: `micro`.' "$CONF"
forbid "the toolchain list names no pending follow-up" 'not yet covered' \
  '# The hosted route is not yet covered.' "$CONF"
forbid "the toolchain list holds no git subcommand" '^git ' 'git commit' "$CONF"
forbid "no workflow or reference restates the rule" 'does no item work' \
  "$RULE." "$SKILL_DIR/workflows"/*.md "$SKILL_DIR/references"/*.md
forbid "no workflow or reference routes the train to a hosted lane" \
  'consumer-train\.md.*hosted lane' \
  'A match launches [consumer-train.md](../workflows/consumer-train.md) as a hosted lane.' \
  "$SKILL_DIR/workflows"/*.md "$SKILL_DIR/references"/*.md

md_report
