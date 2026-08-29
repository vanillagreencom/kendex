#!/usr/bin/env bash
# Doc-contract lint for the dep-radar operating policy.
#
# The policy is a table and each rule is a row keyed by name. This lint parses
# ONE CONTIGUOUS TABLE inside the Operating policy section — header, the
# delimiter on the line immediately below it, then the unbroken run of rows —
# and pins every ROW KEY in that run. Losing the table shape, reordering its
# parts, or moving the rows elsewhere in the file all fail. review-bots.md: a token pin establishes that a structural
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

# contiguous_table <header-line>  (section on stdin)
# ONE table, parsed as a structure rather than as a bag of lines: the header,
# the delimiter that must sit on the line IMMEDIATELY below it, and the
# unbroken run of rows beneath that. Anything the run does not reach — a row
# above the header, a row past a blank line, a delimiter moved below the rows
# — is not part of this table however row-shaped it looks.
#
# Checking header, delimiter and rows as independent facts does not establish
# that they form a table, for the same reason two token pins never establish a
# relation between the tokens. Order is the relation here.
contiguous_table() {
  awk -v hdr="$1" '
    !started && index($0, hdr) == 1 { started = 1; want_delim = 1; print; next }
    want_delim {
      if ($0 ~ /^\|[-:]+\|[-:| ]*$/) { want_delim = 0; print; next }
      exit
    }
    started {
      if (index($0, "|") == 1) { print; next }
      exit
    }
  '
}

# check_contract <file>
# Prints what the policy table is missing: `header`, `delimiter`, or a rule key.
check_contract() {
  local f="$1" key table missing=""
  table="$(policy_table "$f" | contiguous_table '| Rule | Contract |')"
  grep -qF -- '| Rule | Contract |' <<<"$table" || missing="$missing header"
  grep -qE '^\|[-:]+\|[-:| ]*$' <<<"$table" || missing="$missing delimiter"
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

# Order controls. Deleting the header and deleting the delimiter are two
# probes of PARTS, and two probes of parts cannot detect a structure defect any
# more than two pins can assert one. These three move things instead.

# The delimiter below the rows: eight row-shaped lines and a header, none of it
# a table, and every part still present.
REORDER="$TMP_ROOT/mutant-delim-last.md"
awk '
  /^\|-+\|-+\|$/ { delim = $0; next }
  /^\| `[a-z-]+` \|/ { rows = rows $0 ORS; next }
  rows != "" && delim != "" { printf "%s%s\n", rows, delim; rows = ""; delim = "" }
  { print }
  END { if (rows != "") printf "%s%s\n", rows, delim }
' "$SKILL_MD" > "$REORDER"
if ! grep -qF -- '| Rule | Contract |' "$REORDER" || cmp -s "$REORDER" "$SKILL_MD"; then
  fail "delimiter-last control planted nothing — the table did not reorder"
else
  expect_caught "delimiter" "$REORDER" "a delimiter moved below the rows is caught"
fi

# A row above the header: it is still in the section, still row-shaped, and no
# longer part of the table beneath the header.
REORDER="$TMP_ROOT/mutant-row-first.md"
# The row is read out first: a single pass meets the header before the row and
# would drop the row instead of moving it, leaving nothing to detect.
MOVED_ROW="$(grep -F -- '| `dated-report` |' "$SKILL_MD")"
awk -v row='| `dated-report` |' -v moved="$MOVED_ROW" '
  index($0, row) == 1 { next }
  index($0, "| Rule | Contract |") == 1 { print moved; print; next }
  { print }
' "$SKILL_MD" > "$REORDER"
if ! grep -qF -- '| `dated-report` |' "$REORDER" || cmp -s "$REORDER" "$SKILL_MD"; then
  fail "row-first control planted nothing — the row did not move"
else
  expect_caught "dated-report" "$REORDER" "a row moved above the header is caught"
fi

# A blank line mid-table: markdown ends the table there, so the rows below it
# are a second block, not this one.
REORDER="$TMP_ROOT/mutant-split.md"
awk -v row='| `one-pr-per-surface` |' 'index($0, row) == 1 { print "" } { print }' \
  "$SKILL_MD" > "$REORDER"
if [[ "$(grep -c . "$REORDER")" -ne "$(grep -c . "$SKILL_MD")" ]]; then
  fail "split control planted nothing — no blank line was inserted"
else
  expect_caught "one-pr-per-surface" "$REORDER" "a blank line mid-table is caught"
fi

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
