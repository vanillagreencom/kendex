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

DEGEN_N=1

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
require_fixed "$skill" 'top-level' 'Ethos says where the declaration goes'
require_fixed "$skill" 'stability: 0/10' 'Ethos distinguishes a zero result from a zero sample'
require_fixed "$schema" 'zero_sample' 'schema doc names the rejection reason'
require_fixed "$schema" 'measurement_failed' 'schema doc specifies the declaration field'
require_fixed "$schema" 'invalid_declaration' 'schema doc names the bar a declaration must clear'
require_fixed "$schema" 'valid_undermeasured' 'schema doc names the state a declaration produces'
require_fixed "$schema" 'are never scanned' 'schema doc says where quoted numbers belong'
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

  # QUOTING SOMEBODY ELSE'S ZEROED RUN. .summary and .qa_metadata carry the
  # artifact's own measurements; the finding arrays describe the code under
  # review, so numbers a reviewer is quoting go there and the gate stays out of
  # the way. Both directions, or the scope is a comment rather than a rule.
  expect_reason \
    "$(artifact quoted-in-blocker '{"agent":"reviewer-test","verdict":"action_required","summary":"reviewed the gate","blockers":[{"id":1,"title":"t","location":"tests/x.sh","description":"the fixture uses mutation: killed 0/0 to prove the gate rejects","recommendation":"r","priority":3,"estimate":1}],"suggestions":[],"qa_metadata":{}}')" \
    valid "a zeroed citation quoted inside a blocker is out of scope"
  expect_reason \
    "$(artifact same-text-in-summary '{"agent":"reviewer-test","verdict":"pass","summary":"the fixture uses mutation: killed 0/0 to prove the gate rejects","blockers":[],"suggestions":[],"qa_metadata":{}}')" \
    zero_sample "the same text in .summary is the artifact's own measurement"

  # THE FINDING CLASS THE GATE EXISTS TO PROMOTE. A reviewer whose OWN harness
  # generated nothing must be able to report it WITH the numbers. The
  # declaration is top-level — reaching it must not require adopting the qa
  # shape and its finding-array contract — and it produces its own reason, so
  # an orchestrator branching on reason cannot record the domain as clean.
  declared="$(artifact declared-failure '{"agent":"reviewer-test","verdict":"action_required","summary":"harness produced nothing: mutation: killed 0/0","blockers":[],"suggestions":[],"measurement_failed":"cargo-mutants selected 0 mutants for the changed file"}')"
  expect_reason "$declared" valid_undermeasured "a declared instrument failure keeps its zero citation"
  expect_field "$declared" '.measurement_failed' \
    "cargo-mutants selected 0 mutants for the changed file" \
    "the declaration is echoed back on the check's result"
  expect_field "$declared" '.ok' true "a declared instrument failure is still an accepted artifact"

  # Following the rejection's instruction from the tolerant shape must not
  # dead-end in a second, different refusal.
  expect_reason \
    "$(artifact tolerant-adopts-escape '{"agent":"reviewer-test","verdict":"pass","summary":"mutation: killed 0/0","measurement_failed":"cargo-mutants selected 0 mutants for this module"}')" \
    valid_undermeasured "an artifact with no qa_metadata can adopt the escape"

  # A declaration next to verdict "pass" is not a plain green.
  expect_reason \
    "$(artifact declared-and-pass '{"agent":"reviewer-test","verdict":"pass","summary":"mutation: killed 0/0","blockers":[],"suggestions":[],"measurement_failed":"cargo-mutants selected 0 mutants for the changed file"}')" \
    valid_undermeasured "verdict pass beside a declaration is never reported as plain valid"

  # MUST-FAIL CONTROLS on the escape: it has to SAY something, and it is
  # refused on its own terms rather than silently ignored.
  for degenerate in '"."' '"n/a"' '"none"' '"unknown"' '"   "' '"---"' 'true' '0'; do
    expect_reason \
      "$(artifact "degenerate-$DEGEN_N" "{\"agent\":\"reviewer-test\",\"verdict\":\"pass\",\"summary\":\"mutation: killed 0/0\",\"blockers\":[],\"suggestions\":[],\"measurement_failed\":$degenerate}")" \
      invalid_declaration "a declaration of $degenerate names no instrument and is refused"
    DEGEN_N=$((DEGEN_N + 1))
  done

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

  # A jq diagnostic that leaves the exit status alone is not a finding: it used
  # to be merged into the answer and echoed as a fabricated declaration.
  chatty_dir="$TMP_ROOT/jqchatty"
  mkdir -p "$chatty_dir"
  printf '#!/usr/bin/env bash\necho "chatty jq diagnostic" >&2\nexec %s "$@"\n' "$(command -v jq)" > "$chatty_dir/jq"
  chmod +x "$chatty_dir/jq"
  set +e
  chatty_out="$(PATH="$chatty_dir:$PATH" "$CHECK" --file "$clean" 2>/dev/null)"
  chatty_rc=$?
  set -e
  chatty_reason="$(jq -r '.reason' <<<"$chatty_out" 2>/dev/null || printf 'unparseable')"
  chatty_decl="$(jq -r 'has("measurement_failed")' <<<"$chatty_out" 2>/dev/null || printf 'unparseable')"
  if [[ "$chatty_reason" == "valid" && "$chatty_rc" -eq 0 && "$chatty_decl" == "false" ]]; then
    pass "jq stderr on a successful call is neither a finding nor a fabricated declaration"
  else
    fail "a jq stderr diagnostic leaked into the answer (reason=$chatty_reason, rc=$chatty_rc, declared=$chatty_decl)"
  fi

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
