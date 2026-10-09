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
# At a cap of 0 that budget is review-pr § 4's one fix round, which `cap
# --issue` reads from `review_fix_round`: § 4 Fix Delegation sets it on every
# round whatever its items' outcomes, and no other round touches it.
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

# The zero cap's one writer: the walk sets review_fix_round itself, so only
# these pins hold § 4 Fix Delegation to the write `cap --issue` reads, and
# every other workflow to leaving it alone.
section_4() { awk '$0 == "## 4. Handle Review Items" { on = 1; next } on && /^## 5[.]/ { on = 0 } on' "$1"; }
FIX_WRITE='workflow-state set [ISSUE_ID] review_fix_round true'
grep -q -F "$FIX_WRITE" <<<"$(section_4 "$REVIEW_PR_WF")" \
  && pass "§ 4 records its fix round on review_fix_round" \
  || fail "§ 4 records no review_fix_round"
writers="$(grep -r -n -F 'set [ISSUE_ID] review_fix_round' "$REPO_ROOT/skills/orch/workflows")" || true
[[ "$(wc -l <<<"$writers")" -eq 1 && "$writers" == "$REVIEW_PR_WF:"* ]] \
  && pass "no other workflow writes review_fix_round" \
  || fail "review_fix_round is not written by review-pr.md alone" "$writers"

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

# --- the review walk per setting, tier history, prior round and outcome ----
# review-pr § 4 reads `cap --issue` before Fix Delegation, which sets
# review_fix_round before it delegates, at every cap; that round's
# dev-fix then records each item as fixed or escalated and raises `cycles`,
# and the At The Cap write may later drop a fixed entry whose fix did not
# hold. Bounded Re-Review reads the bare cap, where `0` routes to § 5, and
# otherwise writes rereview_panel; § 4 then reads the cap again. At 0 the
# first read is below and every read after the fix round is at-cap, whatever
# the round's items came to, so there is exactly one fix round and no
# re-review. A `local-review` prior is submit-pr § 1.2's fix round before the
# first § 4 read: it raises `cycles` and records a fixed item, and must leave
# the § 4 fix round to run. That § 5 route and the verification pass it skips
# are workflow sentences no script holds; the script holds the reads either
# side of them and the refused write.
# `small standard` is a small item relaunched at standard by ../workflows/small.md § Escape.
# walk [SCRIPT] SETTING TIERS PRIOR OUTCOME — each step's output, joined with |.
walk() {
  local bin="$WS" sdw issue=KEN-W err rc tier
  [[ "$1" != /* ]] || { bin="$1"; shift; }
  local setting="$1" tiers="$2" prior="$3" outcome="$4"
  sdw="$(mktemp -d "$TMP_ROOT/state-walk.XXXXXX")" || return 1
  wsw() { (cd "$NO_SETTINGS" && REVIEW_MAX_CYCLES="$setting" "$bin" --state-dir "$sdw" "$@"); }
  # record BUCKET SOURCE — the dev-fix outcome write for one item.
  record() {
    wsw update "$issue" --arg src "$2" ".$1 += [{description: (\"d-\" + \$src), location: \"l\", commit: \"c\", source: \$src}]" >/dev/null
  }
  wsw init "$issue" --worktree "$REPO_ROOT" --branch ken-w >/dev/null
  for tier in $tiers; do wsw set "$issue" tier "$tier"; done
  [[ "$prior" == none ]] || { record fixed_items "$prior"; wsw increment "$issue" cycles >/dev/null; }
  printf '%s|' "$(wsw cap REVIEW_MAX_CYCLES --issue "$issue")"
  wsw set "$issue" review_fix_round true
  case "$outcome" in
    fixed) record fixed_items pr-review ;;
    escalated) record escalated_items pr-review ;;
    dropped)
      record fixed_items pr-review
      wsw update "$issue" '.fixed_items |= map(select(.source != "pr-review"))' >/dev/null
      record escalated_items pr-review ;;
  esac
  wsw increment "$issue" cycles >/dev/null
  printf '%s|%s|' "$(wsw cap REVIEW_MAX_CYCLES --issue "$issue")" "$(wsw cap REVIEW_MAX_CYCLES)"
  err="$(wsw set "$issue" rereview_panel '{"agents": ["rev-a"], "reason": "test", "external": false}' 2>&1 >/dev/null)" && rc=0 || rc=$?
  printf '%s rc=%s|%s' "$(sed -n '1s/^workflow-state: \([a-z-]*\).*/\1/p' <<<"$err")" "$rc" "$(wsw cap REVIEW_MAX_CYCLES --issue "$issue")"
}
# setting|tiers|prior|outcome|first pass|after the fix round|bare cap|rereview_panel|next pass
WALK_ROWS=(
  "0|standard|none|fixed|below 0/0|at-cap 0/0|0|cycle-cap rc=1|at-cap 0/0"
  "0|standard|local-review|fixed|below 0/0|at-cap 0/0|0|cycle-cap rc=1|at-cap 0/0"
  "0|standard|none|escalated|below 0/0|at-cap 0/0|0|cycle-cap rc=1|at-cap 0/0"
  "0|standard|none|dropped|below 0/0|at-cap 0/0|0|cycle-cap rc=1|at-cap 0/0"
  "0|small standard|none|fixed|below 0/0|at-cap 0/0|0|cycle-cap rc=1|at-cap 0/0"
  "0|small|none|fixed|below 0/0|at-cap 0/0|0|cycle-cap rc=1|at-cap 0/0"
  "1|standard|none|fixed|below 0/1|below 0/1|1| rc=0|at-cap 1/1"
)
for row in "${WALK_ROWS[@]}"; do
  IFS='|' read -r setting tiers prior outcome want <<<"$row"
  assert_eq "$(walk "$setting" "$tiers" "$prior" "$outcome")" "$want" "REVIEW_MAX_CYCLES=$setting, tiers $tiers, prior $prior, item $outcome: one fix round, then the re-reviews the setting allows"
done

# The exception is REVIEW_MAX_CYCLES's alone: another cap at 0 on a fresh
# item has no fix round to allow, so it reads at-cap from the first read.
# other_zero [SCRIPT] — REVIEW_MAX_EXTERNAL_ROUNDS=0 read with --issue on a fresh item.
other_zero() {
  local bin="$WS" sdo
  [[ "${1:-}" != /* ]] || bin="$1"
  sdo="$(mktemp -d "$TMP_ROOT/state-other.XXXXXX")" || return 1
  (cd "$NO_SETTINGS" && export REVIEW_MAX_EXTERNAL_ROUNDS=0 \
    && "$bin" --state-dir "$sdo" init KEN-X --worktree "$REPO_ROOT" --branch ken-x >/dev/null \
    && "$bin" --state-dir "$sdo" cap REVIEW_MAX_EXTERNAL_ROUNDS --issue KEN-X)
}
assert_eq "$(other_zero)" "at-cap 0/0" "REVIEW_MAX_EXTERNAL_ROUNDS=0 on a fresh item is at-cap: the zero-cap exception is REVIEW_MAX_CYCLES's alone"

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

# The zero cap's four directions, each in a copy of the script: the
# exception gone, so the first pass at 0 is at-cap and no fix round runs; the
# exception blind to the record, so a second fix round is admitted; the
# exception keyed on a pr-review `fixed_items` entry, so a round whose item
# was escalated or whose fixed entry was dropped reads as never taken; and
# the exception keyed on `cycles`, so a prior local-review round spends the
# § 4 fix round. Each turns its rows at 0 red.
NOZERO_WS="$(mutant_scripts no-zero workflow-state)/workflow-state" || exit 1
mutate_file "$NOZERO_WS" '&& (( limit == 0 )); then' '&& (( limit == -1 )); then'
FIX_KEY="fix_round=\$(jq -r '.review_fix_round // false | tostring'"
BLIND_WS="$(mutant_scripts zero-blind workflow-state)/workflow-state" || exit 1
mutate_file "$BLIND_WS" "$FIX_KEY" "fix_round=\$(jq -r 'false | tostring'"
FIXED_WS="$(mutant_scripts zero-fixed-items workflow-state)/workflow-state" || exit 1
mutate_file "$FIXED_WS" "$FIX_KEY" "fix_round=\$(jq -r 'any((.fixed_items // [])[]; .source == \"pr-review\") | tostring'"
CYCLES_WS="$(mutant_scripts zero-cycles workflow-state)/workflow-state" || exit 1
mutate_file "$CYCLES_WS" "$FIX_KEY" "fix_round=\$(jq -r '(.cycles // 0) > 0 | tostring'"
# script|label|row|the copy's walk
for control in \
  "$NOZERO_WS|a zero cap that runs no fix round|0|at-cap 0/0|at-cap 0/0|0|cycle-cap rc=1|at-cap 0/0" \
  "$BLIND_WS|a zero cap that admits a second fix round|0|below 0/0|below 0/0|0|cycle-cap rc=1|below 0/0" \
  "$FIXED_WS|a zero cap that an escalated item leaves untaken|2|below 0/0|below 0/0|0|cycle-cap rc=1|below 0/0" \
  "$FIXED_WS|a zero cap that a dropped fixed entry gives back|3|below 0/0|below 0/0|0|cycle-cap rc=1|below 0/0" \
  "$CYCLES_WS|a zero cap that a local-review round spends|1|at-cap 0/0|at-cap 0/0|0|cycle-cap rc=1|at-cap 0/0"; do
  IFS='|' read -r bin label n mutant <<<"$control"
  IFS='|' read -r setting tiers prior outcome want <<<"${WALK_ROWS[$n]}"
  got="$(walk "$bin" "$setting" "$tiers" "$prior" "$outcome")"
  [[ "$got" != "$want" && "$got" == "$mutant" ]] \
    && pass "the walk at 0, prior $prior, item $outcome, flags $label" \
    || fail "the walk at 0, prior $prior, item $outcome, MISSED $label" "got=$got"
done

# The exception widened past its setting: a copy whose branch matches any cap
# reads the external cap at 0 as below, which the row above must turn red.
SCOPE_WS="$(mutant_scripts zero-any-cap workflow-state)/workflow-state" || exit 1
mutate_file "$SCOPE_WS" '[[ "$setting" == REVIEW_MAX_CYCLES ]] && (( limit == 0 ))' '[[ -n "$setting" ]] && (( limit == 0 ))'
got="$(other_zero "$SCOPE_WS")"
[[ "$got" == "below 0/0" ]] \
  && pass "the external-cap row flags a zero-cap exception that matches any cap" \
  || fail "the external-cap row MISSED a zero-cap exception that matches any cap" "got=$got"

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

# § 4 without its review_fix_round write: every later § 4 read at 0 is below.
CTRL_WF="$TMP_ROOT/review-pr-nofix.md"
grep -v -F "$FIX_WRITE" "$REVIEW_PR_WF" > "$CTRL_WF" || true
if cmp -s "$CTRL_WF" "$REVIEW_PR_WF"; then
  fail "§ 4 review_fix_round control planted nothing — its filter matched no text"
elif grep -q -F "$FIX_WRITE" <<<"$(section_4 "$CTRL_WF")"; then
  fail "the assertion MISSED § 4 recording no review_fix_round"
else
  pass "the assertion flags § 4 recording no review_fix_round"
fi

# --- a fix diff's panel against first_panel ------------------------
# A rereview_panel or verification_panel holding every first_panel reviewer
# is refused as panel-copy unless `domain_reasons` names, per first_panel
# reviewer, why the fix diff concerns that domain. The first row is KEN-3449's
# copy: a nonempty free-text `reason` and nothing else. A refused rereview
# write spends no budget; verification spends none either way.
FIRST='{"agents": ["reviewer-arch", "reviewer-correctness", "reviewer-error", "reviewer-security", "reviewer-quality", "reviewer-test", "reviewer-doc"], "reason": "first cycle"}'
ALL='"reviewer-arch", "reviewer-correctness", "reviewer-error", "reviewer-security", "reviewer-quality", "reviewer-test", "reviewer-doc"'
WHY='"reviewer-arch": "a", "reviewer-correctness": "c", "reviewer-error": "e", "reviewer-security": "s", "reviewer-quality": "q", "reviewer-test": "t"'
COPY_REASON='"reason": "Covers both unreviewed fix commits since accepted implementation"'
# field|panel|verdict|rereview_cycles after
COPY_ROWS=(
  "rereview_panel|{\"agents\": [$ALL], $COPY_REASON, \"external\": true}|panel-copy rc=1|0"
  "rereview_panel|{\"agents\": [$ALL, \"reviewer-perf\"], $COPY_REASON}|panel-copy rc=1|0"
  "rereview_panel|{\"agents\": [$ALL], $COPY_REASON, \"domain_reasons\": {$WHY}}|panel-copy rc=1|0"
  "rereview_panel|{\"agents\": [$ALL], $COPY_REASON, \"domain_reasons\": {$WHY, \"reviewer-doc\": \"\"}}|panel-copy rc=1|0"
  "rereview_panel|{\"agents\": [$ALL], $COPY_REASON, \"domain_reasons\": \"every domain\"}|panel-copy rc=1|0"
  "rereview_panel|{\"agents\": [\"reviewer-correctness\", \"reviewer-test\"], \"reason\": \"fix diff\", \"external\": true}| rc=0|1"
  "rereview_panel|{\"agents\": [$ALL], $COPY_REASON, \"domain_reasons\": {$WHY, \"reviewer-doc\": \"d\"}}| rc=0|1"
  "verification_panel|{\"agents\": [$ALL], $COPY_REASON}|panel-copy rc=1|0"
  "verification_panel|{\"agents\": [\"reviewer-error\"], \"reason\": \"fix diff\"}| rc=0|0"
  "verification_panel|{\"agents\": [$ALL], $COPY_REASON, \"domain_reasons\": {$WHY, \"reviewer-doc\": \"d\"}}| rc=0|0"
)
# copy_verdict [SCRIPT] N FIELD PANEL — a fresh item with FIRST recorded, then
# the set's first stderr key, its status and the re-review count after it.
copy_verdict() {
  local bin=("$WS") n field panel err rc=0 sdc
  [[ "$1" != /* ]] || { bin=("$1"); shift; }
  n="$1" field="$2" panel="$3"
  sdc="$TMP_ROOT/state-copy-$n-${#bin[@]}"
  ws "${bin[@]}" --state-dir "$sdc" init KEN-C --worktree "$REPO_ROOT" --branch ken-c >/dev/null
  ws "${bin[@]}" --state-dir "$sdc" set KEN-C first_panel "$FIRST" >/dev/null
  err="$(ws "${bin[@]}" --state-dir "$sdc" set KEN-C "$field" "$panel" 2>&1 >/dev/null)" || rc=$?
  printf '%s rc=%s|%s' "$(sed -n '1s/^workflow-state: \([a-z-]*\).*/\1/p' <<<"$err")" "$rc" \
    "$(ws "${bin[@]}" --state-dir "$sdc" get KEN-C .rereview_cycles)"
}
n=0
for row in "${COPY_ROWS[@]}"; do
  IFS='|' read -r field panel want count <<<"$row"
  n=$((n + 1))
  assert_eq "$(copy_verdict "$n" "$field" "$panel")" "$want|$count" "panel-copy row $n: $field"
done

# The check disabled: the KEN-3449 copy goes through and spends the budget.
COPY_WS="$(mutant_scripts copy-blind workflow-state)/workflow-state" || exit 1
mutate_file "$COPY_WS" 'if [[ -n "$uncovered" ]]; then' 'if false && [[ -n "$uncovered" ]]; then'
IFS='|' read -r field panel want count <<<"${COPY_ROWS[0]}"
got="$(copy_verdict "$COPY_WS" 0 "$field" "$panel")"
[[ "$got" != "$want|$count" ]] \
  && pass "the panel-copy rows flag a workflow-state that accepts a first_panel copy (got $got)" \
  || fail "the panel-copy rows MISSED a workflow-state that accepts a first_panel copy" "got=$got"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
