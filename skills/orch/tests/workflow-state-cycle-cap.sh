#!/usr/bin/env bash
# `workflow-state set <id> rereview_panel <json>` — the write review-pr § 4
# makes when it re-enters § 2 — is itself the re-review cycle: it raises
# `rereview_cycles` under the same lock it is gated on, and refuses once that
# count reaches REVIEW_MAX_CYCLES (default 4). The count is entries already
# taken, so the setting is the number of entries allowed and the stored count
# never exceeds it: at a cap of 4 the fifth write is refused at exactly 4.
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
[[ "$rc" -ne 0 ]] && [[ "$err" == *"rereview_cycles is at the cap (5 >= REVIEW_MAX_CYCLES=4, entries already taken)"* ]] \
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

# The boundary. The count is entries already taken, so the last permitted
# entry is the one at cap-1 and the entry AT the cap is refused: a guard that
# compares > instead of >= admits a fifth cycle under a cap of four, which is
# the direction that fails open.
"$WS" --state-dir "$sd" update KEN-1 '.rereview_cycles = 3' >/dev/null
"$WS" --state-dir "$sd" set KEN-1 rereview_panel "$PANEL" >/dev/null && rc=0 || rc=$?
agents="$("$WS" --state-dir "$sd" get KEN-1 '.rereview_panel.agents[0]')"
raised="$("$WS" --state-dir "$sd" get KEN-1 .rereview_cycles)"
[[ "$rc" -eq 0 ]] && [[ "$agents" == "rev-a" ]] && [[ "$raised" == "4" ]] \
  && ok "the fourth entry is permitted and raises the count to the cap" \
  || bad "the fourth entry is permitted and raises the count to the cap" "rc=$rc agents=$agents got=$raised"
"$WS" --state-dir "$sd" set KEN-1 rereview_panel "$PANEL" >/dev/null 2>&1 && rc=0 || rc=$?
after4="$("$WS" --state-dir "$sd" get KEN-1 .rereview_cycles)"
[[ "$rc" -ne 0 ]] && [[ "$after4" == "4" ]] \
  && ok "the fifth entry is refused at the cap and spends nothing" \
  || bad "the fifth entry is refused at the cap and spends nothing" "rc=$rc got=$after4"

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
"$WS" --state-dir "$sd_scn" set KEN-8 rereview_panel "$PANEL" >/dev/null 2>&1 && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] && ok "a fifth § 4 re-entry is refused, so the cap is the count allowed" \
  || bad "a fifth § 4 re-entry is refused, so the cap is the count allowed" "rc=$rc"
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
grep -q -F 'finding-disposition.md#recurrence' <<<"$S7" \
  && ok "§ 7 carries the recurrence exit for a loop that never surfaces nothing" \
  || bad "§ 7 has no exit for a loop where every round finds something new"

# Other set fields are untouched by the cap.
"$WS" --state-dir "$sd" set KEN-1 skip_qa true >/dev/null && rc=0 || rc=$?
[[ "$rc" -eq 0 ]] && ok "set of another field passes with the counter at the cap" \
  || bad "set of another field passes with the counter at the cap" "rc=$rc"

# The cap follows REVIEW_MAX_CYCLES from the environment.
"$WS" --state-dir "$sd" init KEN-2 --worktree "$REPO_ROOT" --branch ken-2 >/dev/null
"$WS" --state-dir "$sd" update KEN-2 '.rereview_cycles = 2' >/dev/null
err="$(REVIEW_MAX_CYCLES=2 "$WS" --state-dir "$sd" set KEN-2 rereview_panel "$PANEL" 2>&1 >/dev/null)" && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] && [[ "$err" == *"(2 >= REVIEW_MAX_CYCLES=2, entries already taken)"* ]] \
  && ok "REVIEW_MAX_CYCLES=2 allows two entries and refuses the third" \
  || bad "REVIEW_MAX_CYCLES=2 allows two entries and refuses the third" "rc=$rc err=$err"

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

# The comparison slipped back to >, which admits a fifth entry under a cap of four.
if ! plant off 's/if \\$n >= \$cap then/if \\$n > $cap then/'; then
  bad "off-by-one control planted nothing — its sed program matched no text"
else
  sdo="$TMP_ROOT/state-ctrl-off"
  "$CTRL_SCRIPTS/workflow-state" --state-dir "$sdo" init KEN-9x --worktree "$REPO_ROOT" --branch ken-9x >/dev/null
  "$CTRL_SCRIPTS/workflow-state" --state-dir "$sdo" update KEN-9x '.rereview_cycles = 4' >/dev/null
  if "$CTRL_SCRIPTS/workflow-state" --state-dir "$sdo" set KEN-9x rereview_panel "$PANEL" >/dev/null 2>&1; then
    ok "the boundary assertion flags a guard that admits a fifth entry"
  else
    bad "the boundary assertion MISSED a guard that admits a fifth entry" "the control refused at the cap"
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
sed 's|\[finding-disposition[.]md § Recurrence\](../references/finding-disposition[.]md#recurrence).s structural close|a structural close|' "$REVIEW_PR_WF" > "$CTRL_WF"
if cmp -s "$CTRL_WF" "$REVIEW_PR_WF"; then
  bad "§ 7 recurrence control planted nothing — its sed program matched no text"
elif grep -q -F 'finding-disposition.md#recurrence' <<<"$(section_7 "$CTRL_WF")"; then
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

# --- `cap`: the one reader of a round cap ----------------------------------
# The guard above and every workflow that reads a cap come through this table,
# so its verdict must agree with the write it gates, exactly, at the boundary.
echo
echo "--- workflow-state cap ---"

cd_sd="$TMP_ROOT/cap-state"
"$WS" --state-dir "$cd_sd" init KEN-CAP --worktree "$REPO_ROOT" --branch ken-cap >/dev/null

got="$("$WS" --state-dir "$cd_sd" cap REVIEW_MAX_CYCLES)"
[[ "$got" == "4" ]] && ok "bare cap prints the resolved limit" || bad "bare cap prints the resolved limit" "got=$got"

got="$("$WS" --state-dir "$cd_sd" cap REVIEW_MAX_CYCLES --issue KEN-CAP)"
[[ "$got" == "below 0/4" ]] && ok "a fresh issue is below the re-review cap" \
  || bad "a fresh issue is below the re-review cap" "got=$got"

# Walk the counter to the exact boundary and read both readers at each step:
# the verdict flips on the same count the rereview_panel write starts refusing.
flip_verdict=""
flip_write=""
for n in 0 1 2 3 4 5; do
  "$WS" --state-dir "$cd_sd" update KEN-CAP ".rereview_cycles = $n" >/dev/null
  verdict="$("$WS" --state-dir "$cd_sd" cap REVIEW_MAX_CYCLES --issue KEN-CAP)"
  if [[ -z "$flip_verdict" && "$verdict" == at-cap* ]]; then flip_verdict="$n"; fi
  if "$WS" --state-dir "$cd_sd" set KEN-CAP rereview_panel "$PANEL" >/dev/null 2>&1; then
    "$WS" --state-dir "$cd_sd" update KEN-CAP ".rereview_cycles = $n" >/dev/null
  elif [[ -z "$flip_write" ]]; then
    flip_write="$n"
  fi
done
[[ "$flip_verdict" == "4" ]] && ok "the cap verdict flips to at-cap at 4" \
  || bad "the cap verdict flips to at-cap at 4" "flipped at=$flip_verdict"
[[ "$flip_verdict" == "$flip_write" ]] \
  && ok "the cap verdict and the rereview_panel refusal flip on the same count" \
  || bad "the cap verdict and the rereview_panel refusal flip on the same count" \
     "verdict=$flip_verdict write=$flip_write"

# --- the external round cap's own row --------------------------------------
# The comment loop and submit-pr read REVIEW_MAX_EXTERNAL_ROUNDS through the
# same table, and `review-external-rounds-cap.test.sh` used to prove its row
# from its own scratch repos. This is where that proof lives now. This repo's
# `kendex.settings.toml` names every cap at the table's own number, so a bare
# read here would hold whatever default the table carried. Where a default is
# proved below it resolves from this settings-free checkout with the setting
# stripped from the process environment, the two layers orch-env ranks above
# the table, leaving only the table to answer.
no_settings="$TMP_ROOT/no-settings"
git init -q "$no_settings"
got="$(cd "$no_settings" && env -u REVIEW_MAX_EXTERNAL_ROUNDS "$WS" --state-dir "$cd_sd" cap REVIEW_MAX_EXTERNAL_ROUNDS)"
[[ "$got" == "4" ]] && ok "REVIEW_MAX_EXTERNAL_ROUNDS defaults to 4 through the table" \
  || bad "REVIEW_MAX_EXTERNAL_ROUNDS defaults to 4 through the table" "got=$got"

# Two rows, not one: the external cap moving must leave the re-review cap where
# the table put it, or the two knobs are one.
got="$(cd "$no_settings" && REVIEW_MAX_EXTERNAL_ROUNDS=9 env -u REVIEW_MAX_CYCLES "$WS" --state-dir "$cd_sd" cap REVIEW_MAX_CYCLES)"
[[ "$got" == "4" ]] && ok "moving the external cap leaves REVIEW_MAX_CYCLES alone" \
  || bad "moving the external cap leaves REVIEW_MAX_CYCLES alone" "got=$got"

# Its row names `pr_comment_review.iterations`, so `--issue` counts the triage
# passes rather than the re-review entries the row above it counts.
"$WS" --state-dir "$cd_sd" update KEN-CAP '.pr_comment_review.iterations = 3' >/dev/null
got="$("$WS" --state-dir "$cd_sd" cap REVIEW_MAX_EXTERNAL_ROUNDS --issue KEN-CAP)"
[[ "$got" == "below 3/4" ]] && ok "the external cap counts pr_comment_review.iterations" \
  || bad "the external cap counts pr_comment_review.iterations" "got=$got"
"$WS" --state-dir "$cd_sd" update KEN-CAP '.pr_comment_review.iterations = 4' >/dev/null
got="$("$WS" --state-dir "$cd_sd" cap REVIEW_MAX_EXTERNAL_ROUNDS --issue KEN-CAP)"
[[ "$got" == "at-cap 4/4" ]] && ok "the external cap reads at-cap once the budget is spent" \
  || bad "the external cap reads at-cap once the budget is spent" "got=$got"

# One table, one default: a setting the table does not hold is refused rather
# than silently defaulted, and a state-less cap refuses --issue.
rc=0; "$WS" --state-dir "$cd_sd" cap NOT_A_CAP >/dev/null 2>&1 || rc=$?
[[ "$rc" -eq 2 ]] && ok "an unknown cap name is refused" || bad "an unknown cap name is refused" "rc=$rc"
rc=0; "$WS" --state-dir "$cd_sd" cap CI_FIX_MAX_CYCLES --issue KEN-CAP >/dev/null 2>&1 || rc=$?
[[ "$rc" -eq 2 ]] && ok "a cap with no state field refuses --issue" \
  || bad "a cap with no state field refuses --issue" "rc=$rc"
got="$(env -u CI_FIX_MAX_CYCLES "$WS" --state-dir "$cd_sd" cap CI_FIX_MAX_CYCLES --count 5)"
[[ "$got" == "below 5/6" ]] && ok "CI_FIX_MAX_CYCLES defaults to 6 through the table" \
  || bad "CI_FIX_MAX_CYCLES defaults to 6 through the table" "got=$got"

# The assertion above ran where this repo's own [env] names CI_FIX_MAX_CYCLES at
# the table's number, so it would have held whatever default the table carried.
# The settings-free checkout is what proves the number comes from the table --
# and `env -u`, because orch-env ranks the process environment above the file,
# so an exported CI_FIX_MAX_CYCLES would answer over both.
got="$(cd "$no_settings" && env -u CI_FIX_MAX_CYCLES "$WS" --state-dir "$cd_sd" cap CI_FIX_MAX_CYCLES --count 5)"
[[ "$got" == "below 5/6" ]] && ok "the table's default is what resolves where no setting overrides it" \
  || bad "the table's default is what resolves where no setting overrides it" "got=$got"

# The roster is derived, never spelled. The refusal and the help text once held
# their own copies of it beside the two case arms that resolved a cap, so a cap
# added in one place was missing from the others. Both must now name exactly the
# settings the table resolves.
roster_of() { tr ',' '\n' <<<"$1" | tr -d ' ' | grep -v '^$' | sort; }
refusal_roster="$(roster_of "$("$WS" --state-dir "$cd_sd" cap NOT_A_CAP 2>&1 >/dev/null | sed 's/.*(known: //; s/)$//')")"
help_roster="$("$WS" help | sed -n 's/^ *\([A-Z][A-Z_]*\) (.*/\1/p' | sort)"
[[ -n "$refusal_roster" && "$refusal_roster" == "$help_roster" ]] \
  && ok "the refusal and the help name the same caps" \
  || bad "the refusal and the help name the same caps" "refusal=[$refusal_roster] help=[$help_roster]"
missing=""
while IFS= read -r setting; do
  [[ -n "$setting" ]] || continue
  "$WS" --state-dir "$cd_sd" cap "$setting" >/dev/null 2>&1 || missing="$missing $setting"
done <<<"$refusal_roster"
[[ -z "$missing" ]] && ok "every cap the roster names resolves through the table" \
  || bad "every cap the roster names resolves through the table" "unresolved:$missing"

# The default lives in the table alone: no reader may carry its own copy.
# The scan covers the WORKFLOWS as well as the scripts, and the quote before
# the setting name is optional, because a workflow spells the same read as a
# bare command line -- `.agents/skills/orch/scripts/orch-env CI_FIX_MAX_CYCLES
# 6`. Scripts-and-quotes-only, this check watched the two sites that already
# had rule pins and none of the four this branch rewrote in the workflows,
# where the two-spellings-disagree shape it exists to close would have gone
# back in unseen.
CAP_STRAY_RE='orch-env"? *(CI_FIX_MAX_CYCLES|REVIEW_MAX)'
cap_strays() { grep -rnE "$CAP_STRAY_RE" "$@" 2>/dev/null || true; }
stray="$(cap_strays "$REPO_ROOT/skills/orch/scripts" "$REPO_ROOT/skills/orch/workflows")"
[[ -z "$stray" ]] && ok "no orch script or workflow resolves a round cap outside the table" \
  || bad "no orch script or workflow resolves a round cap outside the table" "$stray"
# Planted, in both spellings: a reader that went back to pairing orch-env with
# its own default. The workflow one is the control for the widened scan --
# under the old scripts-only root it read clean.
CTRL_DIR="$TMP_ROOT/cap-stray-scripts"
CTRL_WF="$TMP_ROOT/cap-stray-workflows"
mkdir -p "$CTRL_DIR" "$CTRL_WF"
printf 'max=$("$SCRIPT_DIR/orch-env" CI_FIX_MAX_CYCLES 6)\n' > "$CTRL_DIR/watcher"
printf '.agents/skills/orch/scripts/orch-env CI_FIX_MAX_CYCLES 6\n' > "$CTRL_WF/merge-pr.md"
[[ -n "$(cap_strays "$CTRL_DIR")" ]] && ok "the stray check flags a script carrying its own cap default" \
  || bad "the stray check flags a script carrying its own cap default"
[[ -n "$(cap_strays "$CTRL_WF")" ]] && ok "the stray check flags a workflow carrying its own cap default" \
  || bad "the stray check flags a workflow carrying its own cap default"

# --- `append-file`: reviewer text never crosses argv ------------------------
echo
echo "--- workflow-state append-file ---"

cause="$TMP_ROOT/cause.json"
# A cause carrying every character that ends a shell word early. It reaches
# the state byte for byte, or the command was not the file-bound one.
python3 - "$cause" <<'PYW'
import json, sys
json.dump({"cause": "fs.rs::write_all's guard \"quoted\" $(whoami) `id` | ;", "commit": "abc1234"},
          open(sys.argv[1], "w"))
PYW
"$WS" --state-dir "$cd_sd" append-file KEN-CAP pr_comment_review.patched_causes "$cause" >/dev/null
"$WS" --state-dir "$cd_sd" append-file KEN-CAP pr_comment_review.patched_causes "$cause" >/dev/null
got="$("$WS" --state-dir "$cd_sd" get KEN-CAP '.pr_comment_review.patched_causes | length')"
[[ "$got" == "2" ]] && ok "append-file appends rather than replacing" \
  || bad "append-file appends rather than replacing" "got=$got"
want="$(jq -r .cause "$cause")"
got="$("$WS" --state-dir "$cd_sd" get KEN-CAP '.pr_comment_review.patched_causes[0].cause')"
[[ "$got" == "$want" ]] && ok "the cause reaches the state verbatim, shell metacharacters and all" \
  || bad "the cause reaches the state verbatim, shell metacharacters and all" "got=$got"

# The array is created where the field is absent — the // [] the workflows
# used to spell at every call site.
"$WS" --state-dir "$cd_sd" append-file KEN-CAP pr_comment_review.frozen_causes "$cause" >/dev/null
got="$("$WS" --state-dir "$cd_sd" get KEN-CAP '.pr_comment_review.frozen_causes | length')"
[[ "$got" == "1" ]] && ok "append-file creates the array when the field is absent" \
  || bad "append-file creates the array when the field is absent" "got=$got"

# Fails closed on anything that is not exactly one JSON value: a truncated or
# doubled write must not reach the record the recurrence rule reads.
printf 'not json\n' > "$TMP_ROOT/bad.json"
rc=0; "$WS" --state-dir "$cd_sd" append-file KEN-CAP pr_comment_review.patched_causes "$TMP_ROOT/bad.json" >/dev/null 2>&1 || rc=$?
[[ "$rc" -ne 0 ]] && ok "append-file refuses a file that is not JSON" || bad "append-file refuses a file that is not JSON"
printf '{"a":1}\n{"b":2}\n' > "$TMP_ROOT/two.json"
rc=0; "$WS" --state-dir "$cd_sd" append-file KEN-CAP pr_comment_review.patched_causes "$TMP_ROOT/two.json" >/dev/null 2>&1 || rc=$?
[[ "$rc" -ne 0 ]] && ok "append-file refuses a file holding two values" || bad "append-file refuses a file holding two values"
rc=0; "$WS" --state-dir "$cd_sd" append-file KEN-CAP pr_comment_review.patched_causes "$TMP_ROOT/nope.json" >/dev/null 2>&1 || rc=$?
[[ "$rc" -ne 0 ]] && ok "append-file refuses a missing file" || bad "append-file refuses a missing file"
got="$("$WS" --state-dir "$cd_sd" get KEN-CAP '.pr_comment_review.patched_causes | length')"
[[ "$got" == "2" ]] && ok "a refused append leaves the record untouched" \
  || bad "a refused append leaves the record untouched" "got=$got"

# The workflows that record a cause come through it — no second spelling of
# the append jq survives.
append_strays() { grep -rnF 'patched_causes // []) + [' "$1" 2>/dev/null || true; }
stray="$(append_strays "$REPO_ROOT/skills/orch/workflows")"
[[ -z "$stray" ]] && ok "no workflow spells the patched_causes append by hand" \
  || bad "no workflow spells the patched_causes append by hand" "$stray"
# Planted: the hand-spelled jq the workflows used to carry.
CTRL_DIR="$TMP_ROOT/append-stray-workflows"
mkdir -p "$CTRL_DIR"
cat > "$CTRL_DIR/dev-fix.md" <<'CTRL'
workflow-state update [ISSUE_ID] --slurpfile e f '$e[0] as $x | .pr_comment_review.patched_causes = ((.pr_comment_review.patched_causes // []) + [$x])'
CTRL
[[ -n "$(append_strays "$CTRL_DIR")" ]] && ok "the stray check flags a workflow spelling the append by hand" \
  || bad "the stray check flags a workflow spelling the append by hand"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
