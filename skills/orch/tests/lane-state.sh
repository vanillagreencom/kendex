#!/usr/bin/env bash
# Tests for orch/scripts/lib/lane-state.sh, the shell judge of what a lane is
# doing, on the rungs its remaining callers run: lane-close's close guard,
# `open-terminal --wake`, overseer-host-tmux and jarvis's session backend run
# `lane_state`, and the relaunch runs `lane_handoff_standing`. The screen
# rules are the runtime classifier's (tests/rust/watch_observe.rs and
# agent-runtime's observe rows); the rows here are the judge's own rungs no
# other suite runs:
#
#   § login walls  a harness's login failure is a terminal wall over any usage
#                  room, during a live turn it stops nothing, above a later
#                  turn it is stale, and a quoted one is no wall
#   § pi rows      a Pi lane judged from the rows its own hook writes, over
#                  screens that would answer otherwise; a rowless Pi lane is
#                  unjudged, never idle off its pane
#   § handoff      lane_handoff_standing's reading of the verb's verdict
#
# The sandbox, its pgrep stub and its assertions are lib/oversee-watch-harness.sh.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
# An inherited or configured provider would turn the rows hosted.
export ORCH_LANE_HOST=local
# shellcheck source=lib/oversee-watch-harness.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/oversee-watch-harness.sh"
# shellcheck source=lib/shared-skill-libs.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/shared-skill-libs.sh"
# mutant_scripts and mutate_file, the two halves of each control.
# shellcheck source=lib/growth-state.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/growth-state.sh"

SCRIPTS_DIR="$REPO_ROOT/skills/orch/scripts"
SCRIPT_DIR="$SCRIPTS_DIR"
JUDGE="$SCRIPTS_DIR/lib/lane-state.sh"
# The library under test, sourced into this shell: the judge is a function, and
# a call to it is the smallest surface that can fail.
# shellcheck source=../scripts/lib/lane-state.sh
source "$JUDGE"

COMPOSER=$'\xe2\x9d\xaf\xc2\xa0'

# One case's stub directory serves every call below: the harness's pgrep
# answers from it, so a row's process observation is the file it writes and
# never this machine's process table.
new_case judge
export STUB_DIR
export PATH="$TMP_ROOT/bin:$PATH"
printf '4242 claude\n' > "$STUB_DIR/kids-100.txt"   # pid 100 has a child

# The screens, each named for what a lane showing it is doing.
screen_for() {
  case "$1" in
    idle) printf '%s\n%s\n' '⏺ Done: the PR is merged.' "$COMPOSER" ;;
    working) printf '%s\n%s\n' '✶ Germinating… (29m 16s · ↓ 58.7k tokens)' "$COMPOSER" ;;
    walled) printf '%s\n\n%s\n%s\n' '⏺ I will keep going.' "You've hit your session limit · resets 21:00" "$COMPOSER" ;;
    shell) printf '%s\n' 'method@box ~/dev/kendex (main)>' ;;
    *) printf 'screen_for: no such screen: %s\n' "$1" >&2; return 1 ;;
  esac
}

echo "=== lane-state § login walls: a login failure is a terminal wall ==="

CLAUDE_AUTH=$'  ⎿ \xc2\xa0Login expired · Please run /login'
CODEX_AUTH='■ Your access token could not be refreshed because your refresh token has expired.'
COPILOT_AUTH=' ✗ You must be logged in to send messages. Please run /login'
for row in "claude|$CLAUDE_AUTH" "codex|$CODEX_AUTH" "copilot|$COPILOT_AUTH"; do
  IFS='|' read -r harness message <<<"$row"
  screen="❯ watch the fleet"$'\n'"$message"$'\n'"$COMPOSER"
  lane_state actual listed "$harness" "" "$screen" "" room
  assert_eq "$actual/$LANE_WALL_KIND" walled/auth "$harness login failure overrides usage room"
  lane_state actual listed "$harness" "" "$screen"$'\n''esc to interrupt'
  assert_eq "$actual" working "$harness login words printed during a live turn do not stop it"
  lane_state actual listed "$harness" "" "$message"$'\n''❯ continue'$'\n'"$COMPOSER"
  assert_eq "$actual" idle "$harness login failure above a later turn is stale"
done
lane_state actual listed claude "" "❯ read lane news"$'\n''⏺ The lane answered "Login expired · Please run /login".'$'\n'"$COMPOSER"
assert_eq "$actual" idle "an inline quote in an overseer report is not its login failure"
# A Pi lane's rows own its state over the banner on its pane, whether the pane
# scan ran or failed.
for rows in idle working walled unreadable; do
  want="$rows"; [[ "$rows" != unreadable ]] || want=unjudged
  for scan in banner failed; do
    rc=0
    if [[ "$scan" == failed ]]; then
      grep() { return 2; }
    fi
    lane_state actual listed pi "" "$CLAUDE_AUTH"$'\n'"$COMPOSER" "" "" "$rows" || rc=$?
    unset -f grep
    assert_eq "$actual/$rc" "$want/0" "Pi $rows row owns state with $scan pane scan"
  done
done
ROWS_CONTROL="$(mutant_scripts pi-row-owner lib/lane-state.sh)"
mutate_file "$ROWS_CONTROL/lib/lane-state.sh" 'local _ls_rows="${8:-}"' 'local _ls_rows=""'
source "$ROWS_CONTROL/lib/lane-state.sh"
lane_state actual listed pi "" "$CLAUDE_AUTH"$'\n'"$COMPOSER" "" "" idle
assert_eq "$actual" walled "must-fail: dropping Pi rows loses the authoritative idle result"
source "$JUDGE"
CONTROL="$(mutant_scripts auth-classifier lib/lane-state.sh)"
mutate_file "$CONTROL/lib/lane-state.sh" 'AUTH_FAILURE_RE=' 'AUTH_FAILURE_RE_DISABLED='
# Retain the table's text but disable its use, as one failed classification
# must turn the auth contract red rather than merely stop the test running.
AUTH_FAILURE_RE='a^'
source "$CONTROL/lib/lane-state.sh"
lane_state actual listed claude "" "$CLAUDE_AUTH"$'\n'"$COMPOSER" "" room
if [[ "$actual" == walled ]]; then
  assert_eq control survived "must-fail: authentication classification removed"
else
  assert_eq control control "must-fail: removing authentication classification rejects the walled assertion"
fi
source "$JUDGE"

echo "=== lane-state § pi rows: a Pi lane judged from what Pi emits ==="

# A Pi lane's rows, as the lane-mail-check hook writes them under the pi-hooks
# carrier (hooks/tests/lane-mail-check.test.sh pins that writer), read by the
# one verdict every caller asks and handed to the judge. Each row runs over a
# pane screen that would answer something ELSE, so a row that passes proves the
# rows answered and the screen did not.
# shellcheck source=../scripts/lib/session-rows.sh
source "$SCRIPTS_DIR/lib/session-rows.sh"
PI_ROWS_FILE="$TMP_ROOT/pi-session-rows.jsonl"
pi_row_file() { # SHAPE
  rm -f -- "${PI_ROWS_FILE:?}"
  case "$1" in
    none) ;;
    ended) printf '%s\n' '{"at":1,"event":"Stop","harness":"pi","stop_reason":"stop"}' > "$PI_ROWS_FILE" ;;
    reopened) printf '%s\n' '{"at":1,"event":"Stop","harness":"pi","stop_reason":"stop"}' \
      '{"at":2,"event":"PreToolUse","harness":"pi"}' > "$PI_ROWS_FILE" ;;
    limit) printf '%s\n' '{"at":1,"event":"Stop","harness":"pi","stop_reason":"error","message":"429 Usage limit reached for this model"}' > "$PI_ROWS_FILE" ;;
    failed) printf '%s\n' '{"at":1,"event":"Stop","harness":"pi","stop_reason":"error","message":"network timeout"}' > "$PI_ROWS_FILE" ;;
    fragment) printf '%s\n%s' '{"at":1,"event":"Stop","harness":"pi","stop_reason":"stop"}' '{"at":2,"eve' > "$PI_ROWS_FILE" ;;
    foreign) printf '%s\n' '{"at":1,"event":"SessionEnd","harness":"pi"}' > "$PI_ROWS_FILE" ;;
    *) printf 'pi_row_file: no such shape: %s\n' "$1" >&2; return 1 ;;
  esac
}

# NAME|ROWS|CMD|PID|SCREEN|WANT_VERDICT|WANT_STATE
while IFS='|' read -r name rows cmd pid screen want_verdict want_state; do
  [[ -n "$name" ]] || continue
  pi_row_file "$rows"
  verdict_rc=0
  session_rows_lane_verdict "$PI_ROWS_FILE" || verdict_rc=$?
  word="$SESSION_ROWS_VERDICT"
  [[ "$verdict_rc" -eq 0 ]] || word=unreadable
  row_state=""
  row_rc=0
  lane_state row_state listed "$cmd" "$pid" "$(screen_for "$screen")" "" "" "$word" || row_rc=$?
  assert_eq "verdict=$word state=$row_state rc=$row_rc" "verdict=$want_verdict state=$want_state rc=0" "$name"
done <<'ROWS'
a Pi lane with no hook row is unjudged, never the idle its screen draws|none|pi|100|idle|none|unjudged
a Stop row with no turn after it is idle, whatever the screen draws|ended|pi|100|working|idle|idle
a tool call after the Stop row is a turn in flight|reopened|pi|100|idle|working|working
a turn that ended on Pi's usage-limit error is walled|limit|pi|100|idle|walled|walled
a turn that ended on any other error is idle, its error the payload|failed|pi|100|walled|idle|idle
a fragment a killed writer left is passed over for the row before it|fragment|pi|100|working|idle|idle
a row no lane writer writes is unreadable, and unreadable is unjudged|foreign|pi|100|idle|unreadable|unjudged
a bare shell with nothing under it is exited, whatever the rows say|ended|bash|101|shell|idle|exited
ROWS

# The Pi reading's own control: a judge that hands a Pi lane with no hook row
# to the pane rungs reads the idle screen idle, the pane scrape the rows exist
# to end.
MUTANT_LIB="$TMP_ROOT/mutant-lane-state-pi.sh"
sed 's/^    \*) printf -v "\$_ls_out" unjudged; return 0 ;;$/    *) ;;/' \
  "$SCRIPTS_DIR/lib/lane-state.sh" > "$MUTANT_LIB"
assert_eq "$(cmp -s "$MUTANT_LIB" "$SCRIPTS_DIR/lib/lane-state.sh" && echo same || echo differs)" "differs" \
  "control: the mutant really hands a rowless Pi lane to the pane"
mutant_state="$(
  source "$MUTANT_LIB"
  answer=""
  lane_state answer listed pi 100 "$(screen_for idle)" "" "" none
  printf '%s' "$answer"
)"
assert_eq "$mutant_state" "idle" \
  "control: a judge that reads the pane for a rowless Pi lane calls it idle"

echo "=== lane_handoff_standing reads the handoff-standing verdict ==="
# handoff_verb — the verb's run, in place of workflow-state: prints
# HS_OUT and exits HS_RC.
handoff_verb() { [[ -z "$HS_OUT" ]] || printf '%s\n' "$HS_OUT"; return "$HS_RC"; }
# handoff_answer [LIB] — the state, record and file lane_handoff_standing
# answers, from LIB where given.
handoff_answer() {
  (
    [[ -z "${1:-}" ]] || source "$1"
    lane_handoff_standing "$TMP_ROOT" "$TMP_ROOT/handoff.err" handoff_verb
    printf '%s|%s|%s' "$LANE_HANDOFF_STATE" "$LANE_HANDOFF_RECORD" "$LANE_HANDOFF_FILE"
  )
}
HS_V='workflow-state: handoff-standing'
while IFS='|' read -r hs_rc hs_out want_state want_record want_file label; do
  HS_RC="$hs_rc" HS_OUT="$(printf '%b' "$hs_out")"
  assert_eq "$(handoff_answer)" "$want_state|$want_record|$want_file" "handoff verdict: $label"
done <<EOF
0|$HS_V=none file=/s/w.json|none||/s/w.json|none is no record, naming its file
0|$HS_V=stands file=/w t/w.json\\n{"merged":[]}|stands|{"merged":[]}|/w t/w.json|stands carries the record under it and the file it stands in
0|$HS_V=stands file=/s/w.json|unreadable||/s/w.json|stands with no record under it is a truncated answer
0|$HS_V=unreadable file=/s/w.json|unreadable||/s/w.json|the verb's own unreadable
0|$HS_V=none|none|||a verdict naming no file
1|$HS_V=none file=/s/w.json|unreadable|||a run that exited non-zero never reached the verb
0|workflow-state: unknown-command|unreadable|||a word the verb does not print
EOF
HANDOFF_MUTANT="$TMP_ROOT/mutant-handoff.sh"
cp "$SCRIPTS_DIR/lib/lane-state.sh" "$HANDOFF_MUTANT"
mutate_file "$HANDOFF_MUTANT" '[[ "$answer" != "$line" && -n "${answer#*$'"'"'\n'"'"'}" ]] || return 0' ':'
HS_RC=0 HS_OUT="$HS_V=stands file=/s/w.json"
hs_mutant="$(handoff_answer "$HANDOFF_MUTANT")"
assert_eq "${hs_mutant%%|*}" "stands" \
  "control: without the record requirement a bare stands reads as a record that stands"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
