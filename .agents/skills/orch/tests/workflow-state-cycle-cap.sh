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

# --- KEN-592: the issue's scenario, end to end ----------------------------
# Four § 4 cycles reach the cap, a QA fix round follows, and its § 7 → § 6
# re-check must run. The re-check panel goes to its own key: a QA re-check is
# not a re-review cycle, so the cap neither refuses it nor counts it.
sd_scn="$TMP_ROOT/state-scenario"
"$WS" --state-dir "$sd_scn" init KEN-8 --worktree "$REPO_ROOT" --branch ken-8 >/dev/null
for _ in 1 2 3 4; do
  "$WS" --state-dir "$sd_scn" set KEN-8 rereview_panel "$PANEL" >/dev/null
  "$WS" --state-dir "$sd_scn" increment KEN-8 cycles >/dev/null
done
spent="$("$WS" --state-dir "$sd_scn" get KEN-8 .rereview_cycles)"
[[ "$spent" == "4" ]] && ok "four § 4 re-entries spend exactly the whole budget" \
  || bad "four § 4 re-entries spend exactly the whole budget" "got=$spent"
# The QA fix round bumps the tally, then its § 7 → § 6 re-check runs.
"$WS" --state-dir "$sd_scn" increment KEN-8 cycles >/dev/null
"$WS" --state-dir "$sd_scn" set KEN-8 qa_recheck_panel "$PANEL" >/dev/null 2>&1 && rc=0 || rc=$?
qa_agents="$("$WS" --state-dir "$sd_scn" get KEN-8 '.qa_recheck_panel.agents[0]')"
[[ "$rc" -eq 0 ]] && [[ "$qa_agents" == "rev-a" ]] \
  && ok "the QA re-check is permitted with the § 4 budget fully spent" \
  || bad "the QA re-check is permitted with the § 4 budget fully spent" "rc=$rc agents=$qa_agents"
still="$("$WS" --state-dir "$sd_scn" get KEN-8 .rereview_cycles)"
[[ "$still" == "4" ]] && ok "the QA re-check leaves rereview_cycles where the § 4 loop left it" \
  || bad "the QA re-check leaves rereview_cycles where the § 4 loop left it" "got=$still"
# Repeating it never accrues budget either: the key is outside the cap entirely.
"$WS" --state-dir "$sd_scn" set KEN-8 qa_recheck_panel "$PANEL" >/dev/null 2>&1 && rc=0 || rc=$?
again="$("$WS" --state-dir "$sd_scn" get KEN-8 .rereview_cycles)"
[[ "$rc" -eq 0 ]] && [[ "$again" == "4" ]] \
  && ok "a second QA re-check is permitted and still spends nothing" \
  || bad "a second QA re-check is permitted and still spends nothing" "rc=$rc got=$again"

# --- KEN-592: § 7 states which counter governs it -------------------------
# The doc side of the same separation. § 7 must name its own key and must not
# read or raise the § 4 budget.
# The pins are IDENTIFIERS and a heading reference — the key § 7 writes, the
# counter it must not touch, the check it must not route through — never a
# sentence: § 7 states the separation without naming the counter, so a token
# scan over the whole section is the assertion.
REVIEW_PR_WF="$REPO_ROOT/skills/orch/workflows/review-pr.md"
section_7() { awk '$0 == "## 7. Handle QA Items" { on = 1; next } on && /^## 8[.]/ { on = 0 } on' "$1"; }
S7="$(section_7 "$REVIEW_PR_WF")"
grep -q -F 'qa_recheck_panel' <<<"$S7" \
  && ok "§ 7 sets its QA panel on its own key" \
  || bad "§ 7 does not name qa_recheck_panel"
grep -q -F 'rereview_cycles' <<<"$S7" \
  && bad "§ 7 still names the § 4 budget" "$(grep -n -F 'rereview_cycles' <<<"$S7")" \
  || ok "§ 7 neither reads nor raises rereview_cycles"
grep -q -F 'At The Cap' <<<"$S7" \
  && bad "§ 7 still routes through § 4's At The Cap check" \
  || ok "§ 7 routes through no cap check"
# With no counter, the two convergence exits both need a round to surface
# nothing new. A loop where every round finds a DIFFERENT blocker fires
# neither, so the section needs the recurrence exit as well: one root cause
# reappearing ends it with a structural close, not another patch round.
grep -q -F 'Review must converge' <<<"$S7" \
  && ok "§ 7 carries the recurrence exit for a loop that never surfaces nothing" \
  || bad "§ 7 has no exit for a loop where every round finds something new"

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

# A guard that also gates the QA re-check key: the issue's scenario would
# fail again, refused under a cap that is not its own.
if ! plant qakey 's/"$field" == "rereview_panel"/"$field" == *_panel/'; then
  bad "qa-key control planted nothing — its sed program matched no text"
else
  sdq="$TMP_ROOT/state-ctrl-qakey"
  "$CTRL_SCRIPTS/workflow-state" --state-dir "$sdq" init KEN-7 --worktree "$REPO_ROOT" --branch ken-7 >/dev/null
  "$CTRL_SCRIPTS/workflow-state" --state-dir "$sdq" update KEN-7 '.rereview_cycles = 5' >/dev/null
  if "$CTRL_SCRIPTS/workflow-state" --state-dir "$sdq" set KEN-7 qa_recheck_panel "$PANEL" >/dev/null 2>&1; then
    bad "the assertion MISSED a guard that gates the QA re-check key" "the control permitted the write"
  else
    ok "the assertion flags a guard that gates the QA re-check key too"
  fi
fi

# § 7 reverted to the shared key: the assertion must catch the counter
# coming back into the section that must not spend it.
CTRL_WF="$TMP_ROOT/review-pr-shared.md"
sed 's/the § 4 budget `REVIEW_MAX_CYCLES` bounds is neither read nor raised in this section/`rereview_cycles` is read here/' "$REVIEW_PR_WF" > "$CTRL_WF"
if cmp -s "$CTRL_WF" "$REVIEW_PR_WF"; then
  bad "§ 7 counter control planted nothing — its sed program matched no text"
elif grep -q -F 'rereview_cycles' <<<"$(section_7 "$CTRL_WF")"; then
  ok "the assertion flags rereview_cycles back inside § 7"
else
  bad "the assertion MISSED rereview_cycles back inside § 7"
fi

# § 7 routed back through the cap check.
CTRL_WF="$TMP_ROOT/review-pr-capcheck.md"
sed 's/\*\*No cap check runs here\*\*/**Run § 4 At The Cap here**/' "$REVIEW_PR_WF" > "$CTRL_WF"
if cmp -s "$CTRL_WF" "$REVIEW_PR_WF"; then
  bad "§ 7 cap-check control planted nothing — its sed program matched no text"
elif grep -q -F 'At The Cap' <<<"$(section_7 "$CTRL_WF")"; then
  ok "the assertion flags § 7 routing through the cap check again"
else
  bad "the assertion MISSED § 7 routing through the cap check again"
fi

# § 7 back to convergence exits alone: a loop whose every round finds a new
# blocker would never end.
CTRL_WF="$TMP_ROOT/review-pr-norecur.md"
sed 's/SKILL[.]md § Review must converge.s structural close/a structural close/' "$REVIEW_PR_WF" > "$CTRL_WF"
if cmp -s "$CTRL_WF" "$REVIEW_PR_WF"; then
  bad "§ 7 recurrence control planted nothing — its sed program matched no text"
elif grep -q -F 'Review must converge' <<<"$(section_7 "$CTRL_WF")"; then
  bad "the assertion MISSED § 7 losing its recurrence exit"
else
  ok "the assertion flags § 7 losing its recurrence exit"
fi

# § 7 with no key of its own: the QA panel would land on the gated field.
CTRL_WF="$TMP_ROOT/review-pr-nokey.md"
sed 's/qa_recheck_panel/rereview_panel/g' "$REVIEW_PR_WF" > "$CTRL_WF"
if cmp -s "$CTRL_WF" "$REVIEW_PR_WF"; then
  bad "§ 7 key control planted nothing — its sed program matched no text"
elif grep -q -F 'qa_recheck_panel' <<<"$(section_7 "$CTRL_WF")"; then
  bad "the assertion MISSED § 7 writing the gated panel key"
else
  ok "the assertion flags § 7 writing the gated panel key"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
