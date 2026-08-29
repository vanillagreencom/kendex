#!/usr/bin/env bash
# Doc-contract lint for the dep-radar operating policy.
#
# The policy is a table and each rule is a row keyed by name. This lint pins
# the table — its header, its delimiter, and every ROW KEY — inside the
# Operating policy section, so neither losing the table shape nor moving the
# rows elsewhere in the file passes. review-bots.md: a token pin establishes that a structural
# element is present, never that a behavioral claim written in prose is true,
# and prose negates and qualifies around any literal — so the second column is
# not pinned and may be reworded freely. Dropping or renaming a key is what
# this catches, and a key is what an inventory owner-rule cites when it demotes
# a tier, so the key is the part that has to hold still.
#
# Teeth: every check is re-run against a copy of the doc with its row deleted.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
SKILL_MD="$SKILL_DIR/SKILL.md"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }

# Every rule the policy table carries, in table order.
RULE_KEYS=(
  auto-with-fixes
  report-never-auto
  uncertain
  defer
  one-pr-per-surface
  upstream-check-required
  dated-report
  demote-only
)

# policy_table <file>
# The Operating policy section only. Row-shaped text elsewhere in SKILL.md is
# not the policy, and matching it anywhere would let the section be deleted
# outright while every check stayed green.
policy_table() {
  awk '/^## Operating policy/ { on = 1; next }
       on && /^## / { on = 0 }
       on' "$1"
}

# check_contract <file>
# Prints what the policy table is missing: `header`, `delimiter`, or a rule key.
# The header and delimiter are what make the rows a TABLE — without them the
# keys are just lines beginning with a pipe, and the surface the keys are
# supposed to be is gone.
check_contract() {
  local f="$1" key table missing=""
  table="$(policy_table "$f")"
  grep -qF -- '| Rule | Contract |' <<<"$table" || missing="$missing header"
  grep -qE '^\|-+\|-+\|$' <<<"$table" || missing="$missing delimiter"
  for key in "${RULE_KEYS[@]}"; do
    grep -qF -- "| \`$key\` |" <<<"$table" || missing="$missing $key"
  done
  printf '%s' "$missing"
}

# drop_row <key> → prints a copy of SKILL.md with that rule's row removed.
# awk with index(), not sed: the row is full of `|` characters, which end a sed
# address early and leave an EMPTY mutant that every check reports as missing —
# a control that passes without proving anything.
drop_row() {
  local out="$TMP_ROOT/mutant-$1.md"
  awk -v row="| \`$1\` |" 'index($0, row) != 1' "$SKILL_MD" > "$out"
  printf '%s' "$out"
}

# expect_caught <clause-name> <mutant-path> <description>
# The mutated doc must fail the check, and the failure must name the clause.
expect_caught() {
  local clause="$1" mutant="$2" desc="$3" out
  out="$(check_contract "$mutant")"
  if [[ "$out" == *"$clause"* ]]; then
    pass "$desc"
  else
    fail "$desc (check output: '$out')"
  fi
}

echo "=== dep-radar policy contract lint ==="

# --- The real doc carries every rule row ------------------------------------

missing="$(check_contract "$SKILL_MD")"
if [[ -z "$missing" ]]; then
  pass "the Operating policy is a table with a keyed row for every rule"
else
  fail "the Operating policy table is missing:$missing"
fi

# --- Frontmatter contract ---------------------------------------------------

if grep -q '^name: dep-radar$' "$SKILL_MD"; then
  pass "frontmatter names the skill dep-radar"
else
  fail "frontmatter name is not dep-radar"
fi

if grep -q '^user-invocable: true$' "$SKILL_MD"; then
  pass "frontmatter declares user-invocable: true"
else
  fail "frontmatter missing user-invocable: true"
fi

if grep -q 'required: \[github\]' "$SKILL_MD"; then
  pass "frontmatter declares the github skill as a required dependency"
else
  fail "frontmatter missing required github dependency (the PR flow needs it)"
fi

# --- Teeth: losing any part of the table must be caught ---------------------

for key in "${RULE_KEYS[@]}"; do
  ctrl="$(drop_row "$key")"
  dropped=$(( $(grep -c . "$SKILL_MD") - $(grep -c . "$ctrl") ))
  if [[ "$dropped" -ne 1 ]]; then
    fail "control for $key planted nothing — $dropped line(s) removed, expected 1"
  else
    expect_caught "$key" "$ctrl" "deleting the $key row is caught"
  fi
done

# The rows are only a table while the header and delimiter are above them.
# Both were unchecked when the keys were first pinned: deleting either left
# eight row-shaped lines and a green suite.
drop_line() { # $1 = control name, $2 = literal line prefix
  local out="$TMP_ROOT/mutant-$1.md"
  awk -v pre="$2" 'index($0, pre) != 1' "$SKILL_MD" > "$out"
  printf '%s' "$out"
}

for probe in "header:| Rule | Contract |" "delimiter:|---|---|"; do
  name="${probe%%:*}"; line="${probe#*:}"
  ctrl="$(drop_line "$name" "$line")"
  dropped=$(( $(grep -c . "$SKILL_MD") - $(grep -c . "$ctrl") ))
  if [[ "$dropped" -lt 1 ]]; then
    fail "$name control planted nothing — no line matched '$line'"
  else
    expect_caught "$name" "$ctrl" "deleting the table $name is caught"
  fi
done

# The section itself removed: the rows survive as text further down the file,
# which is what an unscoped check would still credit.
MOVED="$TMP_ROOT/mutant-moved.md"
{
  awk '/^## Operating policy/ { on = 1; next } on && /^## / { on = 0 } !on' "$SKILL_MD"
  policy_table "$SKILL_MD"
} > "$MOVED"
if ! grep -qF -- '| `dated-report` |' "$MOVED"; then
  fail "moved-section control planted nothing — the rows did not survive the move"
elif grep -qE '^## Operating policy' "$MOVED"; then
  fail "moved-section control planted nothing — the heading is still there"
else
  expect_caught "header" "$MOVED" "rows outside the Operating policy section are not the policy"
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
