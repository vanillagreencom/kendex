#!/usr/bin/env bash
# Contract test for the fail-closed measurement rule: a run that produced no
# samples is instrument failure, never a numeric or green result. Two halves,
# because the rule has two carriers:
#
#   a. Prose — the Ethos bullet in SKILL.md that binds every reviewer, and the
#      schema doc's statement of the rejection reviewers have to satisfy.
#   b. Behavior — orch's review-artifact-check actually rejecting a zero-sample
#      artifact and actually accepting a measured one (a guard proven in one
#      direction only is a guard that could be passing vacuously).
#
# The behavioral half runs only when the canonical orch skill sits alongside
# this one, the same way the agent-file mirror check in
# mutation-stability-contract.test.sh is conditional.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CHECK="$SKILL_DIR/../orch/scripts/review-artifact-check"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }

require_fixed() {
  local file="$1" needle="$2" desc="$3"
  if grep -Fq -- "$needle" "$file"; then
    pass "$desc"
  else
    fail "$desc — missing in ${file#$SKILL_DIR/}"
  fi
}

# artifact <name> <json> → prints the written path
artifact() {
  local path="$TMP_ROOT/$1.json"
  printf '%s' "$2" > "$path"
  printf '%s' "$path"
}

# expect_reason <artifact-path> <expected-reason> <desc>
expect_reason() {
  local path="$1" want="$2" desc="$3" out rc=0
  out="$("$CHECK" --file "$path" 2>/dev/null)" || rc=$?
  local got
  got="$(jq -r '.reason' <<<"$out" 2>/dev/null || printf 'unparseable')"
  if [[ "$got" == "$want" ]]; then
    pass "$desc"
  else
    fail "$desc — expected reason=$want, got reason=$got (rc=$rc)"
  fi
}

echo "=== reviewer measurement fail-closed contract ==="

skill="$SKILL_DIR/SKILL.md"
schema="$SKILL_DIR/schemas/review-finding.md"
[[ -f "$skill" ]] || { echo "FAIL: SKILL.md not found" >&2; exit 1; }
[[ -f "$schema" ]] || { echo "FAIL: schemas/review-finding.md not found" >&2; exit 1; }

# --- a. the rule is stated where every reviewer loads it ---

require_fixed "$skill" 'produced zero samples' 'Ethos states the zero-sample rule'
require_fixed "$skill" 'exited nonzero' 'Ethos covers a measuring pipeline that failed'
require_fixed "$skill" 'instrument failure' 'Ethos names the classification'
require_fixed "$skill" 'never as a number, a zero, or a pass' 'Ethos forbids reporting it as a result'
require_fixed "$schema" 'zero_sample' 'schema doc names the rejection reason'
require_fixed "$schema" 'never as a numeric citation' 'schema doc states what to report instead'

# --- b. the gate enforces it, in both directions ---

if [[ ! -x "$CHECK" ]]; then
  echo "  skip  review-artifact-check not present alongside this skill"
else
  # A zero denominator is the incident shape: a selection/quoting fault runs
  # nothing, the pipeline still exits 0, and the citation reads as evidence.
  expect_reason \
    "$(artifact zero-mutants '{"agent":"reviewer-test","verdict":"pass","summary":"mutation: killed 0/0; stability: 10/10 at 16 threads"}')" \
    zero_sample "gate rejects a zero-mutant mutation citation"
  expect_reason \
    "$(artifact zero-runs '{"agent":"reviewer-test","verdict":"pass","summary":"mutation: killed 3/3; stability: 0/0 at 16 threads"}')" \
    zero_sample "gate rejects a zero-run stability citation"
  expect_reason \
    "$(artifact zero-threads '{"agent":"reviewer-test","verdict":"pass","summary":"mutation: killed 3/3; stability: 10/10 at 0 threads"}')" \
    zero_sample "gate rejects elevated parallelism of zero threads"
  expect_reason \
    "$(artifact zero-percentiles '{"agent":"reviewer-perf","verdict":"pass","summary":"s","blockers":[],"suggestions":[],"qa_metadata":{"perf_qa":{"percentiles":{"p50":0,"p99":0}}}}')" \
    zero_sample "gate rejects an all-zero benchmark percentile block"

  # MUST-FAIL CONTROLS: the same artifacts with real samples must pass, or the
  # rejections above prove nothing about the guard's discrimination.
  expect_reason \
    "$(artifact measured '{"agent":"reviewer-test","verdict":"pass","summary":"mutation: killed 3/3; stability: 10/10 at 16 threads"}')" \
    valid "gate accepts a citation with real samples"
  expect_reason \
    "$(artifact measured-percentiles '{"agent":"reviewer-perf","verdict":"pass","summary":"s","blockers":[],"suggestions":[],"qa_metadata":{"perf_qa":{"percentiles":{"p50":0,"p99":4.2}}}}')" \
    valid "gate accepts a percentile block carrying a real number"
  expect_reason \
    "$(artifact uncited '{"agent":"reviewer-quality","verdict":"pass","summary":"no measurement in scope for this domain"}')" \
    valid "gate leaves an artifact citing no measurement alone"
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
