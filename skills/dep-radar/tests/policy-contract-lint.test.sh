#!/usr/bin/env bash
# Doc-contract lint for the dep-radar operating policy.
#
# The skill's value rests on a maintainer-approved contract: what may be
# auto-applied, what must only ever be reported, uncertain→report, one PR per
# surface, and the demote-only owner-rule. A future edit that softens any of
# those tiers (e.g. "may promote report→auto", batching surfaces into one PR)
# would silently turn a safe refresh loop into an unsafe one. This lint pins
# each contract clause in SKILL.md, and proves its own teeth by mutating a
# copy of the doc to violate each rule and asserting the check catches it.
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
# Prints the names of missing/violated contract clauses (empty output = doc
# honors the full contract). Each clause is pinned as a fixed string that the
# canonical SKILL.md carries on a single line, so plain grep -F is exact.
check_contract() {
  local f="$1" missing=""
  grep -qF 'AUTO-apply: security fixes; patch/minor bumps; pinned-binary version+SHA refreshes from OFFICIAL manifests only; SDK bumps with clean changelogs; internal improvements with no user-facing behavior change.' "$f" \
    || missing="$missing auto-tier-list"
  grep -qF 'REPORT (never auto): new user-facing capabilities; breaking/major bumps; vendored-fork rebases; model swaps.' "$f" \
    || missing="$missing report-tier-list"
  grep -qF 'Uncertain → report.' "$f" \
    || missing="$missing uncertain-to-report"
  grep -qF 'Every run ends with a dated report.' "$f" \
    || missing="$missing dated-report-every-run"
  grep -qF 'never promote report→auto' "$f" \
    || missing="$missing demote-only-owner-rule"
  grep -qiF 'one PR per surface' "$f" \
    || missing="$missing one-pr-per-surface"
  grep -qF 'never batch' "$f" \
    || missing="$missing never-batch"
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

expect_caught auto-tier-list \
  "$(mutate no-auto '/AUTO-apply: security fixes/d')" \
  "deleting the AUTO-apply tier list is caught"

expect_caught report-tier-list \
  "$(mutate no-report '/REPORT (never auto)/d')" \
  "deleting the REPORT tier list is caught"

expect_caught uncertain-to-report \
  "$(mutate uncertain-flip 's/Uncertain → report\./Uncertain → auto-apply./')" \
  "flipping uncertain→report to uncertain→auto is caught"

expect_caught dated-report-every-run \
  "$(mutate no-dated '/Every run ends with a dated report/d')" \
  "deleting the every-run dated report rule is caught"

expect_caught demote-only-owner-rule \
  "$(mutate promote 's/never promote report→auto/may promote report→auto/g')" \
  "softening the owner-rule to allow report→auto promotion is caught"

expect_caught one-pr-per-surface \
  "$(mutate batch-run 's/per surface/per run/g')" \
  "rewording one-PR-per-surface to one-PR-per-run is caught"

expect_caught never-batch \
  "$(mutate batch-ok 's/never batch/batch freely/g')" \
  "removing the never-batch rule is caught"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
