#!/usr/bin/env bash
# Contract test for the fail-closed measurement rule: a run that produced no
# samples is instrument failure, never a numeric or green result — and a zero
# RESULT on a measured run is the opposite, a finding that has to reach the
# orchestrator intact. Two halves, because the rule has two carriers:
#
#   a. Prose — the Ethos bullet in SKILL.md that binds every reviewer, and the
#      schema doc's statement of both the rejection and the declaration that
#      lets a reviewer keep its evidence.
#   b. Behavior — orch's review-artifact-check rejecting a zero-sample artifact,
#      accepting a measured one, and accepting a declared instrument failure. A
#      guard proven in one direction only is a guard that could be passing
#      vacuously, and the accepting cases are what pin WHICH number it reads.
#
# The behavioral half is skipped only for a reviewer-without-orch install (no
# sibling skills/orch at all). When orch IS installed, a missing or
# non-executable review-artifact-check is a failure, not a skip: that is
# precisely the drift this suite exists to catch, and skipping on it would make
# the branch fire only when it matters.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ORCH_DIR="$SKILL_DIR/../orch"
CHECK="$ORCH_DIR/scripts/review-artifact-check"
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
  local path="$1" want="$2" desc="$3" out rc=0 got
  set +e
  out="$("$CHECK" --file "$path" 2>/dev/null)"
  rc=$?
  set -e
  got="$(jq -r '.reason' <<<"$out" 2>/dev/null || printf 'unparseable')"
  if [[ "$got" == "$want" ]]; then
    pass "$desc"
  else
    fail "$desc — expected reason=$want, got reason=$got (rc=$rc)"
  fi
}

# expect_field <artifact-path> <jq-filter> <expected> <desc>
expect_field() {
  local path="$1" filter="$2" want="$3" desc="$4" out got
  set +e
  out="$("$CHECK" --file "$path" 2>/dev/null)"
  set -e
  got="$(jq -r "$filter" <<<"$out" 2>/dev/null || printf 'unparseable')"
  if [[ "$got" == "$want" ]]; then
    pass "$desc"
  else
    fail "$desc — expected '$want', got '$got'"
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
require_fixed "$skill" 'measurement_failed' 'Ethos names the declaration, so evidence is kept not deleted'
require_fixed "$skill" 'stability: 0/10' 'Ethos distinguishes a zero result from a zero sample'
require_fixed "$schema" 'zero_sample' 'schema doc names the rejection reason'
require_fixed "$schema" 'measurement_failed' 'schema doc specifies the declaration field'
require_fixed "$schema" 'Omitting the numbers is never the way past this gate' 'schema doc forbids the omission shortcut'

# --- b. the gate enforces it, in both directions ---

if [[ ! -d "$ORCH_DIR" ]]; then
  echo "  skip  sibling skills/orch is not installed (reviewer-without-orch)"
elif [[ ! -x "$CHECK" ]]; then
  fail "skills/orch is installed but review-artifact-check is missing or not executable at $CHECK"
else
  # A zero SAMPLE COUNT is the incident shape: a selection or quoting fault runs
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
    "$(artifact wrapped-citation '{"agent":"reviewer-test","verdict":"pass","summary":"mutation: killed 0/\n0"}')" \
    zero_sample "gate sees a citation its author wrapped across a newline"
  expect_reason \
    "$(artifact zero-percentiles '{"agent":"reviewer-perf","verdict":"pass","summary":"s","blockers":[],"suggestions":[],"qa_metadata":{"perf_qa":{"percentiles":{"p50":0,"p99":0}}}}')" \
    zero_sample "gate rejects an all-zero benchmark percentile block"
  expect_reason \
    "$(artifact absent-percentiles '{"agent":"reviewer-perf","verdict":"pass","summary":"s","blockers":[],"suggestions":[],"qa_metadata":{"perf_qa":{"regression_pct":0}}}')" \
    zero_sample "gate rejects a perf payload that omits percentiles entirely"

  # ACCEPTING DIRECTION, part one: a zero RESULT on a measured run. SKILL.md
  # calls a stability failure "never a pass" — the gate must let it through as
  # the finding, and these two cases are what prove the gate reads the sample
  # count rather than the result.
  expect_reason \
    "$(artifact measured-stability-failure '{"agent":"reviewer-test","verdict":"action_required","summary":"mutation: killed 3/3; stability: 0/10 at 16 threads"}')" \
    valid "gate accepts stability 0/10 — ten measured runs, none passed"
  expect_reason \
    "$(artifact surviving-mutants '{"agent":"reviewer-test","verdict":"action_required","summary":"mutation: killed 0/3; stability: 10/10 at 16 threads"}')" \
    valid "gate accepts mutation killed 0/3 — three mutants, none killed"

  # ACCEPTING DIRECTION, part two: real samples, and no citation at all.
  expect_reason \
    "$(artifact measured '{"agent":"reviewer-test","verdict":"pass","summary":"mutation: killed 3/3; stability: 10/10 at 16 threads"}')" \
    valid "gate accepts a citation with real samples"
  expect_reason \
    "$(artifact measured-percentiles '{"agent":"reviewer-perf","verdict":"pass","summary":"s","blockers":[],"suggestions":[],"qa_metadata":{"perf_qa":{"percentiles":{"p50":0,"p99":4.2}}}}')" \
    valid "gate accepts a percentile block carrying a real number"
  expect_reason \
    "$(artifact uncited '{"agent":"reviewer-quality","verdict":"pass","summary":"no measurement in scope for this domain"}')" \
    valid "gate leaves an artifact citing no measurement alone"

  # THE FINDING CLASS THE GATE EXISTS TO PROMOTE. A reviewer that discovers the
  # harness generated nothing must be able to report it WITH the numbers; the
  # declaration is the route, and it travels back out to the orchestrator so the
  # broken instrument is visible rather than quietly tolerated.
  declared="$(artifact declared-failure '{"agent":"reviewer-test","verdict":"action_required","summary":"harness produced nothing: mutation: killed 0/0","blockers":[],"suggestions":[],"qa_metadata":{"measurement_failed":"cargo-mutants selected 0 mutants for the changed file"}}')"
  expect_reason "$declared" valid "a declared instrument failure keeps its zero citation"
  expect_field "$declared" '.measurement_failed' \
    "cargo-mutants selected 0 mutants for the changed file" \
    "the declaration is echoed back on the check's result"

  # MUST-FAIL CONTROLS on the escape: it is a declaration, not a field that
  # merely exists. Neither blank nor non-string suppresses the gate.
  expect_reason \
    "$(artifact blank-declaration '{"agent":"reviewer-test","verdict":"pass","summary":"mutation: killed 0/0","blockers":[],"suggestions":[],"qa_metadata":{"measurement_failed":"   "}}')" \
    zero_sample "a blank measurement_failed does not suppress the gate"
  expect_reason \
    "$(artifact nonstring-declaration '{"agent":"reviewer-test","verdict":"pass","summary":"mutation: killed 0/0","blockers":[],"suggestions":[],"qa_metadata":{"measurement_failed":true}}')" \
    zero_sample "a non-string measurement_failed does not suppress the gate"
  expect_field \
    "$(artifact undeclared '{"agent":"reviewer-test","verdict":"pass","summary":"mutation: killed 3/3; stability: 10/10 at 16 threads"}')" \
    'has("measurement_failed")' false \
    "an artifact declaring nothing carries no measurement_failed field"

  # The rejection has to teach the declaration. A diagnostic that only accuses
  # the reviewer makes deleting the evidence the path of least resistance.
  expect_field \
    "$(artifact teaching '{"agent":"reviewer-test","verdict":"pass","summary":"mutation: killed 0/0"}')" \
    '.detail | test("measurement_failed")' true \
    "the rejection names the declaration instead of only accusing the reviewer"

  # A gate that could not run is not a clean artifact. Under a jq that fails
  # only for this gate, the answer is a loud `invalid`, never an approval.
  shim_dir="$TMP_ROOT/jqshim"
  mkdir -p "$shim_dir"
  real_jq="$(command -v jq)"
  printf '#!/usr/bin/env bash\nfor a in "$@"; do\n  case "$a" in\n    *"gate:zero-sample"*) echo "jq: error: simulated torn read" >&2; exit 5 ;;\n  esac\ndone\nexec %s "$@"\n' "$real_jq" > "$shim_dir/jq"
  chmod +x "$shim_dir/jq"
  clean="$(artifact clean-for-shim '{"agent":"reviewer-test","verdict":"pass","summary":"mutation: killed 3/3; stability: 10/10 at 16 threads"}')"
  set +e
  shim_out="$(PATH="$shim_dir:$PATH" "$CHECK" --file "$clean" 2>/dev/null)"
  shim_rc=$?
  set -e
  shim_reason="$(jq -r '.reason' <<<"$shim_out" 2>/dev/null || printf 'unparseable')"
  if [[ "$shim_reason" == "invalid" && "$shim_rc" -ne 0 ]]; then
    pass "a gate that could not run is reported, never read as a clean artifact"
  else
    fail "a broken gate was not reported (reason=$shim_reason, rc=$shim_rc)"
  fi
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
