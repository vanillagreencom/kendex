#!/usr/bin/env bash
# `workflow-state set <id> rereview_panel <json>` — the write review-pr § 4
# makes when it re-enters § 2 — is itself the re-review cycle: it raises
# `rereview_cycles` under the same lock it is gated on, and refuses once that
# count is past REVIEW_MAX_CYCLES (default 4). The write AT the cap is the one
# verification pass the rule allows.
#
# `cycles` decides nothing here (KEN-592). It is the general fix-round tally
# `dev-fix.md` keeps, bumped by QA fix rounds and by review/submit fix rounds
# that run before the loop starts; those must leave the loop budget untouched.
# The failing direction runs first so a green pass is evidence.

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

# init seeds the key, so the first read is a number and not a null the gate
# has to coalesce.
seeded="$("$WS" --state-dir "$sd" get KEN-1 .rereview_cycles)"
[[ "$seeded" == "0" ]] && ok "init seeds rereview_cycles at 0" \
  || bad "init seeds rereview_cycles at 0" "got=$seeded"

# Past the cap: rereview_cycles=5 refuses the re-entry and leaves the state alone.
"$WS" --state-dir "$sd" update KEN-1 '.rereview_cycles = 5' >/dev/null
err="$("$WS" --state-dir "$sd" set KEN-1 rereview_panel "$PANEL" 2>&1 >/dev/null)" && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] && [[ "$err" == *"rereview_cycles is past the cap (5 > REVIEW_MAX_CYCLES=4)"* ]] \
  && ok "rereview_cycles=5 refuses rereview_panel, naming the count and the cap" \
  || bad "rereview_cycles=5 refuses rereview_panel, naming the count and the cap" "rc=$rc err=$err"
[[ "$err" == *"review-pr § 5"* ]] && ok "the refusal names the step that follows" \
  || bad "the refusal names the step that follows" "$err"
# § 7 applies the same rule with § 6 as its re-review target, so a refusal
# that names only § 5 misroutes a QA round to the verdict pass — the routing
# half of KEN-592.
[[ "$err" == *"review-pr § 8"* ]] && ok "the refusal names § 7's route as well as § 4's" \
  || bad "the refusal names § 7's route as well as § 4's" "$err"
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
after="$("$WS" --state-dir "$sd" get KEN-1 .rereview_cycles)"
[[ "$after" == "5" ]] && ok "a refused write does not raise the counter" \
  || bad "a refused write does not raise the counter" "got=$after"

# At the cap: the verification pass is allowed, and it costs one cycle.
"$WS" --state-dir "$sd" update KEN-1 '.rereview_cycles = 4' >/dev/null
"$WS" --state-dir "$sd" set KEN-1 rereview_panel "$PANEL" >/dev/null && rc=0 || rc=$?
agents="$("$WS" --state-dir "$sd" get KEN-1 '.rereview_panel.agents[0]')"
[[ "$rc" -eq 0 ]] && [[ "$agents" == "rev-a" ]] && ok "rereview_cycles=4 (at the cap) still records the verification pass panel" \
  || bad "rereview_cycles=4 (at the cap) still records the verification pass panel" "rc=$rc agents=$agents"
raised="$("$WS" --state-dir "$sd" get KEN-1 .rereview_cycles)"
[[ "$raised" == "5" ]] && ok "the panel write raises rereview_cycles by exactly one" \
  || bad "the panel write raises rereview_cycles by exactly one" "got=$raised"

# --- KEN-592: fix rounds outside the loop leave the loop budget alone -------
# `dev-fix.md` increments `cycles` on EVERY fix round it runs — QA fixes in
# review-pr § 7, and review.md / submit-pr.md rounds before the loop starts.
# While the gate read `.cycles`, those rounds spent loop budget they never
# used, and a QA recheck after four loop cycles was refused outright.
sd_qa="$TMP_ROOT/state-qa"
"$WS" --state-dir "$sd_qa" init KEN-9 --worktree "$REPO_ROOT" --branch ken-9 >/dev/null
for _ in 1 2 3 4 5 6 7; do
  "$WS" --state-dir "$sd_qa" increment KEN-9 cycles >/dev/null
done
tally="$("$WS" --state-dir "$sd_qa" get KEN-9 .cycles)"
[[ "$tally" == "7" ]] && ok "increment … cycles is unbounded" \
  || bad "increment … cycles is unbounded" "cycles=$tally"
"$WS" --state-dir "$sd_qa" set KEN-9 rereview_panel "$PANEL" >/dev/null && rc=0 || rc=$?
budget="$("$WS" --state-dir "$sd_qa" get KEN-9 .rereview_cycles)"
[[ "$rc" -eq 0 ]] && [[ "$budget" == "1" ]] \
  && ok "seven fix rounds spend no loop budget — the re-entry still passes" \
  || bad "seven fix rounds spend no loop budget — the re-entry still passes" "rc=$rc rereview_cycles=$budget"

# Other set fields are untouched by the cap.
"$WS" --state-dir "$sd" set KEN-1 rereview_skipped "no files changed" >/dev/null && rc=0 || rc=$?
[[ "$rc" -eq 0 ]] && ok "set of another field passes with the counter past the cap" \
  || bad "set of another field passes with the counter past the cap" "rc=$rc"

# The cap follows REVIEW_MAX_CYCLES from the environment.
"$WS" --state-dir "$sd" init KEN-2 --worktree "$REPO_ROOT" --branch ken-2 >/dev/null
"$WS" --state-dir "$sd" update KEN-2 '.rereview_cycles = 3' >/dev/null
err="$(REVIEW_MAX_CYCLES=2 "$WS" --state-dir "$sd" set KEN-2 rereview_panel "$PANEL" 2>&1 >/dev/null)" && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] && [[ "$err" == *"(3 > REVIEW_MAX_CYCLES=2)"* ]] \
  && ok "REVIEW_MAX_CYCLES=2 refuses at rereview_cycles=3" \
  || bad "REVIEW_MAX_CYCLES=2 refuses at rereview_cycles=3" "rc=$rc err=$err"

# --- planted controls: prove each assertion can fail ------------------------
echo
echo "--- planted controls ---"

CTRL_SCRIPTS="$TMP_ROOT/scripts"
cp -R "$REPO_ROOT/skills/orch/scripts" "$CTRL_SCRIPTS"

# $1 = control name, $2 = sed program. Writes the control interpreter and
# reports whether the program changed anything: one matching nothing leaves
# the source untouched and the control proves nothing.
plant() {
  sed "$2" "$WS" > "$CTRL_SCRIPTS/workflow-state"
  chmod +x "$CTRL_SCRIPTS/workflow-state"
  ! cmp -s "$CTRL_SCRIPTS/workflow-state" "$WS"
}

# The pre-KEN-592 gate: read `.cycles`, the tally every fix round bumps. It
# must refuse the very re-entry the fixed gate allows.
if ! plant tally 's/(\.rereview_cycles \/\/ 0) as \\\$n/(.cycles \/\/ 0) as \\$n/'; then
  bad "tally control planted nothing — its sed program matched no text"
else
  sdc="$TMP_ROOT/state-ctrl-tally"
  "$CTRL_SCRIPTS/workflow-state" --state-dir "$sdc" init KEN-5 --worktree "$REPO_ROOT" --branch ken-5 >/dev/null
  "$CTRL_SCRIPTS/workflow-state" --state-dir "$sdc" update KEN-5 '.cycles = 7' >/dev/null
  if "$CTRL_SCRIPTS/workflow-state" --state-dir "$sdc" set KEN-5 rereview_panel "$PANEL" >/dev/null 2>&1; then
    bad "the assertion MISSED a gate reading the fix-round tally" "the control accepted the re-entry"
  else
    ok "the assertion flags a gate reading the fix-round tally instead of the loop budget"
  fi
fi

# A gate that reads the loop budget but never raises it: every pass sees 0 and
# the loop never ends.
if ! plant raise 's/ | \.rereview_cycles = \\\$n + 1//'; then
  bad "raise control planted nothing — its sed program matched no text"
else
  sdr="$TMP_ROOT/state-ctrl-raise"
  "$CTRL_SCRIPTS/workflow-state" --state-dir "$sdr" init KEN-6 --worktree "$REPO_ROOT" --branch ken-6 >/dev/null
  "$CTRL_SCRIPTS/workflow-state" --state-dir "$sdr" set KEN-6 rereview_panel "$PANEL" >/dev/null
  cbudget="$("$CTRL_SCRIPTS/workflow-state" --state-dir "$sdr" get KEN-6 .rereview_cycles)"
  if [[ "$cbudget" == "1" ]]; then
    bad "the assertion MISSED a panel write that never raises the counter" "got=$cbudget"
  else
    ok "the assertion flags a panel write that never raises the counter"
  fi
fi

# Planted control: a refusal carrying only the escalated half. The assertion
# above must go red on it, or it is pinning nothing the round-1 wording did not
# already satisfy.
if ! plant supersede 's/ and drops its superseded fixed_items entry in the same write//'; then
  bad "supersede control planted nothing — its sed program matched no text"
else
  sdc="$TMP_ROOT/state-ctrl"
  "$CTRL_SCRIPTS/workflow-state" --state-dir "$sdc" init KEN-3 --worktree "$REPO_ROOT" --branch ken-3 >/dev/null
  "$CTRL_SCRIPTS/workflow-state" --state-dir "$sdc" update KEN-3 '.rereview_cycles = 5' >/dev/null
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
if ! plant fix 's/ and no further fix round//'; then
  bad "fix-round control planted nothing — its sed program matched no text"
else
  sdf="$TMP_ROOT/state-ctrl-fix"
  "$CTRL_SCRIPTS/workflow-state" --state-dir "$sdf" init KEN-4 --worktree "$REPO_ROOT" --branch ken-4 >/dev/null
  "$CTRL_SCRIPTS/workflow-state" --state-dir "$sdf" update KEN-4 '.rereview_cycles = 5' >/dev/null
  ferr="$("$CTRL_SCRIPTS/workflow-state" --state-dir "$sdf" set KEN-4 rereview_panel "$PANEL" 2>&1 >/dev/null)" || true
  if [[ "$ferr" != *"no further re-review cycle"* ]]; then
    bad "the control refusal stopped printing at all" "$ferr"
  elif [[ "$ferr" == *"no further fix round"* ]]; then
    bad "the assertion MISSED a refusal that stops only the re-review cycle" "$ferr"
  else
    ok "the assertion flags a refusal that stops only the re-review cycle"
  fi
fi

# The § 5-only routing that misrouted a § 7 QA recheck to the verdict pass.
if ! plant route 's/, review-pr § 8 (summary) from § 7,/,/'; then
  bad "routing control planted nothing — its sed program matched no text"
else
  sdo="$TMP_ROOT/state-ctrl-route"
  "$CTRL_SCRIPTS/workflow-state" --state-dir "$sdo" init KEN-7 --worktree "$REPO_ROOT" --branch ken-7 >/dev/null
  "$CTRL_SCRIPTS/workflow-state" --state-dir "$sdo" update KEN-7 '.rereview_cycles = 5' >/dev/null
  rerr="$("$CTRL_SCRIPTS/workflow-state" --state-dir "$sdo" set KEN-7 rereview_panel "$PANEL" 2>&1 >/dev/null)" || true
  if [[ "$rerr" != *"review-pr § 5"* ]]; then
    bad "the control refusal stopped naming § 4's route" "$rerr"
  elif [[ "$rerr" == *"review-pr § 8"* ]]; then
    bad "the assertion MISSED a refusal that names only § 4's route" "$rerr"
  else
    ok "the assertion flags a refusal that names only § 4's route"
  fi
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
