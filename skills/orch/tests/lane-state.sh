#!/usr/bin/env bash
# Tests for orch/scripts/lib/lane-state.sh, the shell judge of what a lane is
# doing, on the rungs its callers run: overseer-host-tmux runs
# `lane_state`, and jarvis's session backend runs
# `lane_state` and `lane_input_ready`. The screen rules are the runtime
# classifier's (tests/rust/watch_observe.rs and agent-runtime's observe rows);
# the rows here are the judge's own rungs no other suite runs:
#
#   § login walls  a harness's login failure is a terminal wall over any usage
#                  room, during a live turn it stops nothing, above a later
#                  turn it is stale, and a quoted one is no wall; a Pi lane's
#                  idle rows outrank the banner on its pane
#   § input        Pi input waits on the base editor, not on idle rows alone
#   § identity     a launch identity in the runtime's start form reads live
#                  while its process runs and ended once it exits
#   § capture      lane_pane_capture keeps the screen and reads remain-on-exit's
#                  dead flag, under a UTF-8 client locale and under none
#
# The sandbox, its pgrep stub and its assertions are lib/oversee-watch-harness.sh;
# § capture runs a tmux server private to this suite.
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
# A Pi lane's idle rows, the word jarvis's session backend passes, own its
# state over the banner on its pane, whether the pane scan ran or failed.
for scan in banner failed; do
  rc=0
  if [[ "$scan" == failed ]]; then
    grep() { return 2; }
  fi
  lane_state actual listed pi "" "$CLAUDE_AUTH"$'\n'"$COMPOSER" "" "" idle || rc=$?
  unset -f grep
  assert_eq "$actual/$rc" "idle/0" "Pi idle rows own the state with $scan pane scan"
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

echo "=== lane-state § input: Pi input waits on the base editor ==="

# jarvis's session backend asks lane_input_ready of a Pi session it started
# and delivered no brief to, passing the idle rows verdict its own record
# holds. The rows settle the turn; the capture must also show Pi's base
# editor at its final empty prompt, or the paste lands in a draft or a
# selector. The screens: Pi 1.3.0 with pi-qol at idle
# (fixtures/oversee-watch/pi-qol-idle.txt), and the same with a drafted line.
PI_IDLE="$(cat "$CODEX_PANES/pi-qol-idle.txt")"
PI_DRAFT="$(sed '/^π[[:space:]]*$/s/$/ drafted input/' "$CODEX_PANES/pi-qol-idle.txt")"
rc=0
lane_input_ready actual listed pi 100 "$PI_IDLE" "" "" idle "" pi || rc=$?
assert_eq "$actual/$rc" idle/0 "idle rows over the empty base editor permit input"
rc=0
lane_input_ready actual listed pi 100 "$PI_DRAFT" "" "" idle "" pi || rc=$?
assert_eq "$actual/$rc" unjudged/1 "idle rows over a drafted editor refuse input: the editor is not ready"

echo "=== lane-state § identity: the runtime's recorded start is read in its own form ==="

# The by-hand stop hands lane_identity_status the
# launch identity a record names. The record is the one the runtime's
# launch-lane writes (tests/fixtures/launch-lane/claude-dontask.json, held to
# that producer by tests/rust/lane.rs), its pid and start bound to a
# process this suite holds: the start keeps the form the producer wrote, its
# value the /proc start field the producer reads. Read as text in another
# form, a running harness reads ended, and a stop with no pane stops nothing.
if lane_proc_readable; then
  sleep 60 &
  IDENTITY_PID=$!
  IDENTITY_TICKS="$(awk '{ print $22 }' "/proc/$IDENTITY_PID/stat")"
  IDENTITY_RECORD="$(sed -e "s|\"@PID@\"|$IDENTITY_PID|" -e "s|@START@|$IDENTITY_TICKS|" \
    "$(dirname "${BASH_SOURCE[0]}")/fixtures/launch-lane/claude-dontask.json")"
  IDENTITY_START="$(jq -r '.launch.start' <<<"$IDENTITY_RECORD")"
  rc=0
  lane_identity_status "$(jq -r '.launch.pid' <<<"$IDENTITY_RECORD")" "$IDENTITY_START" || rc=$?
  assert_eq "$rc/$LANE_IDENTITY_CAUSE" 0/ "a runtime-recorded launch identity reads live while its process runs"
  kill "$IDENTITY_PID"
  wait "$IDENTITY_PID" 2>/dev/null || :
  rc=0
  lane_identity_status "$IDENTITY_PID" "$IDENTITY_START" || rc=$?
  assert_eq "$rc/$LANE_IDENTITY_CAUSE" 3/identity-stale "a runtime-recorded launch identity reads ended once its process exits"
fi

echo "=== lane-state § capture: the screen kept and remain-on-exit's dead flag read ==="

# lane_pane_capture is the shell's one read of a local pane. A launcher run
# from a job unit is a tmux client whose environment names no UTF-8 locale,
# to which tmux prints a control byte in a format as `_`, so the screen and
# the dead proof are read under a UTF-8 client and under none. The pane
# prints a line spelled like the dead marker: screen text, never the flag.
# The server is this suite's own, its socket under TMP_ROOT, ended with it.
# The sandbox's stubs sit ahead of PATH; the capture runs the real tmux.
CAPTURE_PATH="$(printf '%s' "$PATH" | tr ':' '\n' | grep -vxF "$TMP_ROOT/bin" | paste -sd: -)"
REAL_TMUX="$(PATH="$CAPTURE_PATH" command -v tmux)" || { echo "lane-state: tmux-missing" >&2; exit 1; }
SOCK_DIR="$TMP_ROOT/sock"
mkdir -p "$SOCK_DIR"
tm() { env -i GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" PATH="$CAPTURE_PATH" HOME="$TMP_ROOT" LANG=C.UTF-8 SHELL=/bin/sh TMUX_TMPDIR="$SOCK_DIR" "$REAL_TMUX" "$@"; }
trap 'tm kill-server 2>/dev/null || true; rm -rf -- "${TMP_ROOT:?}"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
tm -f /dev/null new-session -d -s w -n lane -x 200 -y 50 'exec sleep 100000'
CAPTURE_PANE="$(tm new-window -d -P -F '#{pane_id}' -t w -n capture "printf 'capture-ready\\nkendex-pane-dead=1\\n'; exec cat")"
tm set-window-option -t "$CAPTURE_PANE" remain-on-exit on
capture_wait=0
until [[ "$(tm capture-pane -pJ -t "$CAPTURE_PANE")" == *capture-ready* ]]; do
  capture_wait=$((capture_wait + 1))
  [[ "$capture_wait" -lt 100 ]] || { echo 'lane-state: capture-not-ready' >&2; exit 1; }
  sleep 0.1
done
# capture_locale LOCALE EXPECTED_SCREEN — the capture of the pane and the
# judge's word on it, from a child shell whose client locale is LOCALE, none
# where LOCALE is empty.
capture_locale() {
  env -i GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" PATH="$CAPTURE_PATH" HOME="$TMP_ROOT" TMUX_TMPDIR="$SOCK_DIR" ${1:+LANG="$1"} "$BASH" -c '
    source "$1"
    rc=0
    lane_pane_capture screen local local capture "$3" || rc=$?
    preserved=no; [[ "$screen" != "$2" ]] || preserved=yes
    lane_state state listed copilot "" "$screen" "" "" "" "" copilot "$LANE_PANE_SOURCE"
    printf "rc=%s source=%s screen=%s state=%s" "$rc" "$LANE_PANE_SOURCE" "$preserved" "$state"
  ' _ "$JUDGE" "$2" "$CAPTURE_PANE"
}
while IFS='|' read -r phase locale source state; do
  if [[ "$phase" == dead && "$(tm display-message -p -t "$CAPTURE_PANE" '#{pane_dead}')" != 1 ]]; then
    tm send-keys -t "$CAPTURE_PANE" C-d
    capture_wait=0
    until [[ "$(tm display-message -p -t "$CAPTURE_PANE" '#{pane_dead}')" == 1 ]]; do
      capture_wait=$((capture_wait + 1))
      [[ "$capture_wait" -lt 100 ]] || { echo 'lane-state: capture-not-dead' >&2; exit 1; }
      sleep 0.1
    done
  fi
  capture_expected="$(tm capture-pane -pJ -t "$CAPTURE_PANE")"
  assert_eq "$(capture_locale "$locale" "$capture_expected")" \
    "rc=0 source=$source screen=yes state=$state" "real tmux capture: $phase pane with locale [$locale]"
done <<'ROWS'
live|C.UTF-8|local|unjudged
live||local|unjudged
dead|C.UTF-8|local-dead|exited
dead||local-dead|exited
ROWS

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
