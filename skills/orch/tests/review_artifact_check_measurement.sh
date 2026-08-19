#!/usr/bin/env bash
# Regression tests for review-artifact-check's MEASUREMENT gates: the
# zero_sample rejection, the perf-payload evidence requirement, the declared
# instrument-failure escape, and the rule that a gate which could not run is
# never read as a clean artifact. Split from review_artifact_check.sh, which
# owns location, freshness, and finding-shape acceptance.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
CHECK="$REPO_ROOT/skills/orch/scripts/review-artifact-check"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

assert_eq() {
  local got="$1" want="$2" name="$3"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$name" "$want" "$got"
  fi
}

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

assert_substr() {
  local haystack="$1" needle="$2" name="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected substring: %s\n        in:                 %s\n' "$name" "$needle" "$haystack"
  fi
}

assert_file_not_contains() {
  local file="$1" pattern="$2" name="$3"
  if grep -Fq -- "$pattern" "$file"; then
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        unexpected pattern: %s\n        file: %s\n' "$name" "$pattern" "$file"
  else
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  fi
}

# expect_valid <artifact-path> <desc> — accepting-direction assertion that
# survives a mutant. A bare `out="$("$CHECK" ...)"` aborts the whole run under
# set -e the moment a guard starts over-rejecting, which truncates the suite
# instead of naming what broke; the accepting direction is exactly where that
# matters, because it is what pins WHICH number a guard reads.
expect_valid() {
  local path="$1" desc="$2" out rc=0
  set +e
  out="$("$CHECK" --file "$path")"
  rc=$?
  set -e
  assert_eq "$rc" "0" "$desc (exits 0)"
  assert_eq "$(jq -r '.reason' <<<"$out")" "valid" "$desc"
}

# expect_glob_valid <worktree> <agent> <boundary> <expected-path> <desc>
expect_glob_valid() {
  local wt="$1" ag="$2" bound="$3" want="$4" desc="$5" out rc=0
  set +e
  out="$("$CHECK" "$wt" "$ag" "$bound")"
  rc=$?
  set -e
  assert_eq "$rc" "0" "$desc (exits 0)"
  assert_eq "$(jq -r '.path' <<<"$out")" "$want" "$desc"
}

echo "=== review-artifact-check: measurement gates ==="

worktree="$TMP_ROOT/wt"
mkdir -p "$worktree/tmp"
delegated_at=1750000000
before=$((delegated_at - 100))
after=$((delegated_at + 100))
later=$((delegated_at + 200))

# --- zero_sample: a measurement that produced no samples is not a result (vstack#1497) ---
# The gate reads the SAMPLE COUNT, never the result. A zero denominator or zero
# thread count means the instrument selected nothing; a zero numerator means it
# ran and everything failed, which is the finding SKILL.md calls "never a pass"
# and must reach the orchestrator intact. The accepting-direction cases below
# are load-bearing: without them a numerator/denominator swap passes both suites
# while the gate suppresses exactly the class it exists to promote.

zs_mut="$worktree/tmp/review-external-20260815-010101.json"
printf '{"agent":"reviewer-test","verdict":"pass","summary":"validated: mutation: killed 0/0; stability: 10/10 at 16 threads"}' > "$zs_mut"
set +e
out="$("$CHECK" --file "$zs_mut")"
rc=$?
set -e
assert_eq "$rc" "1" "--file zero-mutant citation exits 1"
assert_eq "$(jq -r '.ok' <<<"$out")" "false" "--file zero-mutant citation reports ok=false"
assert_eq "$(jq -r '.reason' <<<"$out")" "zero_sample" "--file zero-mutant citation reports reason=zero_sample"
assert_substr "$(jq -r '.detail' <<<"$out")" "killed 0/0" "--file zero-mutant detail quotes the offending citation"
assert_substr "$(jq -r '.detail' <<<"$out")" "instrument failure" "--file zero-mutant detail names the rule"
assert_substr "$(jq -r '.detail' <<<"$out")" "measurement_failed" "--file zero-mutant detail teaches the declaration, not omission"

zs_stab="$worktree/tmp/review-external-20260815-020202.json"
printf '{"agent":"reviewer-test","verdict":"pass","summary":"mutation: killed 3/3; stability: 0/0 at 16 threads"}' > "$zs_stab"
set +e
out="$("$CHECK" --file "$zs_stab")"
rc=$?
set -e
assert_eq "$rc" "1" "--file zero-run stability citation exits 1"
assert_eq "$(jq -r '.reason' <<<"$out")" "zero_sample" "--file zero-run stability reports reason=zero_sample"
assert_substr "$(jq -r '.detail' <<<"$out")" "stability: 0/0" "--file zero-run detail quotes the stability citation"

# elevated parallelism of zero threads is the same instrument failure
zs_thr="$worktree/tmp/review-external-20260815-030303.json"
printf '{"agent":"reviewer-test","verdict":"pass","summary":"mutation: killed 3/3; stability: 10/10 at 0 threads"}' > "$zs_thr"
set +e
out="$("$CHECK" --file "$zs_thr")"
rc=$?
set -e
assert_eq "$rc" "1" "--file zero-thread stability citation exits 1"
assert_eq "$(jq -r '.reason' <<<"$out")" "zero_sample" "--file zero-thread stability reports reason=zero_sample"
assert_substr "$(jq -r '.detail' <<<"$out")" "zero threads" "--file zero-thread detail names the thread count"

# ACCEPTING DIRECTION — a zero RESULT on a measured run. Both cases fail under a
# numerator/denominator swap, which is what pins WHICH number the gate reads.
zs_stab_fail="$worktree/tmp/review-external-20260815-035353.json"
printf '{"agent":"reviewer-test","verdict":"action_required","summary":"concurrency-sensitive: mutation: killed 3/3; stability: 0/10 at 16 threads"}' > "$zs_stab_fail"
expect_valid "$zs_stab_fail" "--file stability 0/10 (ten measured runs, none passed) stays valid"

zs_mut_alive="$worktree/tmp/review-external-20260815-036363.json"
printf '{"agent":"reviewer-test","verdict":"action_required","summary":"mutant survived: mutation: killed 0/3; stability: 10/10 at 16 threads"}' > "$zs_mut_alive"
expect_valid "$zs_mut_alive" "--file mutation killed 0/3 (three mutants, none killed) stays valid"

# a partial kill on a measured run is likewise the reviewer's to report
zs_mut_partial="$worktree/tmp/review-external-20260815-037373.json"
printf '{"agent":"reviewer-test","verdict":"action_required","summary":"mutation: killed 2/3; stability: 9/10 at 16 threads"}' > "$zs_mut_partial"
expect_valid "$zs_mut_partial" "--file partial kill / partial stability stays valid"

# the citation is caught wherever it lives, not only in .summary
zs_deep="$worktree/tmp/review-external-20260815-040404.json"
printf '{"agent":"reviewer-test","verdict":"action_required","summary":"s","blockers":[{"id":1,"title":"t","location":"src/x.rs (`f`)","description":"evidence: mutation: killed 0/0; stability: 10/10 at 16 threads","recommendation":"r","priority":2,"estimate":2}],"suggestions":[],"qa_metadata":{}}' > "$zs_deep"
set +e
out="$("$CHECK" --file "$zs_deep")"
rc=$?
set -e
assert_eq "$rc" "1" "--file zero-sample citation inside a blocker description exits 1"
assert_eq "$(jq -r '.reason' <<<"$out")" "zero_sample" "--file nested citation reports reason=zero_sample"

# whitespace between citation tokens is not one fixed spelling: a citation the
# reviewer's own formatting wrapped across a newline must still count
zs_wrap="$worktree/tmp/review-external-20260815-045454.json"
printf '{"agent":"reviewer-test","verdict":"pass","summary":"mutation: killed 0/\\n0; stability: 10/10 at 16 threads"}' > "$zs_wrap"
set +e
out="$("$CHECK" --file "$zs_wrap")"
rc=$?
set -e
assert_eq "$rc" "1" "--file a citation wrapped across a newline still exits 1"
assert_eq "$(jq -r '.reason' <<<"$out")" "zero_sample" "--file newline-wrapped citation reports reason=zero_sample"

zs_wrap2="$worktree/tmp/review-external-20260815-046464.json"
printf '{"agent":"reviewer-test","verdict":"pass","summary":"stability:\\n0/0 at 16 threads"}' > "$zs_wrap2"
set +e
out="$("$CHECK" --file "$zs_wrap2")"
rc=$?
set -e
assert_eq "$(jq -r '.reason' <<<"$out")" "zero_sample" "--file newline after 'stability:' still reports zero_sample"

zs_wrap3="$worktree/tmp/review-external-20260815-047474.json"
printf '{"agent":"reviewer-test","verdict":"pass","summary":"stability: 10/10 at\\n0 threads"}' > "$zs_wrap3"
set +e
out="$("$CHECK" --file "$zs_wrap3")"
rc=$?
set -e
assert_eq "$(jq -r '.reason' <<<"$out")" "zero_sample" "--file newline before a zero thread count still reports zero_sample"

# MUST-FAIL CONTROL, other direction: a real two-number citation still validates
zs_ok="$worktree/tmp/review-external-20260815-050505.json"
printf '{"agent":"reviewer-test","verdict":"pass","summary":"mutation: killed 3/3; stability: 10/10 at 16 threads"}' > "$zs_ok"
expect_valid "$zs_ok" "--file a nonzero mutation/stability citation stays valid"

# an artifact citing no measurement at all is untouched by the guard
zs_none="$worktree/tmp/review-external-20260815-060606.json"
printf '{"agent":"reviewer-quality","verdict":"pass","summary":"no measurement was needed for this domain"}' > "$zs_none"
expect_valid "$zs_none" "--file artifact with no measurement citation stays valid"

# --- perf payload: evidence is REQUIRED, absence is not detected shape-by-shape ---
# Every spelling of "produced nothing" must be refused, or emitting less becomes
# the cheapest way past the gate. percentiles is a required perf_qa field.
# zs_perf_case <name> <perf_qa-payload> <expected-reason> [expected-detail-substring]
# The detail argument is what keeps the rejecting cases honest: several of these
# shapes are refused by DIFFERENT branches, and asserting only the shared reason
# lets any one branch be deleted while the suite stays green.
zs_perf_case() {
  local name="$1" payload="$2" want="$3" want_detail="${4:-}" path
  path="$worktree/tmp/review-external-20260815-07$(printf '%04d' "$PERF_N").json"
  PERF_N=$((PERF_N + 1))
  printf '{"agent":"reviewer-perf","verdict":"pass","summary":"s","blockers":[],"suggestions":[],"qa_metadata":{"perf_qa":%s}}' "$payload" > "$path"
  set +e
  local out
  out="$("$CHECK" --file "$path")"
  set -e
  assert_eq "$(jq -r '.reason' <<<"$out")" "$want" "--file perf payload $name -> $want"
  if [[ "$want" == "valid" ]]; then
    assert_eq "$(jq -r '.ok' <<<"$out")" "true" "--file perf payload $name is accepted"
  fi
  if [[ -n "$want_detail" ]]; then
    assert_substr "$(jq -r '.detail' <<<"$out")" "$want_detail" "--file perf payload $name is refused for the right reason"
  fi
}
PERF_N=1
zs_perf_case "percentiles missing entirely"   '{"regression_pct":0,"regressions":[],"platform":"linux","baseline_sha":"abc"}' zero_sample "declares no percentiles block"
zs_perf_case "percentiles null"               '{"percentiles":null}'                zero_sample "declares no percentiles block"
zs_perf_case "percentiles empty object"       '{"percentiles":{}}'                  zero_sample "percentiles is empty"
zs_perf_case "percentiles empty array"        '{"percentiles":[]}'                  zero_sample "percentiles is empty"
zs_perf_case "percentiles all-zero numbers"   '{"percentiles":{"p50":0,"p99":0}}'   zero_sample "no measured value above zero"
zs_perf_case "percentiles zero-valued strings" '{"percentiles":{"p50":"0ms","p99":"0ms"}}' zero_sample "no measured value above zero"
zs_perf_case "percentiles null leaves"        '{"percentiles":{"p50":null,"p99":null}}'   zero_sample "no measured value above zero"
zs_perf_case "percentiles a bare string"      '{"percentiles":"none recorded"}'     zero_sample "neither an object nor an array"
zs_perf_case "perf_qa itself not an object"   '"benchmarks ran"'                    zero_sample "perf_qa is not an object"
# ACCEPTING DIRECTION: one real measured value is enough, in either container
zs_perf_case "one real number among zeros"    '{"percentiles":{"p50":0,"p99":4.2}}' valid
zs_perf_case "percentiles as a populated array" '{"percentiles":[1.5,2.5]}'         valid
zs_perf_case "no perf_qa payload at all"      'null'                                valid

# --- declared instrument failure keeps the evidence and stays visible ---
# The gate must not suppress the finding class it exists to promote: a reviewer
# whose harness produced nothing declares it, keeps its numbers, and the
# declaration rides back out on the result.
zs_declared="$worktree/tmp/review-external-20260815-080808.json"
printf '{"agent":"reviewer-test","verdict":"action_required","summary":"harness produced nothing: mutation: killed 0/0","blockers":[],"suggestions":[],"qa_metadata":{"measurement_failed":"cargo-mutants selected 0 mutants for the changed file"}}' > "$zs_declared"
expect_valid "$zs_declared" "--file a declared measurement failure keeps its zero citation"
set +e
out="$("$CHECK" --file "$zs_declared")"
set -e
assert_eq "$(jq -r '.measurement_failed' <<<"$out")" "cargo-mutants selected 0 mutants for the changed file" "--file the declaration is echoed on the result"

zs_declared_perf="$worktree/tmp/review-external-20260815-081818.json"
printf '{"agent":"reviewer-perf","verdict":"action_required","summary":"s","blockers":[],"suggestions":[],"qa_metadata":{"measurement_failed":"bench runner emitted no samples","perf_qa":{"percentiles":{}}}}' > "$zs_declared_perf"
expect_valid "$zs_declared_perf" "--file a declared failure also covers an empty perf payload"

# MUST-FAIL CONTROLS on the escape: it is a declaration, not a field that exists
zs_blank="$worktree/tmp/review-external-20260815-082828.json"
printf '{"agent":"reviewer-test","verdict":"pass","summary":"mutation: killed 0/0","blockers":[],"suggestions":[],"qa_metadata":{"measurement_failed":"   "}}' > "$zs_blank"
set +e
out="$("$CHECK" --file "$zs_blank")"
rc=$?
set -e
assert_eq "$rc" "1" "--file a blank measurement_failed does not suppress the gate"
assert_eq "$(jq -r '.reason' <<<"$out")" "zero_sample" "--file blank declaration still reports zero_sample"

zs_nonstr="$worktree/tmp/review-external-20260815-083838.json"
printf '{"agent":"reviewer-test","verdict":"pass","summary":"mutation: killed 0/0","blockers":[],"suggestions":[],"qa_metadata":{"measurement_failed":true}}' > "$zs_nonstr"
set +e
out="$("$CHECK" --file "$zs_nonstr")"
rc=$?
set -e
assert_eq "$rc" "1" "--file a non-string measurement_failed does not suppress the gate"
assert_eq "$(jq -r '.reason' <<<"$out")" "zero_sample" "--file non-string declaration still reports zero_sample"

# an artifact with no declaration carries no measurement_failed field
set +e
out="$("$CHECK" --file "$zs_ok")"
set -e
assert_eq "$(jq -r 'has("measurement_failed")' <<<"$out")" "false" "--file an undeclared artifact carries no measurement_failed field"

# --- a gate that could not run is never silence (vstack#1497 review) ---
# Both gate helpers used to signal "no problem" with an empty string, so a jq
# failure — a torn read of a non-atomically written artifact — was
# indistinguishable from a clean artifact, and --wait's `out="$(glob_check)"`
# capture suspends errexit for the whole body, turning it into ok=true.
SHIM_DIR="$TMP_ROOT/jqshim"
mkdir -p "$SHIM_DIR"
REAL_JQ="$(command -v jq)"
printf '#!/usr/bin/env bash\nfor a in "$@"; do\n  case "$a" in\n    *"gate:zero-sample"*) echo "jq: error (at file): simulated torn read" >&2; exit 5 ;;\n  esac\ndone\nexec %s "$@"\n' "$REAL_JQ" > "$SHIM_DIR/jq"
chmod +x "$SHIM_DIR/jq"

set +e
out="$(PATH="$SHIM_DIR:$PATH" "$CHECK" --file "$zs_mut")"
rc=$?
set -e
assert_eq "$rc" "1" "--file a jq failure in a gate exits 1, not 0"
assert_eq "$(jq -r '.ok' <<<"$out")" "false" "--file a gate that could not run reports ok=false"
assert_eq "$(jq -r '.reason' <<<"$out")" "invalid" "--file a gate that could not run reports reason=invalid"
assert_substr "$(jq -r '.detail' <<<"$out")" "simulated torn read" "--file the gate failure carries jq's own diagnostic"

# ...and the --wait driver, where the capture-and-|| shape hid it
gwt="$TMP_ROOT/gatefail"
mkdir -p "$gwt/tmp"
printf '{"agent":"gf","verdict":"pass","summary":"mutation: killed 0/0; stability: 10/10 at 16 threads"}' > "$gwt/tmp/review-gf-20260101-000001.json"
set +e
out="$(PATH="$SHIM_DIR:$PATH" "$CHECK" "$gwt" gf 0 --wait 4 --interval 1 2>/dev/null)"
rc=$?
set -e
assert_eq "$(jq -r '.ok' <<<"$out")" "false" "--wait does NOT return ok=true when a gate could not run"
assert_eq "$(jq -r '.reason' <<<"$out")" "invalid" "--wait reports the gate failure as invalid"
assert_eq "$rc" "1" "--wait exits 1 on a gate failure"

# The same collapse exists on the PREDICATE side, where jq exit 1 (the answer
# is "no") and exit >=2 (the gate could not answer) would otherwise both read
# as "no problem". A jq that breaks only the no-review gate must not let the
# artifact fall through to some later gate's verdict.
PRED_SHIM="$TMP_ROOT/jqshim-pred"
mkdir -p "$PRED_SHIM"
printf '#!/usr/bin/env bash\nfor a in "$@"; do\n  case "$a" in\n    *"gate:no-review"*) echo "jq: error: simulated torn read" >&2; exit 5 ;;\n  esac\ndone\nexec %s "$@"\n' "$REAL_JQ" > "$PRED_SHIM/jq"
chmod +x "$PRED_SHIM/jq"
zs_pred="$worktree/tmp/review-external-20260815-091919.json"
printf '{"verdict":"pass","qa_metadata":{"review_performed":false,"reason":"no_scope_provided"}}' > "$zs_pred"
set +e
out="$(PATH="$PRED_SHIM:$PATH" "$CHECK" --file "$zs_pred")"
rc=$?
set -e
assert_eq "$rc" "1" "--file a broken predicate gate exits 1"
assert_eq "$(jq -r '.reason' <<<"$out")" "invalid" "--file a broken predicate gate reports invalid, not a later gate's verdict"
assert_substr "$(jq -r '.detail' <<<"$out")" "simulated torn read" "--file the predicate failure carries jq's own diagnostic"

# ...and with real jq the same artifact reports the predicate's real answer
set +e
out="$("$CHECK" --file "$zs_pred")"
set -e
assert_eq "$(jq -r '.reason' <<<"$out")" "no_review" "with real jq the predicate answers no_review"

# CONTROLS. The shim must be selective, or "invalid" above would just be jq
# being broken for everything: an artifact rejected by an EARLIER gate still
# reports that gate's own reason under the same shim.
zs_shim_ctl="$worktree/tmp/review-external-20260815-090909.json"
printf '{"verdict":"pass","qa_metadata":{"review_performed":false,"reason":"no_scope_provided"}}' > "$zs_shim_ctl"
set +e
out="$(PATH="$SHIM_DIR:$PATH" "$CHECK" --file "$zs_shim_ctl")"
set -e
assert_eq "$(jq -r '.reason' <<<"$out")" "no_review" "the shim breaks only the zero-sample gate; earlier gates still answer"

# ...and with real jq the same artifact and invocation report the real verdicts.
expect_valid "$zs_ok" "with real jq the clean artifact is valid, not invalid"
set +e
out="$("$CHECK" "$gwt" gf 0 --wait 4 --interval 1 2>/dev/null)"
set -e
assert_eq "$(jq -r '.reason' <<<"$out")" "zero_sample" "--wait with real jq still reports the real rejection"

# --- glob mode: zero_sample is TERMINAL, not advisory ---
# On a zero_sample hit the search used to record the rejection and keep walking,
# so any older-but-fresh sibling was returned ok=true — and the reviewer's own
# prescribed self-check uses boundary 0, which makes every prior artifact fresh.
zs_glob_ok="$worktree/tmp/review-reviewer-zs-20260815-100000.json"
printf '{"agent":"reviewer-zs","verdict":"pass","summary":"mutation: killed 3/3; stability: 10/10 at 16 threads"}' > "$zs_glob_ok"
zs_glob_bad="$worktree/tmp/review-reviewer-zs-20260815-110000.json"
printf '{"agent":"reviewer-zs","verdict":"pass","summary":"mutation: killed 0/0; stability: 0/0 at 16 threads"}' > "$zs_glob_bad"
touch -d "@$after" "$zs_glob_ok"
touch -d "@$later" "$zs_glob_bad"
set +e
out="$("$CHECK" "$worktree" reviewer-zs "$delegated_at")"
rc=$?
set -e
assert_eq "$rc" "1" "glob zero-sample is terminal, not rescued by an older sibling"
assert_eq "$(jq -r '.reason' <<<"$out")" "zero_sample" "glob terminal zero-sample keeps reason=zero_sample"
assert_eq "$(jq -r '.path' <<<"$out")" "$zs_glob_bad" "glob terminal zero-sample points at the rejected artifact"

# MUST-FAIL CONTROL: with the zero-sample artifact STALE, the fresh measured one
# is still the answer — terminal refuses THIS run, not the agent forever.
touch -d "@$before" "$zs_glob_bad"
expect_glob_valid "$worktree" reviewer-zs "$delegated_at" "$zs_glob_ok" "a STALE zero-sample artifact does not block a fresh measured one"

# the rejection reason is documented where reviewers read the rules
finding_schema="$REPO_ROOT/skills/reviewer/schemas/review-finding.md"
assert_file_contains "$finding_schema" "zero_sample" "review-finding.md documents the zero_sample rejection"
assert_file_contains "$finding_schema" "measurement_failed" "review-finding.md documents the declaration escape"


printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
