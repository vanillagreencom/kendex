#!/usr/bin/env bash
# `workflow-state set <id> rereview_panel <json>` — the write review-pr § 4
# makes when it re-enters § 2 — refuses once cycles is past REVIEW_MAX_CYCLES
# (default 4). The write AT the cap is the one verification pass the rule
# allows. `increment … cycles` itself stays unbounded: QA and submit flows
# bump it too. The failing direction runs first so a green pass is evidence.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

WS="$REPO_ROOT/skills/orch/scripts/workflow-state"
PANEL='{"agents": ["rev-a"], "reason": "test"}'

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }

echo "=== workflow-state re-review cycle cap ==="

sd="$TMP_ROOT/state"
"$WS" --state-dir "$sd" init KEN-1 --worktree "$REPO_ROOT" --branch ken-1 >/dev/null

# Past the cap: cycles=5 refuses the re-entry and leaves the state alone.
"$WS" --state-dir "$sd" update KEN-1 '.cycles = 5' >/dev/null
err="$("$WS" --state-dir "$sd" set KEN-1 rereview_panel "$PANEL" 2>&1 >/dev/null)" && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] && [[ "$err" == *"cycles is past the cap (5 > REVIEW_MAX_CYCLES=4)"* ]] \
  && ok "cycles=5 refuses rereview_panel, naming the count and the cap" \
  || bad "cycles=5 refuses rereview_panel, naming the count and the cap" "rc=$rc err=$err"
[[ "$err" == *"review-pr § 5"* ]] && ok "the refusal names the step that follows" \
  || bad "the refusal names the step that follows" "$err"
# The refusal is the instruction the orchestrator reads at the moment the cap
# fires, so it must carry the WHOLE § 4 contract. Asserting it on the message
# the refusal actually prints proves the branch is reachable, which grepping
# the source for the same text does not.
[[ "$err" == *escalated_items* ]] && ok "the refusal names the escalated_items recording step" \
  || bad "the refusal names the escalated_items recording step" "$err"
[[ "$err" == *"review-pr § 4"* ]] && ok "the refusal points at § 4's capped-items procedure" \
  || bad "the refusal points at § 4's capped-items procedure" "$err"
# Wording that stops only the re-review cycle reads as licensing one more fix
# round, and the items escalated after it would predate that round's diff.
[[ "$err" == *"no further fix round"* ]] && ok "the refusal forbids a further fix round, not just a cycle" \
  || bad "the refusal forbids a further fix round, not just a cycle" "$err"
# Naming only the escalated half re-creates the both-buckets collision § 4 was
# rewritten to prevent: a re-blocked finding keeps its stale fixed_items entry
# and § 8 prints it as FIXED and ESCALATED at once.
[[ "$err" == *fixed_items* ]] && [[ "$err" == *"same write"* ]] \
  && ok "the refusal states the fixed_items drop rides the same write" \
  || bad "the refusal states the fixed_items drop rides the same write" "$err"
panel="$("$WS" --state-dir "$sd" get KEN-1 .rereview_panel)"
[[ "$panel" == "null" ]] && ok "a refused write leaves rereview_panel unset" \
  || bad "a refused write leaves rereview_panel unset" "panel=$panel"

# At the cap: the verification pass is allowed.
"$WS" --state-dir "$sd" update KEN-1 '.cycles = 4' >/dev/null
"$WS" --state-dir "$sd" set KEN-1 rereview_panel "$PANEL" >/dev/null && rc=0 || rc=$?
agents="$("$WS" --state-dir "$sd" get KEN-1 '.rereview_panel.agents[0]')"
[[ "$rc" -eq 0 ]] && [[ "$agents" == "rev-a" ]] && ok "cycles=4 (at the cap) still records the verification pass panel" \
  || bad "cycles=4 (at the cap) still records the verification pass panel" "rc=$rc agents=$agents"

# The counter itself is unbounded: QA and submit flows bump it too.
for i in 1 2 3; do
  "$WS" --state-dir "$sd" increment KEN-1 cycles >/dev/null
done
cycles="$("$WS" --state-dir "$sd" get KEN-1 .cycles)"
[[ "$cycles" == "7" ]] && ok "increment … cycles is unbounded" \
  || bad "increment … cycles is unbounded" "cycles=$cycles"

# Other set fields are untouched by the cap.
"$WS" --state-dir "$sd" set KEN-1 rereview_skipped "no files changed" >/dev/null && rc=0 || rc=$?
[[ "$rc" -eq 0 ]] && ok "set of another field passes with cycles past the cap" \
  || bad "set of another field passes with cycles past the cap" "rc=$rc"

# The cap follows REVIEW_MAX_CYCLES from the environment.
"$WS" --state-dir "$sd" init KEN-2 --worktree "$REPO_ROOT" --branch ken-2 >/dev/null
"$WS" --state-dir "$sd" update KEN-2 '.cycles = 3' >/dev/null
err="$(REVIEW_MAX_CYCLES=2 "$WS" --state-dir "$sd" set KEN-2 rereview_panel "$PANEL" 2>&1 >/dev/null)" && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] && [[ "$err" == *"(3 > REVIEW_MAX_CYCLES=2)"* ]] \
  && ok "REVIEW_MAX_CYCLES=2 refuses at cycles=3" \
  || bad "REVIEW_MAX_CYCLES=2 refuses at cycles=3" "rc=$rc err=$err"

# Planted control: a refusal carrying only the escalated half. The assertion
# above must go red on it, or it is pinning nothing the round-1 wording did not
# already satisfy.
echo
echo "--- planted control ---"

CTRL_SCRIPTS="$TMP_ROOT/scripts"
cp -R "$REPO_ROOT/skills/orch/scripts" "$CTRL_SCRIPTS"
sed 's/ and drops its superseded fixed_items entry in the same write//' "$WS" > "$CTRL_SCRIPTS/workflow-state"
chmod +x "$CTRL_SCRIPTS/workflow-state"
if cmp -s "$CTRL_SCRIPTS/workflow-state" "$WS"; then
  bad "supersede control planted nothing — its sed program matched no text"
else
  sdc="$TMP_ROOT/state-ctrl"
  "$CTRL_SCRIPTS/workflow-state" --state-dir "$sdc" init KEN-3 --worktree "$REPO_ROOT" --branch ken-3 >/dev/null
  "$CTRL_SCRIPTS/workflow-state" --state-dir "$sdc" update KEN-3 '.cycles = 5' >/dev/null
  cerr="$("$CTRL_SCRIPTS/workflow-state" --state-dir "$sdc" set KEN-3 rereview_panel "$PANEL" 2>&1 >/dev/null)" || true
  if [[ "$cerr" != *escalated_items* ]]; then
    bad "the control refusal still prints its escalated half" "$cerr"
  elif [[ "$cerr" == *fixed_items* ]] && [[ "$cerr" == *"same write"* ]]; then
    bad "the assertion MISSED a refusal that names only the escalated half" "$cerr"
  else
    ok "the assertion flags a refusal that names only the escalated half"
  fi
fi

# The pre-fix wording: only the re-review cycle is stopped, which leaves a
# post-cap fix round licensed.
sed 's/ and no further fix round//' "$WS" > "$CTRL_SCRIPTS/workflow-state"
chmod +x "$CTRL_SCRIPTS/workflow-state"
if cmp -s "$CTRL_SCRIPTS/workflow-state" "$WS"; then
  bad "fix-round control planted nothing — its sed program matched no text"
else
  sdf="$TMP_ROOT/state-ctrl-fix"
  "$CTRL_SCRIPTS/workflow-state" --state-dir "$sdf" init KEN-4 --worktree "$REPO_ROOT" --branch ken-4 >/dev/null
  "$CTRL_SCRIPTS/workflow-state" --state-dir "$sdf" update KEN-4 '.cycles = 5' >/dev/null
  ferr="$("$CTRL_SCRIPTS/workflow-state" --state-dir "$sdf" set KEN-4 rereview_panel "$PANEL" 2>&1 >/dev/null)" || true
  if [[ "$ferr" != *"no further re-review cycle"* ]]; then
    bad "the control refusal stopped printing at all" "$ferr"
  elif [[ "$ferr" == *"no further fix round"* ]]; then
    bad "the assertion MISSED a refusal that stops only the re-review cycle" "$ferr"
  else
    ok "the assertion flags a refusal that stops only the re-review cycle"
  fi
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
