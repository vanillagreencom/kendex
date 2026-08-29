#!/usr/bin/env bash
# Doc-contract lint for the dep-radar operating policy.
#
# The policy assigns every surface to one of three tiers. This lint pins those
# TIER LABELS and the frontmatter, never the clauses that say what each tier
# holds. review-bots.md: a token pin establishes that a structural element is
# present, never that a behavioral claim written in prose is true, and prose
# negates and qualifies around any literal.
#
# So the policy's own content has no lint. Nothing here checks what the
# auto-with-fixes tier covers or that it fixes fallout in the same per-surface
# workstream; what the report tier holds or that nothing else is
# report-by-default; that uncertain means attempt the upgrade and report only
# what failed; that it is one PR per surface and surfaces are never batched;
# that every pinned surface carries a wired upstream check and a surface
# lacking one is an inventory defect the run must fix; that an owner rule
# demotes and never promotes report→auto; or that every run ends with a dated
# report. An edit that re-broadens a tier or drops a rail passes this suite.
#
# Teeth: every remaining check is re-run against a copy of the doc mutated to
# violate it.
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

# check_contract <file>
# Prints the names of missing tier labels (empty output = all three present).
check_contract() {
  local f="$1" missing=""
  grep -qF 'AUTO-with-fixes (default):' "$f" \
    || missing="$missing auto-tier-label"
  grep -qF 'REPORT (never auto):' "$f" \
    || missing="$missing report-tier-label"
  grep -qF 'Uncertain →' "$f" \
    || missing="$missing uncertain-tier-label"
  printf '%s' "$missing"
}

# mutate <name> <sed-script> → prints mutated copy's path.
mutate() {
  local out="$TMP_ROOT/mutant-$1.md"
  sed "$2" "$SKILL_MD" > "$out"
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

# --- The real doc honors the full contract ---------------------------------

missing="$(check_contract "$SKILL_MD")"
if [[ -z "$missing" ]]; then
  pass "SKILL.md carries every policy contract clause"
else
  fail "SKILL.md is missing contract clauses:$missing"
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

# --- Teeth: each violated rule must be caught -------------------------------

expect_caught auto-tier-label \
  "$(mutate no-auto '/AUTO-with-fixes (default): security fixes/d')" \
  "deleting the AUTO-with-fixes tier is caught"

expect_caught report-tier-label \
  "$(mutate no-report '/REPORT (never auto)/d')" \
  "deleting the REPORT tier is caught"

expect_caught uncertain-tier-label \
  "$(mutate no-uncertain '/Uncertain →/d')" \
  "deleting the Uncertain tier is caught"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
