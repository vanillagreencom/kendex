#!/usr/bin/env bash
# Regression tests for `local-review-budget` (VST-153).
#
# The local pre-PR review budget was counted per SUBMISSION: two passes ever,
# regardless of how many heads the branch went through. GitHub bots re-review
# every push — a new head is a new round — so the budget is now counted per
# pushed head: `pr_local_review.passes` is attributed to
# `pr_local_review.reviewed_head`, and the check resets the counter when the
# worktree head no longer matches the recorded one.
#
# These tests pin the reset-on-new-head behavior, the within-head cap, and the
# usage/error contract.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
BUDGET="$SKILL_DIR/scripts/local-review-budget"
WS="$SKILL_DIR/scripts/workflow-state"
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

SD="$TMP_ROOT/state"
ISSUE="VST-153"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }

assert_field() {
  local out="$1" field="$2" want="$3" name="$4" got
  got="$(jq -r ".$field" <<<"$out")"
  if [[ "$got" == "$want" ]]; then pass "$name"
  else fail "$name (want $field=$want, got $got)"; fi
}

assert_status() {
  local got="$1" want="$2" name="$3"
  if [[ "$got" -eq "$want" ]]; then pass "$name"
  else fail "$name (want exit $want, got $got)"; fi
}

HEAD_A="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
HEAD_B="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

echo "=== usage and error contract ==="

set +e
"$BUDGET" --state-dir "$SD" --head "$HEAD_A" >/dev/null 2>&1
no_issue=$?
"$BUDGET" --state-dir "$SD" "$ISSUE" >/dev/null 2>&1
no_source=$?
"$BUDGET" --state-dir "$SD" "$ISSUE" --worktree "$TMP_ROOT" --head "$HEAD_A" >/dev/null 2>&1
both_sources=$?
"$BUDGET" --state-dir "$SD" "$ISSUE" --head "not-a-sha" >/dev/null 2>&1
bad_sha=$?
"$BUDGET" --state-dir "$SD" "$ISSUE" --head "$HEAD_A" >/dev/null 2>&1
no_state=$?
set -e
assert_status "$no_issue" 2 "missing ISSUE_ID is rejected"
assert_status "$no_source" 2 "missing --worktree/--head is rejected"
assert_status "$both_sources" 2 "--worktree plus --head is rejected"
assert_status "$bad_sha" 2 "a non-SHA head is rejected"
assert_status "$no_state" 1 "missing state file errors instead of creating state"

echo "=== first check on fresh state starts round 0 under the current head ==="

"$WS" --state-dir "$SD" init "$ISSUE" --worktree "$TMP_ROOT" --branch issue-vst-153 >/dev/null

OUT="$("$BUDGET" --state-dir "$SD" "$ISSUE" --head "$HEAD_A")"
assert_field "$OUT" passes "0" "fresh state reports 0 passes"
assert_field "$OUT" exhausted "false" "…and is not exhausted"
assert_field "$OUT" reset "true" "…and reports the round reset (nothing was recorded)"
assert_field "$OUT" reviewed_head "" "…with an empty prior recorded head"

recorded="$("$WS" --state-dir "$SD" get "$ISSUE" '.pr_local_review.reviewed_head')"
assert_status "$([[ "$recorded" == "$HEAD_A" ]]; echo $?)" 0 "the current head is stamped into state"

echo "=== the 2-pass cap binds within a single head ==="

"$WS" --state-dir "$SD" increment "$ISSUE" pr_local_review.passes >/dev/null
OUT="$("$BUDGET" --state-dir "$SD" "$ISSUE" --head "$HEAD_A")"
assert_field "$OUT" passes "1" "one counted pass at the same head reports 1"
assert_field "$OUT" exhausted "false" "…still under the cap"
assert_field "$OUT" reset "false" "…with no reset"

"$WS" --state-dir "$SD" increment "$ISSUE" pr_local_review.passes >/dev/null
OUT="$("$BUDGET" --state-dir "$SD" "$ISSUE" --head "$HEAD_A")"
assert_field "$OUT" passes "2" "two counted passes at the same head report 2"
assert_field "$OUT" exhausted "true" "…and the budget is exhausted"
assert_field "$OUT" max_passes "2" "…against the documented cap of 2"

echo "=== a new head is a new round: the counter resets ==="

# Per-SUBMISSION accounting would keep passes=2 here — this is the assertion
# that fails against the pre-VST-153 behavior.
OUT="$("$BUDGET" --state-dir "$SD" "$ISSUE" --head "$HEAD_B")"
assert_field "$OUT" passes "0" "a different head restarts the counter at 0"
assert_field "$OUT" exhausted "false" "…so the budget is available again"
assert_field "$OUT" reset "true" "…and the reset is reported"
assert_field "$OUT" reviewed_head "$HEAD_A" "…naming the previously recorded head"

recorded="$("$WS" --state-dir "$SD" get "$ISSUE" '.pr_local_review.reviewed_head')"
assert_status "$([[ "$recorded" == "$HEAD_B" ]]; echo $?)" 0 "state now records the new head"
passes_state="$("$WS" --state-dir "$SD" get "$ISSUE" '.pr_local_review.passes')"
assert_status "$([[ "$passes_state" == "0" ]]; echo $?)" 0 "state counter restarted at 0"

echo "=== the reset merges, never clobbers, sibling pr_local_review keys ==="

"$WS" --state-dir "$SD" set "$ISSUE" pr_local_review.extra keepme >/dev/null
"$BUDGET" --state-dir "$SD" "$ISSUE" --head "$HEAD_A" >/dev/null
extra="$("$WS" --state-dir "$SD" get "$ISSUE" '.pr_local_review.extra')"
assert_status "$([[ "$extra" == "keepme" ]]; echo $?)" 0 "sibling keys survive a round reset"

echo "=== --worktree reads the real HEAD ==="

REPO="$TMP_ROOT/repo"
git init -q "$REPO"
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m one
OUT="$("$BUDGET" --state-dir "$SD" "$ISSUE" --worktree "$REPO")"
head1="$(git -C "$REPO" rev-parse HEAD)"
assert_field "$OUT" head "$head1" "--worktree resolves the worktree's HEAD"
assert_field "$OUT" reset "true" "…and a real-HEAD change resets the round"

"$WS" --state-dir "$SD" increment "$ISSUE" pr_local_review.passes >/dev/null
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m two
OUT="$("$BUDGET" --state-dir "$SD" "$ISSUE" --worktree "$REPO")"
assert_field "$OUT" passes "0" "a new commit in the worktree restarts the counter"
assert_field "$OUT" reviewed_head "$head1" "…reporting the superseded head"

echo "=== uppercase SHAs normalize instead of resetting the round ==="

HEAD_C="cccccccccccccccccccccccccccccccccccccccc"
HEAD_C_UPPER="CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"
"$BUDGET" --state-dir "$SD" "$ISSUE" --head "$HEAD_C" >/dev/null
"$WS" --state-dir "$SD" increment "$ISSUE" pr_local_review.passes >/dev/null
OUT="$("$BUDGET" --state-dir "$SD" "$ISSUE" --head "$HEAD_C_UPPER")"
assert_field "$OUT" reset "false" "an uppercase spelling of the same head is not a new round"
assert_field "$OUT" passes "1" "…and keeps the counted pass"
assert_field "$OUT" head "$HEAD_C" "…reporting the normalized head"

echo "=== transient bookkeeping never leaks into state ==="

prior="$("$WS" --state-dir "$SD" get "$ISSUE" '.pr_local_review | has("prior_head")')"
assert_status "$([[ "$prior" == "false" ]]; echo $?)" 0 "no transient keys land in state"

echo "=== bare flags stay on the documented exit-2 usage path ==="

for flag in --state-dir --worktree --head --count; do
  rc=0
  "$BUDGET" "$ISSUE" "$flag" >/dev/null 2>&1 || rc=$?
  assert_status "$rc" 2 "bare $flag exits 2, not a bash expansion abort"
done

rc=0
"$BUDGET" --state-dir= "$ISSUE" --head "$HEAD_C" >/dev/null 2>&1 || rc=$?
assert_status "$rc" 2 "empty equals-form --state-dir= exits 2 instead of silently dropping the override"

echo "=== --count attributes a completed pass atomically ==="

HEAD_D="dddddddddddddddddddddddddddddddddddddddd"
HEAD_E="eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
"$BUDGET" --state-dir "$SD" "$ISSUE" --head "$HEAD_D" >/dev/null
"$WS" --state-dir "$SD" set "$ISSUE" pr_local_review.extra keepme2 >/dev/null
OUT="$("$BUDGET" --state-dir "$SD" "$ISSUE" --count "$HEAD_D")"
assert_field "$OUT" passes "1" "matching head increments to one pass"
assert_field "$OUT" reviewed_head "$HEAD_D" "…attributed to the counted head"
OUT="$("$BUDGET" --state-dir "$SD" "$ISSUE" --count "$HEAD_D")"
assert_field "$OUT" passes "2" "second count on the same head increments"
OUT="$("$BUDGET" --state-dir "$SD" "$ISSUE" --count "$HEAD_E")"
assert_field "$OUT" passes "1" "a different artifact head initializes at one pass, never inheriting"
assert_field "$OUT" reviewed_head "$HEAD_E" "…and re-attributes to the new head"
extra="$("$WS" --state-dir "$SD" get "$ISSUE" '.pr_local_review.extra')"
assert_status "$([[ "$extra" == "keepme2" ]]; echo $?)" 0 "count-mode re-attribution preserves sibling keys"

rc=0
"$BUDGET" --state-dir "$SD" "$ISSUE" --count 'bad"; .x = 1; "' >/dev/null 2>&1 || rc=$?
assert_status "$rc" 2 "malformed artifact head is refused before any state write"
rc=0
"$BUDGET" --state-dir "$SD" "$ISSUE" --count "$HEAD_D" --head "$HEAD_E" >/dev/null 2>&1 || rc=$?
assert_status "$rc" 2 "--count combined with --head is a usage error"

echo "=== update-report: concurrent calls each get exactly their own evidence ==="

# Ten overlapping update-report calls increment one counter; the lock must
# serialize them so the state lands at 10 and the ten printed reports are a
# permutation of 1..10 — no lost update, no cross-read report.
"$WS" --state-dir "$SD" set "$ISSUE" race_counter 0 >/dev/null
RACE_OUT="$TMP_ROOT/race-reports"
: >"$RACE_OUT"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  "$WS" --state-dir "$SD" update-report "$ISSUE" \
    '((.race_counter // 0) + 1) as $n | {state: (.race_counter = $n), report: {n: $n}}' \
    >>"$RACE_OUT" &
done
wait
final="$("$WS" --state-dir "$SD" get "$ISSUE" '.race_counter')"
assert_status "$([[ "$final" == "10" ]]; echo $?)" 0 "ten concurrent update-reports serialize to a final count of 10"
distinct="$(jq -r '.n' "$RACE_OUT" | sort -n | uniq | wc -l | tr -d ' ')"
assert_status "$([[ "$distinct" == "10" ]]; echo $?)" 0 "each call reported a distinct transition (no report cross-read)"

rc=0
"$WS" --state-dir "$SD" update-report "$ISSUE" '{state: ., report: 1}, {state: ., report: 2}' >/dev/null 2>&1 || rc=$?
assert_status "$rc" 1 "a multi-object update-report stream is rejected, not written"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
