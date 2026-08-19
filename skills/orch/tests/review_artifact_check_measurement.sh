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
REAL_JQ="$(command -v jq)"

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

# --- CARRIERS: .summary and .qa_metadata are the artifact's own measurements ---
# Scanning every string leaf left no honest route for quoting somebody else's
# zeroed run: the reviewer had to delete its evidence or declare an instrument
# failure that was not its own. The same text is a rejection in the summary and
# fine inside the finding it is evidence for — both directions pinned, or the
# scope is a comment rather than a rule.
zs_deep="$worktree/tmp/review-external-20260815-040404.json"
printf '{"agent":"reviewer-test","verdict":"action_required","summary":"s","blockers":[{"id":1,"title":"t","location":"src/x.rs (`f`)","description":"the fixture proves the gate rejects mutation: killed 0/0; stability: 0/0 at 16 threads","recommendation":"r","priority":2,"estimate":2}],"suggestions":[],"qa_metadata":{}}' > "$zs_deep"
expect_valid "$zs_deep" "--file a zeroed citation QUOTED in a blocker description is out of scope"

zs_deep_sugg="$worktree/tmp/review-external-20260815-041414.json"
printf '{"agent":"reviewer-test","verdict":"pass","summary":"s","blockers":[],"suggestions":[{"id":1,"title":"t","location":"tests/x.sh","description":"the fixture uses mutation: killed 0/0 as its control","recommendation":"r","priority":3,"estimate":1,"category":"fix"}],"qa_metadata":{}}' > "$zs_deep_sugg"
expect_valid "$zs_deep_sugg" "--file a zeroed citation quoted in a suggestion is out of scope"

zs_deep_q="$worktree/tmp/review-external-20260815-042424.json"
printf '{"agent":"reviewer-test","verdict":"pass","summary":"s","blockers":[],"suggestions":[],"questions":[{"id":1,"location":"general","question":"is mutation: killed 0/0 expected here?","draft_response":"d","source":"@x","source_id":"1","source_type":"inline"}],"qa_metadata":{}}' > "$zs_deep_q"
expect_valid "$zs_deep_q" "--file a zeroed citation quoted in a question is out of scope"

# ...and the SAME text in the artifact's own carriers still rejects, or the
# scoping would have disarmed the gate rather than aimed it.
zs_own_summary="$worktree/tmp/review-external-20260815-043434.json"
printf '{"agent":"reviewer-test","verdict":"pass","summary":"the fixture proves the gate rejects mutation: killed 0/0; stability: 0/0 at 16 threads","blockers":[],"suggestions":[],"qa_metadata":{}}' > "$zs_own_summary"
set +e
out="$("$CHECK" --file "$zs_own_summary")"
rc=$?
set -e
assert_eq "$rc" "1" "--file the same text in .summary still exits 1"
assert_eq "$(jq -r '.reason' <<<"$out")" "zero_sample" "--file a citation in .summary is the artifact's own measurement"
assert_substr "$(jq -r '.detail' <<<"$out")" "blocker or suggestion" "--file the rejection points at the honest route for quoted numbers"

zs_own_qa="$worktree/tmp/review-external-20260815-044444.json"
printf '{"agent":"reviewer-test","verdict":"pass","summary":"s","blockers":[],"suggestions":[],"qa_metadata":{"test_qa":{"note":"mutation: killed 0/0"}}}' > "$zs_own_qa"
set +e
out="$("$CHECK" --file "$zs_own_qa")"
rc=$?
set -e
assert_eq "$rc" "1" "--file a citation nested in qa_metadata still exits 1"
assert_eq "$(jq -r '.reason' <<<"$out")" "zero_sample" "--file qa_metadata is the artifact's own measurement payload"

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

# --- the declaration: top-level, substantive, and mechanically visible ---
# The escape must not require adopting the qa shape (that made following the
# rejection's own instruction dead-end in a second refusal), must not be
# satisfiable by any single character, and must not read as a plain green.
zs_declared="$worktree/tmp/review-external-20260815-080808.json"
printf '{"agent":"reviewer-test","verdict":"action_required","summary":"harness produced nothing: mutation: killed 0/0","blockers":[],"suggestions":[],"measurement_failed":"cargo-mutants selected 0 mutants for the changed file"}' > "$zs_declared"
set +e
out="$("$CHECK" --file "$zs_declared")"
rc=$?
set -e
assert_eq "$rc" "0" "--file a declared measurement failure is accepted"
assert_eq "$(jq -r '.ok' <<<"$out")" "true" "--file a declared measurement failure keeps its zero citation"
assert_eq "$(jq -r '.reason' <<<"$out")" "valid_undermeasured" "--file a declaration gets its own reason, not a plain valid"
assert_eq "$(jq -r '.measurement_failed' <<<"$out")" "cargo-mutants selected 0 mutants for the changed file" "--file the declaration is echoed on the result"

# THE DEAD END: an artifact in the tolerant shape (no qa_metadata) that adopts
# the escape must validate. Reaching the declaration used to require adding
# qa_metadata, which then demanded the finding arrays.
zs_tolerant="$worktree/tmp/review-external-20260815-080909.json"
printf '{"agent":"reviewer-test","verdict":"pass","summary":"mutation: killed 0/0","measurement_failed":"cargo-mutants selected 0 mutants for this module"}' > "$zs_tolerant"
set +e
out="$("$CHECK" --file "$zs_tolerant")"
rc=$?
set -e
assert_eq "$rc" "0" "--file the tolerant shape can adopt the escape without adding qa_metadata"
assert_eq "$(jq -r '.reason' <<<"$out")" "valid_undermeasured" "--file the tolerant-shape declaration is accepted as undermeasured"

zs_declared_perf="$worktree/tmp/review-external-20260815-081818.json"
printf '{"agent":"reviewer-perf","verdict":"action_required","summary":"s","blockers":[],"suggestions":[],"measurement_failed":"the bench runner emitted no samples for any lane","qa_metadata":{"perf_qa":{"percentiles":{}}}}' > "$zs_declared_perf"
set +e
out="$("$CHECK" --file "$zs_declared_perf")"
set -e
assert_eq "$(jq -r '.reason' <<<"$out")" "valid_undermeasured" "--file a declared failure also covers an empty perf payload"

# A declaration alongside verdict "pass" is still not a plain green — the reason
# is what an orchestrator branches on, and it says undermeasured.
zs_declared_pass="$worktree/tmp/review-external-20260815-082020.json"
printf '{"agent":"reviewer-test","verdict":"pass","summary":"mutation: killed 0/0","blockers":[],"suggestions":[],"measurement_failed":"cargo-mutants selected 0 mutants for the changed file"}' > "$zs_declared_pass"
set +e
out="$("$CHECK" --file "$zs_declared_pass")"
set -e
assert_eq "$(jq -r '.reason' <<<"$out")" "valid_undermeasured" "--file verdict pass plus a declaration is never reported as plain valid"
assert_eq "$(jq -r '.ok' <<<"$out")" "true" "--file verdict pass plus a declaration is still an accepted artifact"

# MUST-FAIL CONTROLS on the escape: it has to SAY something. Any single
# character used to open it.
# zs_decl_case <name> <json-literal> <expected-reason> [expected-detail-substring]
# The detail argument is load-bearing: these rejection branches OVERLAP (a null
# token is also short, bare punctuation is also short), so a verdict-only
# assertion lets any one of them be deleted while the suite stays green — the
# message is the only thing that distinguishes which branch answered, and the
# message is what the reviewer has to act on.
zs_decl_case() {
  local name="$1" literal="$2" want="$3" want_detail="${4:-}" path
  path="$worktree/tmp/review-external-20260815-083$(printf '%03d' "$DECL_N").json"
  DECL_N=$((DECL_N + 1))
  printf '{"agent":"reviewer-test","verdict":"pass","summary":"mutation: killed 0/0","blockers":[],"suggestions":[],"measurement_failed":%s}' "$literal" > "$path"
  set +e
  local out
  out="$("$CHECK" --file "$path")"
  set -e
  assert_eq "$(jq -r '.reason' <<<"$out")" "$want" "--file declaration $name -> $want"
  # The detail is "<what this branch found> — <the shared requirement>". The
  # requirement sentence necessarily quotes the very tokens the branches match
  # on ("null token", "characters", "bare punctuation"), so a needle tested
  # against the WHOLE string matches the boilerplate and pins nothing. Split on
  # the first em-dash and test each half against what only it can say.
  local detail branch bar
  detail="$(jq -r '.detail // ""' <<<"$out")"
  branch="${detail%% — *}"
  bar="${detail#* — }"
  if [[ "$want" == "invalid_declaration" ]]; then
    assert_eq "$(jq -r 'has("measurement_failed")' <<<"$out")" "false" "--file declaration $name is not echoed as a real declaration"
    assert_substr "$bar" "name the instrument" "--file declaration $name is told what a declaration must contain"
  fi
  if [[ -n "$want_detail" ]]; then
    assert_substr "$branch" "$want_detail" "--file declaration $name is refused by the right branch"
  fi
}
DECL_N=1
zs_decl_case "a single period"        '"."'            invalid_declaration "punctuation only"
zs_decl_case "n/a"                    '"n/a"'          invalid_declaration "null token"
zs_decl_case "N/A with punctuation"   '"N/A."'         invalid_declaration "null token"
zs_decl_case "none"                   '"none"'         invalid_declaration "null token"
zs_decl_case "unknown"                '"unknown"'      invalid_declaration "null token"
zs_decl_case "unavailable"            '"unavailable"'  invalid_declaration "null token"
zs_decl_case "tbd"                    '"tbd"'          invalid_declaration "null token"
zs_decl_case "bare punctuation"       '"---"'          invalid_declaration "punctuation only"
zs_decl_case "long bare punctuation"  '"---------------------------"' invalid_declaration "punctuation only"
zs_decl_case "whitespace only"        '"   "'          invalid_declaration "is blank"
zs_decl_case "one long word"          '"instrumentfailedbadly"' invalid_declaration "is 1 word(s)"
# Two words past the 20-character floor: only the word bar can refuse this, so
# it is what pins the constant. The three-word counterpart is the other side.
zs_decl_case "two words past the length floor" '"cargo-mutants produced-no-samples-at-all"' invalid_declaration "is 2 word(s)"
zs_decl_case "three words past the floor"      '"cargo-mutants selected zero-mutants"'      valid_undermeasured
zs_decl_case "three tiny words"       '"a b c"'        invalid_declaration "is 5 characters"
zs_decl_case "a boolean"              'true'           invalid_declaration "must be a string"
zs_decl_case "a number"               '0'              invalid_declaration "must be a string"
zs_decl_case "an object"              '{"why":"broke"}' invalid_declaration "must be a string"
zs_decl_case "an array"               '["broke"]'      invalid_declaration "must be a string"
zs_decl_case "null"                   'null'           zero_sample
# ...and the accepting direction: a real sentence naming the instrument
zs_decl_case "a real declaration"     '"cargo-mutants selected 0 mutants"' valid_undermeasured

# The declaration is read in ONE place, so the echoed value and the decision to
# skip the gate cannot disagree. Walk the boundary either side of the bar.
zs_boundary() {
  local literal="$1" want_reason="$2" want_echo="$3" name="$4" path out
  path="$worktree/tmp/review-external-20260815-084$(printf '%03d' "$DECL_N").json"
  DECL_N=$((DECL_N + 1))
  printf '{"agent":"reviewer-test","verdict":"pass","summary":"mutation: killed 0/0","blockers":[],"suggestions":[],"measurement_failed":%s}' "$literal" > "$path"
  set +e
  out="$("$CHECK" --file "$path")"
  set -e
  assert_eq "$(jq -r '.reason' <<<"$out")" "$want_reason" "--file boundary $name reason"
  assert_eq "$(jq -r '.measurement_failed // "-"' <<<"$out")" "$want_echo" "--file boundary $name echo agrees with the decision"
}
# 19 characters, 3 words: one short of the bar. A present-but-inadequate
# declaration is refused on its OWN terms rather than silently ignored — the
# reviewer meant to declare something, and dropping it would hide the
# instrument failure the same way deleting the numbers would.
zs_boundary '"aa bbbb ccccccccccc"' invalid_declaration - "19 characters"
# 20 characters, 3 words: exactly the bar
zs_boundary '"aa bbbb cccccccccccc"' valid_undermeasured "aa bbbb cccccccccccc" "20 characters"

# an artifact with no declaration carries no measurement_failed field
set +e
out="$("$CHECK" --file "$zs_ok")"
set -e
assert_eq "$(jq -r 'has("measurement_failed")' <<<"$out")" "false" "--file an undeclared artifact carries no measurement_failed field"

# --- the escape suppresses ONE gate, wherever its block sits ---
# The declaration's blast radius used to be a consequence of statement order:
# hoisting its block to the first step of artifact_content_gates turned
# `review_performed: false` into an ACCEPTED valid_undermeasured, and a consumer
# reading the contract saw a legitimate state rather than an anomaly. These
# assertions state the radius as behavior, so the containment survives any
# reordering — and they go red the moment the escape short-circuits again.
DECLARATION='"measurement_failed":"cargo-mutants selected 0 mutants for the changed file"'

zs_radius() {
  local name="$1" body="$2" want="$3" path out
  path="$worktree/tmp/review-external-20260816-01$(printf '%04d' "$RADIUS_N").json"
  RADIUS_N=$((RADIUS_N + 1))
  printf '%s' "$body" > "$path"
  set +e
  out="$("$CHECK" --file "$path")"
  set -e
  assert_eq "$(jq -r '.reason' <<<"$out")" "$want" "--file a valid declaration does NOT suppress $name"
}
RADIUS_N=1
zs_radius "the no-review gate" \
  "{\"verdict\":\"pass\",\"summary\":\"mutation: killed 0/0\",\"blockers\":[],\"suggestions\":[],$DECLARATION,\"qa_metadata\":{\"review_performed\":false,\"reason\":\"no_scope_provided\"}}" \
  no_review
zs_radius "the finding-item gate" \
  "{\"verdict\":\"pass\",\"summary\":\"mutation: killed 0/0\",\"blockers\":[],\"suggestions\":[{\"title\":\"t\",\"detail\":\"d\"}],$DECLARATION,\"qa_metadata\":{}}" \
  incomplete
zs_radius "the qa-shape gate" \
  "{\"verdict\":\"pass\",\"summary\":\"mutation: killed 0/0\",$DECLARATION,\"qa_metadata\":{}}" \
  incomplete
zs_radius "the missing-verdict gate" \
  "{\"agent\":\"r\",\"summary\":\"mutation: killed 0/0\",$DECLARATION}" \
  invalid

# ...and the ONE gate it does suppress, so the radius is bounded on both sides.
zs_radius "(control) the zero-sample gate, which it DOES replace" \
  "{\"verdict\":\"pass\",\"summary\":\"mutation: killed 0/0\",\"blockers\":[],\"suggestions\":[],$DECLARATION,\"qa_metadata\":{}}" \
  valid_undermeasured

# --- glob mode reaches invalid_declaration too, and it is terminal ---
# The most likely reviewer behavior after a zeroed instrument: reach for the
# escape, write something under the bar. Falling back handed that reviewer an
# older artifact and called it valid.
zs_decl_glob_ok="$worktree/tmp/review-reviewer-decl-20260816-100000.json"
printf '{"agent":"reviewer-decl","verdict":"pass","summary":"mutation: killed 3/3; stability: 10/10 at 16 threads","blockers":[],"suggestions":[]}' > "$zs_decl_glob_ok"
zs_decl_glob_bad="$worktree/tmp/review-reviewer-decl-20260816-110000.json"
printf '{"agent":"reviewer-decl","verdict":"pass","summary":"mutation: killed 0/0","blockers":[],"suggestions":[],"measurement_failed":"n/a"}' > "$zs_decl_glob_bad"
touch -d "@$after" "$zs_decl_glob_ok"
touch -d "@$later" "$zs_decl_glob_bad"
set +e
out="$("$CHECK" "$worktree" reviewer-decl "$delegated_at")"
rc=$?
set -e
assert_eq "$rc" "1" "glob invalid_declaration is terminal, not rescued by an older sibling"
assert_eq "$(jq -r '.reason' <<<"$out")" "invalid_declaration" "glob terminal invalid_declaration keeps its reason"
assert_eq "$(jq -r '.path' <<<"$out")" "$zs_decl_glob_bad" "glob terminal invalid_declaration points at the rejected artifact"

touch -d "@$before" "$zs_decl_glob_bad"
expect_glob_valid "$worktree" reviewer-decl "$delegated_at" "$zs_decl_glob_ok" "a STALE invalid_declaration artifact does not block a fresh measured one"
touch -d "@$later" "$zs_decl_glob_bad"

# --- a declaration records what it silenced ---
# The declaration covers whatever the measurement gate would have said,
# including a perf payload the named instrument has nothing to do with. That is
# allowed; doing it invisibly is the shape this issue is about.
zs_sup="$worktree/tmp/review-external-20260817-010101.json"
printf '{"agent":"reviewer-perf","verdict":"pass","summary":"s","blockers":[],"suggestions":[],"measurement_failed":"cargo-mutants selected 0 mutants for the changed file","qa_metadata":{"perf_qa":{"percentiles":{"p50":0,"p99":0}}}}' > "$zs_sup"
set +e
out="$("$CHECK" --file "$zs_sup")"
rc=$?
set -e
assert_eq "$rc" "0" "a declaration still accepts an artifact whose perf payload measured nothing"
assert_eq "$(jq -r '.reason' <<<"$out")" "valid_undermeasured" "the suppressed-perf artifact is undermeasured, not plain valid"
assert_substr "$(jq -r '.measurement_suppressed // ""' <<<"$out")" "percentiles carries no measured value above zero" "the result names the perf measurement the mutation declaration silenced"

# a citation silenced by the declaration is recorded the same way
zs_sup_cite="$worktree/tmp/review-external-20260817-020202.json"
printf '{"agent":"reviewer-test","verdict":"pass","summary":"mutation: killed 0/0","blockers":[],"suggestions":[],"measurement_failed":"cargo-mutants selected 0 mutants for the changed file"}' > "$zs_sup_cite"
set +e
out="$("$CHECK" --file "$zs_sup_cite")"
set -e
assert_substr "$(jq -r '.measurement_suppressed // ""' <<<"$out")" "killed 0/0" "the result names the citation the declaration silenced"
# ...and the recorded finding is the finding, not the rejection's instructions
assert_eq "$(jq -r '.measurement_suppressed | test("measurement_failed")' <<<"$out")" "false" "the suppression record carries the finding, not remedy text for a rejection that did not happen"

# MUST-FAIL CONTROL: a declaration with nothing to silence records nothing.
zs_sup_none="$worktree/tmp/review-external-20260817-030303.json"
printf '{"agent":"reviewer-test","verdict":"pass","summary":"mutation: killed 3/3; stability: 10/10 at 16 threads","blockers":[],"suggestions":[],"measurement_failed":"cargo-mutants selected 0 mutants for the changed file"}' > "$zs_sup_none"
set +e
out="$("$CHECK" --file "$zs_sup_none")"
set -e
assert_eq "$(jq -r 'has("measurement_suppressed")' <<<"$out")" "false" "a declaration with nothing to silence carries no suppression record"
assert_eq "$(jq -r '.reason' <<<"$out")" "valid_undermeasured" "that artifact is still undermeasured"

# ...and an artifact with no declaration never carries one either.
set +e
out="$("$CHECK" --file "$zs_ok")"
set -e
assert_eq "$(jq -r 'has("measurement_suppressed")' <<<"$out")" "false" "an undeclared artifact carries no suppression record"

# --- THE FALLBACK CONTRACT, which is now a single case ---
# After the qa-shape gate was reclassified, "the gate could not run" is the only
# content rejection that may be answered by an older sibling — so this one case
# IS the torn-write half of the disposition rule. It is also the case the rule
# was written around: reviewer artifacts are written non-atomically, a torn read
# makes jq fail on THAT file, and the intact sibling beside it is the same
# review written whole.
TORN_SHIM="$TMP_ROOT/jqshim-torn"
mkdir -p "$TORN_SHIM"
# Fails one CONTENT gate, and only for the newest artifact — so this exercises
# the gate's disposition rather than the per-file `.verdict` branch.
printf '#!/usr/bin/env bash\nprog=""; target=""\nfor a in "$@"; do\n  case "$a" in\n    *"gate:no-review"*) prog=1 ;;\n    *torn-newest*) target=1 ;;\n  esac\ndone\nif [ -n "$prog" ] && [ -n "$target" ]; then echo "jq: error: simulated torn read" >&2; exit 5; fi\nexec %s "$@"\n' "$REAL_JQ" > "$TORN_SHIM/jq"
chmod +x "$TORN_SHIM/jq"

twt="$TMP_ROOT/tornwt"
mkdir -p "$twt/tmp"
torn_ok="$twt/tmp/review-torn-20260101-000001.json"
printf '{"agent":"torn","verdict":"pass","summary":"mutation: killed 3/3; stability: 10/10 at 16 threads","blockers":[],"suggestions":[],"qa_metadata":{}}' > "$torn_ok"
torn_new="$twt/tmp/review-torn-newest-20260101-000002.json"
printf '{"agent":"torn","verdict":"pass","summary":"clean","blockers":[],"suggestions":[],"qa_metadata":{}}' > "$torn_new"
touch -d "@$after" "$torn_ok"
touch -d "@$later" "$torn_new"

# The torn artifact ALONE is rejected — the fallback is a real answer, not an
# absence of gating.
set +e
out="$(PATH="$TORN_SHIM:$PATH" "$CHECK" --file "$torn_new")"
rc=$?
set -e
assert_eq "$rc" "1" "a gate that could not run rejects the artifact on its own"
assert_eq "$(jq -r '.reason' <<<"$out")" "invalid" "a gate that could not run reports reason=invalid"

# ...and in glob mode it falls back to the intact sibling, because THIS file may
# simply have been read mid-write.
set +e
out="$(PATH="$TORN_SHIM:$PATH" "$CHECK" "$twt" torn "$delegated_at")"
rc=$?
set -e
assert_eq "$rc" "0" "glob falls back past a gate that could not run"
assert_eq "$(jq -r '.ok' <<<"$out")" "true" "glob accepts the intact sibling beside a torn artifact"
assert_eq "$(jq -r '.path' <<<"$out")" "$torn_ok" "glob fallback selects the intact sibling"

# MUST-FAIL CONTROL: with real jq the newest artifact answers for itself, so the
# fallback above is the shim's doing and not the sibling always winning.
set +e
out="$("$CHECK" "$twt" torn "$delegated_at")"
set -e
assert_eq "$(jq -r '.path' <<<"$out")" "$torn_new" "with real jq the newest artifact is the answer"

# --- the fail-closed default behind the rule ---
# The predicate is what protects a gate added later that forgets to classify
# itself. Asserted directly, because every gate present does classify itself so
# no artifact can reach the default. Run in a child shell: sourcing the lib here
# would install its own EXIT trap over this suite's and leak $TMP_ROOT.
disp_out="$(bash -c '
  source "$1/skills/orch/scripts/lib/review-artifact-gates.sh"
  for d in torn_write terminal "" typo_write; do
    review_artifact_disposition="$d"
    if disposition_allows_fallback; then
      printf "%s=fallback\n" "${d:-unset}"
    else
      printf "%s=terminal\n" "${d:-unset}"
    fi
  done
' _ "$REPO_ROOT" 2>/dev/null)"
assert_eq "$(printf '%s' "$disp_out" | grep -c .)" "4" "the disposition predicate answered for all four inputs"
assert_substr "$disp_out" "torn_write=fallback" "an explicit torn_write allows the fallback"
assert_substr "$disp_out" "terminal=terminal" "an explicit terminal refuses the fallback"
assert_substr "$disp_out" "unset=terminal" "an UNSET disposition is treated as terminal — a gate that forgets to classify itself fails closed"
assert_substr "$disp_out" "typo_write=terminal" "an unrecognised disposition is treated as terminal"

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
