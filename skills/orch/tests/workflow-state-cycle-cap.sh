#!/usr/bin/env bash
# `workflow-state set <id> rereview_panel <json>` — the write review-pr § 4
# makes when it re-enters § 2 — is itself the re-review cycle: it raises
# `rereview_cycles` under the same lock it is gated on, and refuses once that
# count reaches REVIEW_MAX_CYCLES (default 1). The count is entries already
# taken, so the setting is the number of entries allowed and the stored count
# never exceeds it: at the default cap of 1 the second write is refused at
# exactly 1. Every row below reads the table's default from a settings-free
# checkout with the setting stripped from the process environment, the two
# layers orch-env ranks above the table.
#
# `cycles` decides nothing here. It is the general fix-round tally
# `dev-fix.md` keeps, bumped by QA fix rounds and by review/submit fix rounds
# that run before the loop starts; those must leave the loop budget untouched.
# The failing direction runs first so a green pass is evidence.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

WS="$REPO_ROOT/skills/orch/scripts/workflow-state"
PANEL='{"agents": ["rev-a"], "reason": "test"}'
NO_SETTINGS="$TMP_ROOT/no-settings"
git init -q "$NO_SETTINGS"
# ws [SCRIPT] ARGS... — a workflow-state, the real one unless SCRIPT is a
# path to a copy, run where only the table can answer a cap.
ws() {
  local bin="$WS"
  [[ "$1" != /* ]] || { bin="$1"; shift; }
  (cd "$NO_SETTINGS" && env -u REVIEW_MAX_CYCLES "$bin" "$@")
}

# shellcheck source=lib/assertions.sh
source "$TEST_DIR/lib/assertions.sh"
# mutant_scripts and mutate_file, the two halves of the gate's control below.
# shellcheck source=lib/growth-state.sh
source "$TEST_DIR/lib/growth-state.sh"

echo "=== workflow-state re-review cycle cap ==="

sd="$TMP_ROOT/state"
ws --state-dir "$sd" init KEN-1 --worktree "$REPO_ROOT" --branch ken-1 >/dev/null

# init seeds the key, so the first read is a number and not a null the gate
# has to coalesce.
seeded="$(ws --state-dir "$sd" get KEN-1 .rereview_cycles)"
[[ "$seeded" == "0" ]] && pass "init seeds rereview_cycles at 0" \
  || fail "init seeds rereview_cycles at 0" "got=$seeded"

# Past the cap: rereview_cycles=5 refuses the re-entry and leaves the state alone.
ws --state-dir "$sd" update KEN-1 '.rereview_cycles = 5' >/dev/null
err="$(ws --state-dir "$sd" set KEN-1 rereview_panel "$PANEL" 2>&1 >/dev/null)" && rc=0 || rc=$?
[[ "$rc" -eq 1 ]] && [[ "${err%%$'\n'*}" == "workflow-state: cycle-cap count=5 limit=1" ]] \
  && pass "rereview_cycles=5 refuses rereview_panel, naming the count and the cap" \
  || fail "rereview_cycles=5 refuses rereview_panel, naming the count and the cap" "rc=$rc err=$err"
panel="$(ws --state-dir "$sd" get KEN-1 .rereview_panel)"
[[ "$panel" == "null" ]] && pass "a refused write leaves rereview_panel unset" \
  || fail "a refused write leaves rereview_panel unset" "panel=$panel"
after="$(ws --state-dir "$sd" get KEN-1 .rereview_cycles)"
[[ "$after" == "5" ]] && pass "a refused write does not raise the counter" \
  || fail "a refused write does not raise the counter" "got=$after"

# The boundary at the default cap: one fix round, one re-review of it. The
# count is entries already taken, so the one permitted entry is the one at 0
# and the entry AT the cap is refused: a guard that compares > instead of >=,
# or a table whose default is above 1, admits a second re-review, which is
# the direction that fails open.
# second_entry [SCRIPT] — on a fresh item, the first re-entry's exit status
# and the count it leaves, then the second's status, first stderr line and
# the count it leaves.
second_entry() {
  local sdb rc err first
  sdb="$(mktemp -d "$TMP_ROOT/state-boundary.XXXXXX")" || return 1
  ws "$@" --state-dir "$sdb" init KEN-B --worktree "$REPO_ROOT" --branch ken-b >/dev/null
  ws "$@" --state-dir "$sdb" set KEN-B rereview_panel "$PANEL" >/dev/null && rc=0 || rc=$?
  first="rc=$rc count=$(ws "$@" --state-dir "$sdb" get KEN-B .rereview_cycles)"
  err="$(ws "$@" --state-dir "$sdb" set KEN-B rereview_panel "$PANEL" 2>&1 >/dev/null)" && rc=0 || rc=$?
  printf '%s|rc=%s %s count=%s' "$first" "$rc" "${err%%$'\n'*}" "$(ws "$@" --state-dir "$sdb" get KEN-B .rereview_cycles)"
}
SECOND_ENTRY_WANT="rc=0 count=1|rc=1 workflow-state: cycle-cap count=1 limit=1 count=1"
got="$(second_entry)"
[[ "$got" == "$SECOND_ENTRY_WANT" ]] \
  && pass "at the default cap the first re-entry is permitted and the second is refused as cycle-cap count=1 limit=1, spending nothing" \
  || fail "at the default cap the first re-entry is permitted and the second is refused as cycle-cap count=1 limit=1, spending nothing" "got=$got"

# --- fix rounds outside the loop leave the loop budget alone --------
# `dev-fix.md` increments `cycles` on EVERY fix round it runs — QA fixes in
# review-pr § 7, and review.md / submit-pr.md rounds before the loop starts.
# While the gate read `.cycles`, those rounds spent loop budget they never
# used, and a QA recheck after four loop cycles was refused outright.
sd_qa="$TMP_ROOT/state-qa"
ws --state-dir "$sd_qa" init KEN-9 --worktree "$REPO_ROOT" --branch ken-9 >/dev/null
for _ in 1 2 3 4 5 6 7; do
  ws --state-dir "$sd_qa" increment KEN-9 cycles >/dev/null
done
tally="$(ws --state-dir "$sd_qa" get KEN-9 .cycles)"
[[ "$tally" == "7" ]] && pass "increment … cycles is unbounded" \
  || fail "increment … cycles is unbounded" "cycles=$tally"
ws --state-dir "$sd_qa" set KEN-9 rereview_panel "$PANEL" >/dev/null && rc=0 || rc=$?
budget="$(ws --state-dir "$sd_qa" get KEN-9 .rereview_cycles)"
[[ "$rc" -eq 0 ]] && [[ "$budget" == "1" ]] \
  && pass "seven fix rounds spend no loop budget — the re-entry still passes" \
  || fail "seven fix rounds spend no loop budget — the re-entry still passes" "rc=$rc rereview_cycles=$budget"

# --- the loop scenario, end to end --------------------------------
# One § 4 cycle reaches the cap, a QA fix round follows, and its § 7 → § 6
# re-check must run. The re-check panel goes to its own key: a QA re-check is
# not a re-review cycle, so the cap neither refuses it nor counts it.
sd_scn="$TMP_ROOT/state-scenario"
ws --state-dir "$sd_scn" init KEN-8 --worktree "$REPO_ROOT" --branch ken-8 >/dev/null
ws --state-dir "$sd_scn" set KEN-8 rereview_panel "$PANEL" >/dev/null
ws --state-dir "$sd_scn" increment KEN-8 cycles >/dev/null
spent="$(ws --state-dir "$sd_scn" get KEN-8 .rereview_cycles)"
[[ "$spent" == "1" ]] && pass "one § 4 re-entry spends exactly the whole budget" \
  || fail "one § 4 re-entry spends exactly the whole budget" "got=$spent"
ws --state-dir "$sd_scn" set KEN-8 rereview_panel "$PANEL" >/dev/null 2>&1 && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] && pass "a second § 4 re-entry is refused, so the cap is the count allowed" \
  || fail "a second § 4 re-entry is refused, so the cap is the count allowed" "rc=$rc"
# The QA fix round bumps the tally, then its § 7 → § 6 re-check runs.
ws --state-dir "$sd_scn" increment KEN-8 cycles >/dev/null
ws --state-dir "$sd_scn" set KEN-8 qa_recheck_panel "$PANEL" >/dev/null 2>&1 && rc=0 || rc=$?
qa_agents="$(ws --state-dir "$sd_scn" get KEN-8 '.qa_recheck_panel.agents[0]')"
[[ "$rc" -eq 0 ]] && [[ "$qa_agents" == "rev-a" ]] \
  && pass "the QA re-check is permitted with the § 4 budget fully spent" \
  || fail "the QA re-check is permitted with the § 4 budget fully spent" "rc=$rc agents=$qa_agents"
still="$(ws --state-dir "$sd_scn" get KEN-8 .rereview_cycles)"
[[ "$still" == "1" ]] && pass "the QA re-check leaves rereview_cycles where the § 4 loop left it" \
  || fail "the QA re-check leaves rereview_cycles where the § 4 loop left it" "got=$still"
# Repeating it never accrues budget either: the key is outside the cap entirely.
ws --state-dir "$sd_scn" set KEN-8 qa_recheck_panel "$PANEL" >/dev/null 2>&1 && rc=0 || rc=$?
again="$(ws --state-dir "$sd_scn" get KEN-8 .rereview_cycles)"
[[ "$rc" -eq 0 ]] && [[ "$again" == "1" ]] \
  && pass "a second QA re-check is permitted and still spends nothing" \
  || fail "a second QA re-check is permitted and still spends nothing" "rc=$rc got=$again"

# --- § 2 records the first-cycle panel -----------------------------
# The first cycle's panel lands on its own key with its agents and its reason,
# and spends nothing: a first cycle is not a re-review cycle.
sd_first="$TMP_ROOT/state-first"
ws --state-dir "$sd_first" init KEN-3 --worktree "$REPO_ROOT" --branch ken-3 >/dev/null
ws --state-dir "$sd_first" set KEN-3 first_panel '{"agents": ["reviewer-doc", "reviewer-error"], "reason": "docs + shell"}' >/dev/null && rc=0 || rc=$?
first="$(ws --state-dir "$sd_first" get KEN-3 '[.first_panel.agents, .first_panel.reason, .rereview_cycles] | tojson')"
[[ "$rc" -eq 0 && "$first" == '[["reviewer-doc","reviewer-error"],"docs + shell",0]' ]] \
  && pass "first_panel is written with its agents and its reason and spends no re-review budget" \
  || fail "first_panel is written with its agents and its reason and spends no re-review budget" "rc=$rc got=$first"

REVIEW_PR_WF="$REPO_ROOT/skills/orch/workflows/review-pr.md"
section_2() { awk '$0 == "## 2. Prepare Reviewers" { on = 1; next } on && /^## 3[.]/ { on = 0 } on' "$1"; }
FIRST_WRITE='workflow-state set [ISSUE_ID] first_panel'
grep -q -F "$FIRST_WRITE" <<<"$(section_2 "$REVIEW_PR_WF")" \
  && pass "§ 2 records its panel on first_panel" \
  || fail "§ 2 records no first_panel"

# --- § 7 states which counter governs it --------------------------
# The doc side of the same separation. § 7 must name its own key and must not
# read or raise the § 4 budget.
# The pins are IDENTIFIERS and a heading reference — the key § 7 writes, the
# counter it must not touch, the check it must not route through — never a
# sentence: § 7 states the separation without naming the counter, so a token
# scan over the whole section is the assertion.
section_7() { awk '$0 == "## 7. Handle QA Items" { on = 1; next } on && /^## 8[.]/ { on = 0 } on' "$1"; }
S7="$(section_7 "$REVIEW_PR_WF")"
grep -q -F 'qa_recheck_panel' <<<"$S7" \
  && pass "§ 7 sets its QA panel on its own key" \
  || fail "§ 7 does not name qa_recheck_panel"
grep -q -F 'rereview_cycles' <<<"$S7" \
  && fail "§ 7 still names the § 4 budget" "$(grep -n -F 'rereview_cycles' <<<"$S7")" \
  || pass "§ 7 neither reads nor raises rereview_cycles"
grep -q -F 'At The Cap' <<<"$S7" \
  && fail "§ 7 still routes through § 4's At The Cap check" \
  || pass "§ 7 routes through no cap check"
# With no counter, the two convergence exits both need a round to surface
# nothing new. A loop where every round finds a DIFFERENT blocker fires
# neither, so the section needs the recurrence exit as well: one root cause
# reappearing ends it with a structural close, not another patch round.
grep -q -F 'finding-disposition.md#recurrence' <<<"$S7" \
  && pass "§ 7 carries the recurrence exit for a loop that never surfaces nothing" \
  || fail "§ 7 has no exit for a loop where every round finds something new"

# Other set fields are untouched by the cap.
ws --state-dir "$sd" set KEN-1 skip_qa true >/dev/null && rc=0 || rc=$?
[[ "$rc" -eq 0 ]] && pass "set of another field passes with the counter at the cap" \
  || fail "set of another field passes with the counter at the cap" "rc=$rc"

# The cap follows REVIEW_MAX_CYCLES from the environment.
ws --state-dir "$sd" init KEN-2 --worktree "$REPO_ROOT" --branch ken-2 >/dev/null
ws --state-dir "$sd" update KEN-2 '.rereview_cycles = 2' >/dev/null
err="$(cd "$NO_SETTINGS" && REVIEW_MAX_CYCLES=2 "$WS" --state-dir "$sd" set KEN-2 rereview_panel "$PANEL" 2>&1 >/dev/null)" && rc=0 || rc=$?
[[ "$rc" -eq 1 ]] && [[ "${err%%$'\n'*}" == "workflow-state: cycle-cap count=2 limit=2" ]] \
  && pass "REVIEW_MAX_CYCLES=2 allows two entries and refuses the third" \
  || fail "REVIEW_MAX_CYCLES=2 allows two entries and refuses the third" "rc=$rc err=$err"

# --- planted controls: one per instrument, proving each can fail ----------
echo
echo "--- planted controls ---"

# Two ways a second re-review comes back, each in a copy of the script: the
# gate's comparison slipped back to >, and the table's default back to 4. The
# boundary assertion must read each copy as admitting the second entry.
OFF_WS="$(mutant_scripts off-by-one workflow-state)/workflow-state" || exit 1
mutate_file "$OFF_WS" 'if \$n >= $cap then' 'if \$n > $cap then'
DEFAULT_WS="$(mutant_scripts default-four workflow-state)/workflow-state" || exit 1
mutate_file "$DEFAULT_WS" "printf 'REVIEW_MAX_CYCLES\\trereview_cycles\\t1\\t1\\n'" "printf 'REVIEW_MAX_CYCLES\\trereview_cycles\\t4\\t1\\n'"
for control in "$OFF_WS|a guard comparing >" "$DEFAULT_WS|a table defaulting to 4"; do
  got="$(second_entry "${control%%|*}")"
  [[ "$got" != "$SECOND_ENTRY_WANT" && "$got" == "rc=0 count=1|rc=0 "* ]] \
    && pass "the boundary assertion flags ${control#*|} admitting a second re-entry" \
    || fail "the boundary assertion MISSED ${control#*|} admitting a second re-entry" "got=$got"
done

# § 7 changed to the shared key: the assertion must catch the counter
# coming back into the section that must not spend it.
CTRL_WF="$TMP_ROOT/review-pr-shared.md"
sed 's/the § 4 budget `REVIEW_MAX_CYCLES` bounds is neither read nor raised in this section/`rereview_cycles` is read here/' "$REVIEW_PR_WF" > "$CTRL_WF"
if cmp -s "$CTRL_WF" "$REVIEW_PR_WF"; then
  fail "§ 7 counter control planted nothing — its sed program matched no text"
elif grep -q -F 'rereview_cycles' <<<"$(section_7 "$CTRL_WF")"; then
  pass "the assertion flags rereview_cycles back inside § 7"
else
  fail "the assertion MISSED rereview_cycles back inside § 7"
fi

# The unpatched § 2: no first_panel write, so the first cycle leaves no record.
CTRL_WF="$TMP_ROOT/review-pr-nofirst.md"
grep -v -F "$FIRST_WRITE" "$REVIEW_PR_WF" > "$CTRL_WF" || true
if cmp -s "$CTRL_WF" "$REVIEW_PR_WF"; then
  fail "§ 2 first_panel control planted nothing — its filter matched no text"
elif grep -q -F "$FIRST_WRITE" <<<"$(section_2 "$CTRL_WF")"; then
  fail "the assertion MISSED § 2 recording no first_panel"
else
  pass "the assertion flags § 2 recording no first_panel"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
