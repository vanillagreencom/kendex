#!/usr/bin/env bash
# `workflow-state increment <id> cycles` refuses once cycles is at
# REVIEW_MAX_CYCLES (default 4): the review loop ends at the cap, and the
# counter cannot drift past it. Other counters are unbounded. The failing
# direction runs first so a green pass is evidence.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

WS="$REPO_ROOT/skills/orch/scripts/workflow-state"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }

echo "=== workflow-state cycle cap ==="

sd="$TMP_ROOT/state"
"$WS" --state-dir "$sd" init KEN-1 --worktree "$REPO_ROOT" --branch ken-1 >/dev/null

# Default cap 4: four increments pass, the fifth refuses and leaves the count.
for i in 1 2 3 4; do
  "$WS" --state-dir "$sd" increment KEN-1 cycles >/dev/null
done
cycles="$("$WS" --state-dir "$sd" get KEN-1 .cycles)"
[[ "$cycles" == "4" ]] && ok "four increments reach the default cap of 4" \
  || bad "four increments reach the default cap of 4" "cycles=$cycles"

err="$("$WS" --state-dir "$sd" increment KEN-1 cycles 2>&1 >/dev/null)" && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] && [[ "$err" == *"cycles is at the cap (4 of REVIEW_MAX_CYCLES=4)"* ]] \
  && ok "the fifth increment refuses, naming the count and the cap" \
  || bad "the fifth increment refuses, naming the count and the cap" "rc=$rc err=$err"
[[ "$err" == *"verdict or submit step"* ]] && ok "the refusal names the step that follows" \
  || bad "the refusal names the step that follows" "$err"
cycles="$("$WS" --state-dir "$sd" get KEN-1 .cycles)"
[[ "$cycles" == "4" ]] && ok "a refused increment leaves cycles unchanged" \
  || bad "a refused increment leaves cycles unchanged" "cycles=$cycles"

# Other counters are not capped.
for i in 1 2 3 4 5; do
  "$WS" --state-dir "$sd" increment KEN-1 pr_comment_review.iterations >/dev/null
done
iterations="$("$WS" --state-dir "$sd" get KEN-1 .pr_comment_review.iterations)"
[[ "$iterations" == "5" ]] && ok "pr_comment_review.iterations is unbounded" \
  || bad "pr_comment_review.iterations is unbounded" "iterations=$iterations"

# The cap follows REVIEW_MAX_CYCLES from the environment.
"$WS" --state-dir "$sd" init KEN-2 --worktree "$REPO_ROOT" --branch ken-2 >/dev/null
REVIEW_MAX_CYCLES=2 "$WS" --state-dir "$sd" increment KEN-2 cycles >/dev/null
REVIEW_MAX_CYCLES=2 "$WS" --state-dir "$sd" increment KEN-2 cycles >/dev/null
err="$(REVIEW_MAX_CYCLES=2 "$WS" --state-dir "$sd" increment KEN-2 cycles 2>&1 >/dev/null)" && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] && [[ "$err" == *"(2 of REVIEW_MAX_CYCLES=2)"* ]] \
  && ok "REVIEW_MAX_CYCLES=2 refuses the third increment" \
  || bad "REVIEW_MAX_CYCLES=2 refuses the third increment" "rc=$rc err=$err"

# Two increments racing from cap-1: exactly one lands, the count stops at the cap.
"$WS" --state-dir "$sd" init KEN-3 --worktree "$REPO_ROOT" --branch ken-3 >/dev/null
"$WS" --state-dir "$sd" update KEN-3 '.cycles = 3' >/dev/null
"$WS" --state-dir "$sd" increment KEN-3 cycles >/dev/null 2>&1 & p1=$!
"$WS" --state-dir "$sd" increment KEN-3 cycles >/dev/null 2>&1 & p2=$!
wait "$p1" && r1=0 || r1=$?
wait "$p2" && r2=0 || r2=$?
cycles="$("$WS" --state-dir "$sd" get KEN-3 .cycles)"
[[ "$cycles" == "4" ]] && [[ $((r1 == 0 ? 1 : 0)) -ne $((r2 == 0 ? 1 : 0)) ]] \
  && ok "two increments racing from cap-1 land exactly one, cycles stops at the cap" \
  || bad "two increments racing from cap-1 land exactly one, cycles stops at the cap" "cycles=$cycles r1=$r1 r2=$r2"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
