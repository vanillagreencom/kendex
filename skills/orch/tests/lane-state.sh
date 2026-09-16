#!/usr/bin/env bash
# Tests for orch/scripts/lib/lane-state.sh: the ONE judge of what a lane is
# doing, and the production callers that must not disagree about it.
#
# Before this library there were three judges — oversee-watch read the pane
# screen, `open-terminal --wake` read /proc, and oversee-succeed read the
# working predicate alone — and the first two answered differently about the
# same lane inside one minute. The sections here are that contract:
#
#   § states     one row per state the judge can name, over pane screens and
#                process observations, each row the inverse of its neighbours
#   § observe    what lane_pane_observe hands the judge, and what it refuses
#                to hand it
#   § agreement  one screen read by BOTH the watch and the wake, whose two
#                answers must be the same word
#   § control    the must-fail inverse: a judge that reads the harness process
#                and not the pane — the wake as it was — calls the idle screen
#                unjudged
#
# The sandbox, its tmux and pgrep stubs and its assertions are
# lib/oversee-watch-harness.sh, the same ones the watch's own suites drive, so
# no screen or process here is a second fixture of something already measured.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
# An inherited or configured provider would turn the wake rows hosted.
export ORCH_LANE_HOST=local
# shellcheck source=lib/oversee-watch-harness.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/oversee-watch-harness.sh"
# shellcheck source=lib/shared-skill-libs.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/shared-skill-libs.sh"

SCRIPTS_DIR="$REPO_ROOT/skills/orch/scripts"
# The library under test, sourced into this shell: the judge is a function, and
# a call to it is the smallest surface that can fail.
# shellcheck source=../scripts/lib/lane-state.sh
source "$SCRIPTS_DIR/lib/lane-state.sh"

COMPOSER=$'\xe2\x9d\xaf\xc2\xa0'

# One case's stub directory serves every direct call below: the harness's pgrep
# answers from it, so a row's process observation is the file it writes and
# never this machine's process table.
new_case judge
export STUB_DIR
export PATH="$TMP_ROOT/bin:$PATH"
printf '4242\n' > "$STUB_DIR/kids-100.txt"   # pid 100 has a child
printf '2' > "$STUB_DIR/probe-fail-102"  # pid 102's probe cannot run

# The screens, each named for what a lane showing it is doing. The Codex ones
# are the byte-exact captures under fixtures/; the Claude ones are the shapes
# oversee_watch_lanes.sh already pins, kept whole here so a row's premise is
# visible beside it.
screen_for() {
  case "$1" in
    idle) printf '%s\n%s\n' '⏺ Done: the PR is merged.' "$COMPOSER" ;;
    working) printf '%s\n%s\n' '✶ Germinating… (29m 16s · ↓ 58.7k tokens)' "$COMPOSER" ;;
    asking) printf '%s\n%s\n' '⏺ I found two ways to do this.' '❯ 1. Yes' ;;
    walled) printf '%s\n\n%s\n%s\n' '⏺ I will keep going.' "You've hit your session limit · resets 21:00" "$COMPOSER" ;;
    shell) printf '%s\n' 'method@box ~/dev/kendex (main)>' ;;
    blank) printf '\n   \n' ;;
    capacity) cat "$CODEX_PANES/codex-model-capacity.txt" ;;
    codex_idle) cat "$CODEX_PANES/codex-idle-after-turn.txt" ;;
    codex_working) cat "$CODEX_PANES/codex-working.txt" ;;
    claude_dialog) cat "$CODEX_PANES/claude-dialog-permission.txt" ;;
    *) printf 'screen_for: no such screen: %s\n' "$1" >&2; return 1 ;;
  esac
}

echo "=== lane-state § states: one row per state, over screens and process reads ==="

# NAME|WINDOW|CMD|PID|SCREEN|SESSION|WANT
#
# Every state the judge can name has a row, and each row is the inverse of a
# neighbour: the same screen under a different process observation, or the same
# process under a different screen, lands elsewhere in the table. WANT is the
# one word plus the status, so a row fails on the fact it names.
while IFS='|' read -r name window cmd pid screen session want; do
  [[ -n "$name" ]] || continue
  row_state=""
  row_rc=0
  lane_state row_state "$window" "$cmd" "$pid" "$(screen_for "$screen")" "$session" || row_rc=$?
  assert_eq "$row_state rc=$row_rc" "$want rc=0" "$name"
done <<'ROWS'
no window is gone, whatever its last screen said|gone|claude|100|idle||gone
a bare shell with nothing under it is exited|listed|bash|101|shell||exited
a login shell reports itself dashed and is exited all the same|listed|-bash|101|shell||exited
a bare shell WITH a child is the lane, not its grave|listed|fish|100|idle||idle
a probe that cannot run leaves the screen to answer, never exited|listed|bash|102|idle||idle
a spent account outranks the prompt its banner sits above|listed|claude|100|walled||walled
a dialog waiting on an answer is asking|listed|claude|100|asking||asking
a permission dialog is the same question|listed|claude|100|claude_dialog||asking
a streaming token counter is a turn in flight|listed|claude|100|working||working
a codex turn in flight is the same answer|listed|codex|100|codex_working||working
a composer under a finished turn is idle|listed|claude|100|idle||idle
a codex composer under a finished turn is idle|listed|codex|100|codex_idle||idle
a codex capacity refusal parks the lane, so it is idle|listed|codex|100|capacity||idle
a screen with no marker at all and no process read is unjudged|listed|claude|100|blank||unjudged
a markerless screen takes the harness process when there is one|listed|claude|100|blank|busy|working
an idle harness process answers a markerless screen too|listed|claude|100|blank|idle|idle
a session read that could not judge leaves the lane unjudged|listed|claude|100|blank|unjudged|unjudged
the screen outranks the process: a working pane is not idle|listed|claude|100|working|idle|working
the screen outranks the process: an idle pane is not busy|listed|claude|100|idle|busy|idle
ROWS

# A scan that fails is not an answer: exit 2 and `unjudged`, never a verdict a
# caller could act on, and never the `idle` the session read claimed. The grep
# here is a stub that fails the way a broken one would, since no screen can
# make the real one exit 2.
cat > "$TMP_ROOT/bin/grep" <<'EOF'
#!/usr/bin/env bash
[[ -z "${LANE_STATE_GREP_FAIL:-}" ]] || { printf 'E_GREP\n' >&2; exit 2; }
exec /usr/bin/grep "$@"
EOF
chmod +x "$TMP_ROOT/bin/grep"
# Bash caches the path of a command it has already run, and every row above ran
# the real grep: without this the stub below is never reached and the row passes
# on the answer it was meant to disprove.
hash -r
scan_rc=0
scan_state=""
LANE_STATE_GREP_FAIL=1 lane_state scan_state listed claude 100 "$(screen_for idle)" idle || scan_rc=$?
assert_eq "$scan_state rc=$scan_rc" "unjudged rc=2" \
  "a failed scan is exit 2 and unjudged, never the idle its session read claimed"
rm -f -- "${TMP_ROOT:?}/bin/grep"
hash -r

echo "=== lane-state § observe: the pane handed to the judge ==="

# A tmux that treats a -F format string the way the real one does: it
# substitutes the #{...} placeholders and copies EVERY other character through
# unchanged, a backslash escape included. Measured on tmux 3.4, where
# `-F '#{window_name}\t#{pane_id}'` prints a literal backslash-t and no tab —
# which is what made the observer's first spelling of this read every window as
# no match. A stub that merely replays a tab-separated table cannot catch that,
# so this one renders the format the observer actually sends.
#
# In its own directory rather than over the harness's tmux: run_watch below
# builds its PATH with the harness bin first, so the watch keeps the stub its
# own suites drive and only the observer and the wake see this one.
OBS_BIN="$TMP_ROOT/obsbin"; mkdir -p "$OBS_BIN"
cat > "$OBS_BIN/tmux" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
case "${1:-}" in
  list-panes)
    fmt=""
    while [[ $# -gt 0 ]]; do [[ "$1" == "-F" ]] && fmt="$2"; shift; done
    while IFS=$'\t' read -r name pane pid cmd; do
      [[ -n "$name" ]] || continue
      row="$fmt"
      row="${row//'#{window_name}'/$name}"
      row="${row//'#{pane_id}'/$pane}"
      row="${row//'#{pane_pid}'/$pid}"
      row="${row//'#{pane_current_command}'/$cmd}"
      printf '%s\n' "$row"
    done < "$PANE_FIELDS"
    exit 0 ;;
  capture-pane)
    target=""
    while [[ $# -gt 0 ]]; do [[ "$1" == "-t" ]] && target="$2"; shift; done
    [[ -f "$STUB_DIR/pane-$target.txt" ]] || exit 1
    cat "$STUB_DIR/pane-$target.txt"; exit 0 ;;
esac
exit 1
EOF
chmod +x "$OBS_BIN/tmux"
# One pane per line: window name, pane id, pane process, foreground command.
PANE_FIELDS="$TMP_ROOT/pane-fields.txt"
export PANE_FIELDS
PATH="$OBS_BIN:$PATH"
hash -r

printf '%s\n' "⏺ Done." "$COMPOSER" > "$STUB_DIR/pane-%3.txt"

printf 'CC-1\t%%3\t100\tclaude\nCC-9\t%%4\t101\tbash\n' > "$PANE_FIELDS"
lane_pane_observe CC-1
assert_eq "$LANE_PANE_CMD/$LANE_PANE_PID/${LANE_PANE_SCREEN:+screen}" "claude/100/screen" \
  "the window's own pane is what the observer hands the judge"

lane_pane_observe CC-404
assert_eq "${LANE_PANE_CMD:-empty}/${LANE_PANE_PID:-empty}/${LANE_PANE_SCREEN:-empty}" "empty/empty/empty" \
  "a window this server does not hold observes nothing"

printf 'CC-1\t%%3\t100\tclaude\nCC-1\t%%5\t200\tcodex\n' > "$PANE_FIELDS"
lane_pane_observe CC-1
assert_eq "${LANE_PANE_CMD:-empty}/${LANE_PANE_PID:-empty}/${LANE_PANE_SCREEN:-empty}" "empty/empty/empty" \
  "two windows sharing a name observe nothing rather than guess between them"

# The inverse that decides whether a wake is safe: an unobserved pane must not
# reach the judge as an idle one.
unobserved=""
lane_state unobserved listed "$LANE_PANE_CMD" "$LANE_PANE_PID" "$LANE_PANE_SCREEN"
assert_eq "$unobserved" "unjudged" "an unobserved pane is unjudged, never idle"

echo "=== lane-state § agreement: the watch and the wake on one screen ==="

# The wake's sandbox. A wake refuses BEFORE it looks for a session, so the whole
# of it is a worktree whose `path` answers and the harness tmux serving the
# screen as the item's window. The script resolves its libs beside itself, so
# the copy is a whole fixture tree rather than one file.
WAKE_REPO="$TMP_ROOT/wake-repo"
mkdir -p "$WAKE_REPO/scripts/lib" "$TMP_ROOT/wt/CC-1"
cp "$SCRIPTS_DIR/open-terminal" "$SCRIPTS_DIR/lane-host" "$SCRIPTS_DIR/git-context" "$WAKE_REPO/scripts/"
cp "$SCRIPTS_DIR"/lib/*.sh "$WAKE_REPO/scripts/lib/"
orch_fixture_shared_libs "$WAKE_REPO"
chmod +x "$WAKE_REPO/scripts/open-terminal"
git -C "$WAKE_REPO" init -q
cat > "$TMP_ROOT/bin/worktree-stub" <<EOF
#!/usr/bin/env bash
[[ "\${1:-}" != path ]] || { printf '%s\n' "$TMP_ROOT/wt/\${2:-x}"; exit 0; }
exit 1
EOF
chmod +x "$TMP_ROOT/bin/worktree-stub"

# wake_state SCREEN PID CMD — the state `open-terminal --wake` judged CC-1 to
# be in. A refusal names it outright; a lane it let through reaches the session
# scan, which finds none in this sandbox, and that is the wake acting on `idle`.
wake_state() {
  local out rc=0
  screen_for "$1" > "$STUB_DIR/pane-%3.txt"
  printf 'CC-1\t%%3\t%s\t%s\n' "$2" "$3" > "$PANE_FIELDS"
  out="$(cd "$WAKE_REPO" && PATH="$OBS_BIN:$TMP_ROOT/bin:$PATH" \
    env STUB_DIR="$STUB_DIR" TMUX=fake WORKTREE_CLI="$TMP_ROOT/bin/worktree-stub" \
        LANES_HOME="$TMP_ROOT/wake-lanes" \
        ./scripts/open-terminal --wake --harness claude CC-1 2>&1)" || rc=$?
  case "$out" in
    *"wake-refused item=CC-1 reason="*)
      out="${out#*wake-refused item=CC-1 reason=}"
      printf '%s' "${out%%[!a-z]*}" ;;
    *"session-missing item=CC-1"*) printf 'idle' ;;
    *) printf 'no-verdict rc=%s' "$rc" ;;
  esac
}

# watch_event SCREEN PID CMD — the same screen put to oversee-watch, as the
# lane event it emits. Two runs: the watch debounces its exited and idle
# reports, and the second run is where a debounced one goes out.
watch_event() {
  local out
  screen_for "$1" > "$STUB_DIR/pane-gh-2.txt"
  printf '%s\n' "$2" > "$STUB_DIR/panepid-gh-2.txt"
  printf '%s\n' "$3" > "$STUB_DIR/cmd-gh-2.txt"
  printf 'gh-2\n' > "$STUB_DIR/windows.txt"
  out="$(run_watch -- gh-2 2>/dev/null || true)"
  out+=$'\n'"$(run_watch -- gh-2 2>/dev/null || true)"
  case "$out" in
    *"EVENT usage-limit gh-2"*) printf 'usage-limit' ;;
    *"EVENT lane-asking gh-2"*) printf 'lane-asking' ;;
    *"EVENT lane-exited gh-2"*) printf 'lane-exited' ;;
    *"EVENT model-capacity gh-2"*) printf 'model-capacity' ;;
    *"EVENT idle-after-return gh-2"*) printf 'idle-after-return' ;;
    *) printf 'none' ;;
  esac
}

# SCREEN|PANE PID|PANE CMD|THE STATE BOTH MUST READ|THE WATCH'S EVENT FOR IT
#
# Two assertions per row on one screen: the wake names the state in its own
# refusal, and the watch emits the event that state produces. A working lane's
# event is `none`, which is the claim that it took no idle, asking, walled or
# exited line either.
while IFS='|' read -r screen pid cmd want event; do
  [[ -n "$screen" ]] || continue
  new_case "agree-$screen"
  export STUB_DIR
  printf '4242\n' > "$STUB_DIR/kids-100.txt"
  assert_eq "$(watch_event "$screen" "$pid" "$cmd")" "$event" \
    "the watch reads the $screen screen as $want"
  assert_eq "$(wake_state "$screen" "$pid" "$cmd")" "$want" \
    "the wake reads the same $screen screen as $want"
done <<'ROWS'
working|100|claude|working|none
asking|100|claude|asking|lane-asking
walled|100|claude|walled|usage-limit
shell|101|bash|exited|lane-exited
idle|100|claude|idle|idle-after-return
ROWS

echo "=== lane-state § control: the judge that reads the process and not the pane ==="

# The must-fail inverse the change exists to close. Before this library the wake
# read the harness process and nothing else, so a lane with no /proc entry of
# its own — every hosted lane, whose harness runs on another machine — came back
# `unjudged` however plainly its pane said idle. The mutant restores exactly
# that: the pane rungs cut out, the session read left standing.
MUTANT_LIB="$TMP_ROOT/mutant-lane-state.sh"
awk '
  /^  slice="\$\(pane_below_last_turn/ { cut = 1 }
  /^  case "\$session" in$/ { cut = 0 }
  !cut
' "$SCRIPTS_DIR/lib/lane-state.sh" > "$MUTANT_LIB"
assert_eq "$(cmp -s "$MUTANT_LIB" "$SCRIPTS_DIR/lib/lane-state.sh" && echo same || echo differs)" "differs" \
  "control: the mutant really drops the pane rungs"
mutant_state="$(
  source "$MUTANT_LIB"
  answer=""
  lane_state answer listed claude 100 "$(screen_for idle)" ""
  printf '%s' "$answer"
)"
assert_eq "$mutant_state" "unjudged" \
  "control: reading only the harness process calls the idle screen unjudged"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
