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
#                to hand it, over both forms of recorded window
#   § composer    whether the lane's live input line is empty, the one question
#                a caller about to TYPE into the pane must ask
#   § process ownership
#                the host process table, zombie states and unreadable processes,
#                with one must-fail control on lane_owned_processes
#   § agreement  one screen read by BOTH the watch and the wake. The pane rungs
#                are shared, so above idle the two answer the same word; the
#                idle rung falls through to the harness-process read that only
#                the wake makes, and a box with no /proc parts them there
#   § verb       `lanes state` as the third caller: the wiring around the judge,
#                and the host probe that reports beside the state, never as it,
#                with one must-fail control on the verb
#   § pi rows    a Pi lane judged from the rows its own hook writes, over
#                screens that would answer otherwise
#   § control    the must-fail control on the judge: one that reads the harness
#                process and not the pane — the wake as it was — calls the idle
#                screen unjudged, and one that reads a rowless Pi lane's pane
#                calls it idle
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
# shellcheck source=lib/process-table.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/process-table.sh"
# mutant_scripts and mutate_file, the two halves of the verb's control.
# shellcheck source=lib/growth-state.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/growth-state.sh"

SCRIPTS_DIR="$REPO_ROOT/skills/orch/scripts"
SCRIPT_DIR="$SCRIPTS_DIR"
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

# The screens, each named for what a lane showing it is doing. The Codex and
# Copilot ones are the byte-exact captures under fixtures/, the Copilot ones off
# Copilot CLI 1.0.88 in a tmux pane; the Claude ones are the shapes
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
    copilot_idle) cat "$CODEX_PANES/copilot-idle.txt" ;;
    copilot_draft) cat "$CODEX_PANES/copilot-composer-draft.txt" ;;
    copilot_working) cat "$CODEX_PANES/copilot-working.txt" ;;
    copilot_trust) cat "$CODEX_PANES/copilot-dialog-trust.txt" ;;
    pi_working) cat "$CODEX_PANES/pi-working.txt" ;;
    pi_header_only) sed '/^──/,$d' "$CODEX_PANES/pi-working.txt" ;;
    pi_editor_only) sed -n '/^──/,$p' "$CODEX_PANES/pi-working.txt" ;;
    *) printf 'screen_for: no such screen: %s\n' "$1" >&2; return 1 ;;
  esac
}

echo "=== lane-state § states: one row per state, over screens and process reads ==="

# NAME|WINDOW|CMD|PID|SCREEN|SESSION|ACCOUNT|WANT
#
# Every state the judge can name has a row, and each row is the inverse of a
# neighbour: the same screen under a different process observation or account
# reading, or the same process under a different screen, lands elsewhere in the
# table. WANT is the one word plus the status, so a row fails on the fact it
# names.
while IFS='|' read -r name window cmd pid screen session account want; do
  [[ -n "$name" ]] || continue
  row_state=""
  row_rc=0
  lane_state row_state "$window" "$cmd" "$pid" "$(screen_for "$screen")" "$session" "$account" || row_rc=$?
  assert_eq "$row_state rc=$row_rc" "$want rc=0" "$name"
done <<'ROWS'
no window is gone, whatever its last screen said|gone|claude|100|idle|||gone
a bare shell with nothing under it is exited|listed|bash|101|shell|||exited
a login shell reports itself dashed and is exited all the same|listed|-bash|101|shell|||exited
a bare shell WITH a child is the lane, not its grave|listed|fish|100|idle|||idle
a probe that cannot run leaves the screen to answer, never exited|listed|bash|102|idle|||idle
a spent account outranks the prompt its banner sits above|listed|claude|100|walled|||walled
a banner whose account reads room again is a lifted wall, and the prompt under it answers|listed|claude|100|walled||room|idle
a banner whose account still reads walled stays walled|listed|claude|100|walled||walled|walled
an account reading the judge has no word for is unjudged, never a lifted wall|listed|claude|100|walled||lifted|unjudged
a room reading lifts nothing on a screen with no banner|listed|claude|100|working||room|working
a dialog waiting on an answer is asking|listed|claude|100|asking|||asking
a permission dialog is the same question|listed|claude|100|claude_dialog|||asking
a streaming token counter is a turn in flight|listed|claude|100|working|||working
a codex turn in flight is the same answer|listed|codex|100|codex_working|||working
a composer under a finished turn is idle|listed|claude|100|idle|||idle
a codex composer under a finished turn is idle|listed|codex|100|codex_idle|||idle
a codex capacity refusal parks the lane, so it is idle|listed|codex|100|capacity|||idle
a screen with no marker at all and no process read is unjudged|listed|claude|100|blank|||unjudged
a markerless screen takes the harness process when there is one|listed|claude|100|blank|busy||working
an idle harness process answers a markerless screen too|listed|claude|100|blank|idle||idle
a session read that could not judge leaves the lane unjudged|listed|claude|100|blank|unjudged||unjudged
the screen outranks the process: a working pane is not idle|listed|claude|100|working|idle||working
a busy process answers before the idle rung, since a turn's first seconds draw a marker and no working hint|listed|claude|100|idle|busy||working
a process read that could not tell never becomes idle, however plainly the screen reads it|listed|claude|100|idle|unjudged||unjudged
the same for the codex screen a live session between tool calls draws|listed|codex|100|codex_idle|unjudged||unjudged
a process read that says idle agrees with the marker and the lane is idle|listed|claude|100|idle|idle||idle
a copilot composer with its frame's rule under it is idle|listed|node|100|copilot_idle|||idle
a copilot composer holding a draft is the same live input|listed|node|100|copilot_draft|||idle
a copilot footer running a command is a turn in flight|listed|node|100|copilot_working|||working
copilot's folder-trust dialog is asking|listed|node|100|copilot_trust|||asking
ROWS

# The provider creates the remote harness; tmux holds only its live ssh child.
echo "=== lane-state § remote harness: one provider read, no ssh-child verdict ==="
# A status=verb host answering the absent-verb 2 is a provider fault: the lane
# stays unjudged and no pane stands in for the read.
export ORCH_LANE_HOST="$REPO_ROOT/skills/orch/tests/fixtures/lane-host" LANE_HOST_STUB_LOG="$STUB_DIR/host.calls"
for row in 'exited|0|exited|provider' 'running|0|idle|' 'exited|2|unjudged|' 'running|1|unjudged|' 'running|7|unjudged|' 'garbage|0|unjudged|'; do
  IFS='|' read -r remote_status provider_rc want source <<<"$row"
  export LANE_HOST_STUB_HARNESS_STATE="$remote_status" LANE_HOST_STUB_PROBE_STATUS="$provider_rc"
  : > "$LANE_HOST_STUB_LOG"; : > "$STUB_DIR/pgrep.calls"
  remote_result="$(cd -- "$TMP_ROOT/repo" && lane_state row_state listed bash 100 "$(screen_for idle)" "" "" "" TEST-1 claude 2> "$STUB_DIR/probe.note" && printf '%s source=%s' "$row_state" "$LANE_EXIT_SOURCE")" || exit 1
  assert_eq "$remote_result" "$want source=$source" "provider $remote_status/$provider_rc judges the hosted lane"
  assert_eq "$(grep -c '^status --item TEST-1 --harness claude ' "$LANE_HOST_STUB_LOG")" "1" "one provider read per hosted judgment"
  assert_eq "$(wc -c < "$STUB_DIR/pgrep.calls" | tr -d ' ')" "0" "a hosted judgment never reads the local ssh child"
  if [[ "$want" == unjudged ]]; then
    note_rc="$provider_rc"
    [[ "$provider_rc" -ne 0 ]] || note_rc=2
    assert_eq "$(cat "$STUB_DIR/probe.note")" "lane-state: harness-probe-failed item=TEST-1 status=$note_rc" "failed reads keep their diagnostic"
  fi
done
# The old local-only walk leaves this remote exit hidden behind that child.
while IFS='|' read -r name old new provider_rc want; do
  REMOTE_MUTANT="$(mutant_scripts "$name" lib/lane-state.sh)" || exit 1
  mutate_file "$REMOTE_MUTANT/lib/lane-state.sh" "$old" "$new"
  export LANE_HOST_STUB_HARNESS_STATE=exited LANE_HOST_STUB_PROBE_STATUS="$provider_rc"
  remote_control="$(cd -- "$TMP_ROOT/repo" && source "$REMOTE_MUTANT/lib/lane-state.sh" && lane_state row_state listed bash 100 "$(screen_for idle)" "" "" "" TEST-1 claude && printf '%s' "$row_state")" || exit 1
  assert_eq "$remote_control" "$want" "control: $name violates the hosted judgment"
done <<'ROWS'
remote-local-walk|  if [[ -n "$_ls_item" ]]; then|  if [[ -n "$_ls_item" && false == true ]]; then|0|idle
remote-failure|      2) printf -v "$_ls_out" unjudged; return 0 ;;|      2) printf -v "$_ls_out" exited; return 0 ;;|7|exited
ROWS
export ORCH_LANE_HOST=local
unset LANE_HOST_STUB_HARNESS_STATE LANE_HOST_STUB_PROBE_STATUS

# Whether a launcher sees the harness up on a pane it opened: the Copilot
# composer is two lines, so it is the one screen the one-line pattern misses.
# A dialog answers no, the direction the launcher waits out.
while IFS='|' read -r name screen want; do
  [[ -n "$name" ]] || continue
  up=no
  ! pane_harness_up "$(screen_for "$screen")" || up=yes
  assert_eq "$up" "$want" "$name"
done <<'ROWS'
a claude composer is the harness up|idle|yes
an idle copilot composer is the harness up|copilot_idle|yes
a copilot command in flight is the harness up|copilot_working|yes
copilot's folder-trust dialog is not|copilot_trust|no
a Pi compact working screen is the harness up|pi_working|yes
a Pi startup interrupted before its editor is not ready|pi_header_only|no
a Working border without Pi startup is not proof of Pi|pi_editor_only|no
a bare shell is not the harness up|shell|no
ROWS

# Each requirement in Pi's readiness proof has its own inverse. The disabled
# proof rejects the live capture; dropping either requirement accepts a partial
# redraw. mutate_file asserts each edit on a private copy of the shared owner.
for row in 'disabled|pi_working|no' 'header|pi_editor_only|yes' 'editor|pi_header_only|yes'; do
  rule="${row%%|*}" rest="${row#*|}" screen="${rest%%|*}" want="${rest#*|}"
  pi_mutant="$TMP_ROOT/pi-readiness-$rule.sh"
  cp -- "$SCRIPTS_DIR/lib/lane-state.sh" "$pi_mutant"
  case "$rule" in
    disabled) mutate_file "$pi_mutant" '|| { grep -Eq -- "$PI_COMPACT_HEADER_RE"' '|| { false && grep -Eq -- "$PI_COMPACT_HEADER_RE"' ;;
    header) mutate_file "$pi_mutant" 'grep -Eq -- "$PI_COMPACT_HEADER_RE" <<<"$1" &&' 'true &&' ;;
    editor) mutate_file "$pi_mutant" '&& grep -Eq -- "$PI_COMPACT_EDITOR_RE" <<<"$1";' '&& true;' ;;
  esac
  pi_screen="$(screen_for "$screen")"
  pi_up="$(
    source "$pi_mutant"
    if pane_harness_up "$pi_screen"; then printf yes; else printf no; fi
  )"
  assert_eq "$pi_up" "$want" "control: Pi readiness $rule changes the $screen answer"
done

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
    [[ -z "${PANE_LIST_FAIL:-}" ]] || exit 1
    while IFS=$'\t' read -r session name pane pid cmd; do
      [[ -n "$name" ]] || continue
      row="$fmt"
      row="${row//'#{session_name}'/$session}"
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
# One pane per line: session name, window name, pane id, pane process,
# foreground command.
PANE_FIELDS="$TMP_ROOT/pane-fields.txt"
export PANE_FIELDS
PATH="$OBS_BIN:$PATH"
hash -r

printf '%s\n' "⏺ Done." "$COMPOSER" > "$STUB_DIR/pane-%3.txt"

printf 'kendex\tCC-1\t%%3\t100\tclaude\nkendex\tCC-9\t%%4\t101\tbash\n' > "$PANE_FIELDS"
lane_pane_observe CC-1
assert_eq "$LANE_PANE_CMD/$LANE_PANE_PID/${LANE_PANE_SCREEN:+screen}" "claude/100/screen" \
  "the window's own pane is what the observer hands the judge"

lane_pane_observe CC-404
assert_eq "${LANE_PANE_CMD:-empty}/${LANE_PANE_PID:-empty}/${LANE_PANE_SCREEN:-empty}" "empty/empty/empty" \
  "a window this server does not hold observes nothing"

# The rival pane gets a screen of its own, and it must be one the judge would
# happily answer from: with no capture staged for it, the stub's capture-pane
# fails and the observer comes back empty for that reason instead of for the
# duplicate name, and the row below passes with the guard removed.
printf '%s\n%s\n' '⏺ Done: the other lane.' "$COMPOSER" > "$STUB_DIR/pane-%5.txt"
printf 'kendex\tCC-1\t%%3\t100\tclaude\nkendex\tCC-1\t%%5\t200\tcodex\n' > "$PANE_FIELDS"
# The count comes back at none here, where the resolution below answers 2 for
# the same two panes: this function has two answers and that one has three, so
# nothing a caller reads after an observe distinguishes the silences.
lane_pane_observe CC-1
assert_eq "${LANE_PANE_CMD:-empty}/${LANE_PANE_PID:-empty}/${LANE_PANE_SCREEN:-empty}/$LANE_PANE_COUNT" "empty/empty/empty/0" \
  "two windows sharing a name observe nothing rather than guess between them"

# The inverse that decides whether a wake is safe: an unobserved pane must not
# reach the judge as an idle one.
unobserved=""
lane_state unobserved listed "$LANE_PANE_CMD" "$LANE_PANE_PID" "$LANE_PANE_SCREEN"
assert_eq "$unobserved" "unjudged" "an unobserved pane is unjudged, never idle"

# The other form a recorded window comes in. The wake and `lanes state` pass a
# bare name; a fleet record carries tmux's own `session:window` target, and
# `lane-close` starts from that record. Two sessions hold a window of the same
# name here, so a resolution that ignored the session column would answer with
# the wrong lane's pane.
printf 'kendex\tCC-1\t%%3\t100\tclaude\nother\tCC-1\t%%5\t200\tcodex\n' > "$PANE_FIELDS"
lane_pane_observe kendex:CC-1
assert_eq "$LANE_PANE_ID/$LANE_PANE_CMD/$LANE_PANE_COUNT" "%3/claude/1" \
  "a session-qualified window resolves the pane under exactly that session"

lane_pane_observe other:CC-1
assert_eq "$LANE_PANE_ID/$LANE_PANE_CMD/$LANE_PANE_COUNT" "%5/codex/1" \
  "the same window name under the other session resolves that session's pane"

# tmux's own `-t` prefix-matches a session name. A lane whose session died
# would then resolve a sibling's window of the same name, so this one does not.
lane_pane_observe kend:CC-1
assert_eq "${LANE_PANE_ID:-empty}/$LANE_PANE_COUNT" "empty/0" \
  "a session name that only prefixes the pane's own resolves nothing"

# What `lane-close` reads to tell its three refusals apart: the count is the
# whole difference between a window that is gone and a name two windows share,
# and neither hands back a pane to act on.
resolve_rc=0
lane_pane_resolve CC-404 || resolve_rc=$?
assert_eq "rc=$resolve_rc count=$LANE_PANE_COUNT pane=${LANE_PANE_ID:-empty}" "rc=1 count=0 pane=empty" \
  "a window no pane carries resolves a count of none"

printf 'kendex\tCC-1\t%%3\t100\tclaude\nkendex\tCC-1\t%%5\t200\tcodex\n' > "$PANE_FIELDS"
resolve_rc=0
lane_pane_resolve kendex:CC-1 || resolve_rc=$?
assert_eq "rc=$resolve_rc count=$LANE_PANE_COUNT pane=${LANE_PANE_ID:-empty}" "rc=1 count=2 pane=empty" \
  "two panes under one session and name resolve to a count, never a guess"

# A pane list that could not be read is no answer at all, and must never reach
# a caller as the absence its count would otherwise spell.
resolve_rc=0
export PANE_LIST_FAIL=1
lane_pane_resolve kendex:CC-1 || resolve_rc=$?
unset PANE_LIST_FAIL
assert_eq "rc=$resolve_rc count=$LANE_PANE_COUNT" "rc=2 count=0" \
  "a failed pane list is exit 2, never a window this server does not hold"

echo "=== lane-state § process ownership: host process reads ==="

# The names each harness's process carries, as the ownership read and
# pane-write match them. Copilot's native binary reads MainThread on Linux and
# its node loader node-MainThread, which a signal must not stand in for.
while IFS='|' read -r name harness process want; do
  [[ -n "$name" ]] || continue
  got=no
  ! LANE_TEST_RE="$(lane_harness_process_re "$harness")" awk -v n="$process" \
    'BEGIN { exit !(n ~ ENVIRON["LANE_TEST_RE"]) }' || got=yes
  assert_eq "$got" "$want" "$name"
done <<'ROWS'
claude runs under its own name|claude|claude|yes
a name that only contains the harness's is another process|claude|claude-x|no
copilot's native binary on Linux|copilot|MainThread|yes
copilot's binary where ps prints the executable|copilot|copilot|yes
copilot's node loader is not the process a stop signals|copilot|node-MainThread|no
MainThread belongs to no other harness|claude|MainThread|no
a harness name's metacharacters match only themselves|kz)harness|kz)harness|yes
ROWS

if proc_table_readable; then
  new_case process-ownership
  PROCESS_ROOT="$TMP_ROOT/process-root"
  PROCESS_HARNESS="$PROCESS_ROOT/kz)harness"
  PROCESS_ZOMBIE_FILE="$PROCESS_ROOT/zombie-pid"
  PROCESS_FIXTURE_PIDS=""
  mkdir -p "$PROCESS_ROOT"
  PROCESS_REAL_BASH="$(command -v bash)" || exit 1
  cp "$PROCESS_REAL_BASH" "$PROCESS_HARNESS"

  python3 - "$PROCESS_HARNESS" "$PROCESS_ZOMBIE_FILE" <<'PY' &
import os
import sys
import time
child = os.fork()
if child == 0:
    os.execl(sys.argv[1], sys.argv[1], "-c", "exit 0")
with open(sys.argv[2], "w", encoding="utf-8") as output:
    output.write(f"{child}\n")
time.sleep(30)
PY
  PROCESS_ZOMBIE_PARENT=$!
  PROCESS_FIXTURE_PIDS="$PROCESS_ZOMBIE_PARENT"
  (cd "$PROCESS_ROOT" && exec "$PROCESS_HARNESS" -c 'trap "exit 0" TERM; while :; do sleep 1; done') &
  PROCESS_LIVE_ONE=$!
  (cd "$PROCESS_ROOT" && exec "$PROCESS_HARNESS" -c 'trap "exit 0" TERM; while :; do sleep 1; done') &
  PROCESS_LIVE_TWO=$!
  python3 -c 'import os,time; open("/proc/self/comm","w").write("kz ) state\n"); time.sleep(30)' &
  PROCESS_WEIRD=$!
  PROCESS_FIXTURE_PIDS+=" $PROCESS_LIVE_ONE $PROCESS_LIVE_TWO $PROCESS_WEIRD"
  process_fixture_cleanup() {
    local fixture_pid
    for fixture_pid in $PROCESS_FIXTURE_PIDS; do kill "$fixture_pid" 2>/dev/null || true; done
    for fixture_pid in $PROCESS_FIXTURE_PIDS; do wait "$fixture_pid" 2>/dev/null || true; done
  }
  trap 'process_fixture_cleanup; rm -rf "$TMP_ROOT"' EXIT

  PROCESS_ZOMBIE_PID=""
  PROCESS_ZOMBIE_STATE=""
  for _process_try in {1..100}; do
    if [[ -s "$PROCESS_ZOMBIE_FILE" ]]; then
      PROCESS_ZOMBIE_PID="$(<"$PROCESS_ZOMBIE_FILE")"
      PROCESS_ZOMBIE_STATE="$(lane_process_state "$PROCESS_ZOMBIE_PID")" || PROCESS_ZOMBIE_STATE=error
      [[ "$PROCESS_ZOMBIE_STATE" != Z ]] || break
    fi
    sleep 0.02
  done
  assert_eq "$PROCESS_ZOMBIE_STATE" Z "the state reader finds a zombie after the command name's last parenthesis"
  assert_eq "$(lane_process_state "$PROCESS_WEIRD")" S \
    "the state reader handles spaces and a closing parenthesis in the command name"

  PROCESS_OWNED_RC=0
  lane_owned_processes "$PROCESS_ROOT" 'kz)harness' || PROCESS_OWNED_RC=$?
  if [[ "$PROCESS_LIVE_ONE" -lt "$PROCESS_LIVE_TWO" ]]; then
    PROCESS_EXPECTED="$PROCESS_LIVE_ONE $PROCESS_LIVE_TWO"
  else
    PROCESS_EXPECTED="$PROCESS_LIVE_TWO $PROCESS_LIVE_ONE"
  fi
  assert_eq "$LANE_OWNED_PROCESS_PIDS rc=$PROCESS_OWNED_RC" "$PROCESS_EXPECTED rc=0" \
    "a zombie is passed over while both live owned harnesses are returned"

  PROCESS_ZOMBIE_CONTROL_RC=0
  (
    lane_process_state() { printf 'S\n'; }
    lane_owned_processes "$PROCESS_ROOT" 'kz)harness'
  ) || PROCESS_ZOMBIE_CONTROL_RC=$?
  assert_eq "$PROCESS_ZOMBIE_CONTROL_RC" 2 \
    "control: reading the zombie as live makes the ownership read fail"

  # A Copilot lane: a real process named as the Copilot CLI binary is on
  # Linux, in the worktree beside the two harnesses above, which it is not.
  cp "$PROCESS_REAL_BASH" "$PROCESS_ROOT/MainThread"
  (cd "$PROCESS_ROOT" && exec "$PROCESS_ROOT/MainThread" -c 'trap "exit 0" TERM; while :; do sleep 1; done') &
  PROCESS_COPILOT=$!
  PROCESS_FIXTURE_PIDS+=" $PROCESS_COPILOT"
  # The exec renames the child a moment after the fork; the table is read once
  # it has.
  for _process_try in {1..100}; do
    [[ "$(cat "/proc/$PROCESS_COPILOT/comm" 2>/dev/null)" != MainThread ]] || break
    sleep 0.02
  done
  PROCESS_OWNED_RC=0
  lane_owned_processes "$PROCESS_ROOT" copilot || PROCESS_OWNED_RC=$?
  assert_eq "$LANE_OWNED_PROCESS_PIDS rc=$PROCESS_OWNED_RC" "$PROCESS_COPILOT rc=0" \
    "a copilot lane's harness is its MainThread process, and only that one"
  PROCESS_NAME_MUTANT="$TMP_ROOT/lane-state-copilot-name.sh"
  grep -v -F "copilot) printf '%s\n' '^(copilot|MainThread)\$' ;;" "$SCRIPTS_DIR/lib/lane-state.sh" > "$PROCESS_NAME_MUTANT"
  assert_eq "$(cmp -s "$PROCESS_NAME_MUTANT" "$SCRIPTS_DIR/lib/lane-state.sh" && echo same || echo differs)" differs \
    "control: the mutant really drops copilot's process names"
  assert_eq "$(source "$PROCESS_NAME_MUTANT"; lane_owned_processes "$PROCESS_ROOT" copilot; printf '%s' "${LANE_OWNED_PROCESS_PIDS:-none}")" none \
    "control: read under its harness name alone, a copilot lane owns no process"

  # A host without /proc, macOS among them, reads a process's directory
  # through lsof; the stub answers as lsof does, from the directory /proc
  # holds. A host with neither reader has no answer at all, status 3.
  PROCESS_LSOF="$PROCESS_ROOT/lsof-bin"
  mkdir -p "$PROCESS_LSOF"
  cat >"$PROCESS_LSOF/lsof" <<'EOF'
#!/usr/bin/env bash
pid=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == -p ]]; then pid="$2"; shift; fi
  shift
done
cwd="$(readlink -- "/proc/$pid/cwd" 2>/dev/null)" || exit 1
printf 'p%s\nfcwd\nn%s\n' "$pid" "$cwd"
EOF
  chmod +x "$PROCESS_LSOF/lsof"
  PROCESS_OWNED_RC=0
  PROCESS_LSOF_PIDS="$(lane_proc_readable() { return 1; }; PATH="$PROCESS_LSOF:$PATH"
    lane_owned_processes "$PROCESS_ROOT" 'kz)harness' && printf '%s' "$LANE_OWNED_PROCESS_PIDS")" || PROCESS_OWNED_RC=$?
  assert_eq "$PROCESS_LSOF_PIDS rc=$PROCESS_OWNED_RC" "$PROCESS_EXPECTED rc=0" \
    "without /proc the directory read through lsof returns both live owned harnesses"
  PROCESS_OWNED_RC=0
  (lane_proc_readable() { return 1; }; command() { [[ "$*" != "-v lsof" ]] && builtin command "$@"; }
    lane_owned_processes "$PROCESS_ROOT" 'kz)harness') || PROCESS_OWNED_RC=$?
  assert_eq "rc=$PROCESS_OWNED_RC" 'rc=3' "a host with neither /proc nor lsof answers no directory reader"

  PROCESS_FAIL_PS="$PROCESS_ROOT/fail-ps"
  mkdir -p "$PROCESS_FAIL_PS"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 19' > "$PROCESS_FAIL_PS/ps"
  chmod +x "$PROCESS_FAIL_PS/ps"
  PROCESS_FAIL_PS_RC=0
  (set +o pipefail; PATH="$PROCESS_FAIL_PS:$PATH"; lane_owned_processes "$PROCESS_ROOT" 'kz)harness') \
    || PROCESS_FAIL_PS_RC=$?
  assert_eq "$PROCESS_FAIL_PS_RC" 2 \
    "a failed process-table read returns status 2 without caller pipefail"

  process_fixture_cleanup
  PROCESS_FIXTURE_PIDS=""
  trap 'rm -rf "$TMP_ROOT"' EXIT
else
  printf '  skip  process ownership requires procfs\n'
fi

echo "=== lane-state § agreement: the watch and the wake on one screen ==="

# The wake's sandbox. A wake refuses BEFORE it looks for a session, so the whole
# of it is a worktree whose `path` answers and the harness tmux serving the
# screen as the item's window. The script resolves its libs beside itself, so
# the copy is a whole fixture tree rather than one file.
WAKE_REPO="$TMP_ROOT/wake-repo"
mkdir -p "$WAKE_REPO/scripts/lib" "$TMP_ROOT/wt/CC-1"
cp "$SCRIPTS_DIR/open-terminal" "$SCRIPTS_DIR/lane-host" "$SCRIPTS_DIR/workflow-state" "$SCRIPTS_DIR/git-context" "$WAKE_REPO/scripts/"
cp -R "$SCRIPTS_DIR/lib/." "$WAKE_REPO/scripts/lib/"
orch_fixture_shared_libs "$WAKE_REPO"
chmod +x "$WAKE_REPO/scripts/open-terminal"
git -C "$WAKE_REPO" init -q
cat > "$TMP_ROOT/bin/worktree-stub" <<EOF
#!/usr/bin/env bash
[[ "\${1:-}" != path ]] || { printf '%s\n' "$TMP_ROOT/wt/\${2:-x}"; exit 0; }
exit 1
EOF
chmod +x "$TMP_ROOT/bin/worktree-stub"

# The wake's readers of this machine, stubbed through the shared owner so a
# row's answer is the fixture's and never the host's. lib/process-table.sh
# carries the whole rationale.
PROC_BIN="$TMP_ROOT/proc-bin"
proc_table_install "$PROC_BIN"
PROC_TABLE="$TMP_ROOT/ps-table.txt"
PROC_CWD_FILE="$TMP_ROOT/ps-cwd.txt"
PROC_HIDDEN_PIDS=""
export PROC_TABLE PROC_CWD_FILE PROC_HIDDEN_PIDS
# The default table: one live claude on this host, at a pid that really exists
# so the producer's `did it exit` test answers yes, with a cwd this user can
# read that is not the lane's worktree. That is a colleague's session, and the
# producer walks past it to `idle`.
proc_table_write "$PROC_TABLE" "$$ 1 claude"
proc_cwd_write "$PROC_CWD_FILE"

# wake_state SCREEN PID CMD — the state `open-terminal --wake` judged CC-1 to
# be in. A refusal names it outright; a lane it let through reaches the session
# scan, which finds none in this sandbox, and that is the wake acting on `idle`.
wake_state() {
  local out rc=0
  screen_for "$1" > "$STUB_DIR/pane-%3.txt"
  printf 'kendex\tCC-1\t%%3\t%s\t%s\n' "$2" "$3" > "$PANE_FIELDS"
  out="$(cd "$WAKE_REPO" && PATH="$PROC_BIN:$OBS_BIN:$TMP_ROOT/bin:$PATH" \
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
  # The wake's own word, where it can differ from the watch's. Where
  # proc_table_readable says the producer can read no process at all — every
  # macOS runner, and this suite runs on one — it refuses the whole lane the
  # moment the default table hands it a pid. Every rung above idle is the pane's
  # and is unmoved; only the idle rung falls through to the process read, so
  # only an idle row changes. The watch reads no process and keeps its word on
  # every box.
  wake_want="$want"
  proc_table_readable || [[ "$want" != idle ]] || wake_want=unjudged
  assert_eq "$(watch_event "$screen" "$pid" "$cmd")" "$event" \
    "the watch reads the $screen screen as $want"
  assert_eq "$(wake_state "$screen" "$pid" "$cmd")" "$wake_want" \
    "the wake reads the same $screen screen as $wake_want"
done <<'ROWS'
working|100|claude|working|none
asking|100|claude|asking|lane-asking
walled|100|claude|walled|usage-limit
shell|101|bash|exited|lane-exited
idle|100|claude|idle|idle-after-return
ROWS

# A Copilot lane, whose pane reads node, its npm loader: the watch alone, since
# the wake does not take the harness and the lane's monitor is its own wake.
while IFS='|' read -r screen event; do
  [[ -n "$screen" ]] || continue
  new_case "agree-$screen"
  export STUB_DIR
  printf '4242\n' > "$STUB_DIR/kids-100.txt"
  assert_eq "$(watch_event "$screen" 100 node)" "$event" \
    "the watch reads the $screen screen as $event"
done <<'ROWS'
copilot_idle|idle-after-return
copilot_trust|lane-asking
copilot_working|none
ROWS

# The PRODUCER of `unjudged`, not the word. The two § states rows above hand it
# to the judge as an argument; nothing there runs `lane_session_state`, which is
# what emits it in the field. Here the pane is the same idle screen those rows
# use, and the only thing that can change the answer is the process read: a live
# claude at a pid that exists, whose /proc cwd this user cannot read. That is a
# root-owned session, and the producer refuses the whole lane on it rather than
# walking past it.
new_case agree-unreadable-cwd
export STUB_DIR
printf '4242\n' > "$STUB_DIR/kids-100.txt"
proc_table_write "$PROC_TABLE" "$$ 1 claude"
PROC_HIDDEN_PIDS="$$"
assert_eq "$(wake_state idle 100 claude)" "unjudged" \
  "a wake refuses a lane whose harness process has a cwd it cannot read"

# The must-fail inverse of that arm lives in open-terminal-owned-skip.sh, which
# owns the script it mutates. The row above claims something that suite does not:
# that an idle PANE does not outrank a process read the wake could not make. The
# pane rungs have their own mutant in § control below.
PROC_HIDDEN_PIDS=""

echo "=== lane-state § verb: lanes state, the judge on the command line ==="

# `lanes state` is the third caller, and the only one an overseer types. Its own
# work is the wiring — observe the pane, put it to the judge, print the word —
# plus the hosted fallback the other two have no use for: with no pane on this
# server the provider is the only thing left that can tell a host that is gone
# from one whose screen this machine cannot see.
#
# Its own fixture repository rather than the wake's: the rows below swap
# `lane-host` for a stub, and the wake fixture runs against the real one.
VERB_REPO="$TMP_ROOT/verb-repo"
mkdir -p "$VERB_REPO/scripts/lib"
# Every script, since `lanes state` asks workflow-state for the fleet's lane
# records and that script runs its own neighbours.
for verb_script in "$SCRIPTS_DIR"/*; do
  [[ ! -f "$verb_script" ]] || cp "$verb_script" "$VERB_REPO/scripts/"
done
cp -R "$SCRIPTS_DIR/lib/." "$VERB_REPO/scripts/lib/"
chmod +x "$VERB_REPO/scripts/lanes"
git -C "$VERB_REPO" init -q
# The provider, reduced to the one answer the probe reads: `touch` exits with
# LANE_HOST_TOUCH_RC, which is how a reachable host and an unreachable one
# differ to the caller, and writes the message a real provider writes when it
# cannot reach the host, so the forwarding can be asserted. It records the item
# it was asked about in LANE_HOST_TOUCH_LOG.
PROBE_STDERR='lane-host: ssh: connect to host build-7 port 22: Connection refused'
cat > "$VERB_REPO/scripts/lane-host" <<EOF
#!/usr/bin/env bash
[[ "\${1:-}" == touch ]] || exit 0
[[ "\${2:-}" != --item || -z "\${LANE_HOST_TOUCH_LOG:-}" ]] || printf '%s\n' "\${3:-}" > "\$LANE_HOST_TOUCH_LOG"
[[ "\${LANE_HOST_TOUCH_RC:-0}" -eq 0 ]] || printf '%s\n' '$PROBE_STDERR' >&2
exit "\${LANE_HOST_TOUCH_RC:-0}"
EOF
chmod +x "$VERB_REPO/scripts/lane-host"

new_case verb
export STUB_DIR
printf '4242\n' > "$STUB_DIR/kids-100.txt"

VERB_ERR="$TMP_ROOT/verb.err"
VERB_TOUCH_LOG="$TMP_ROOT/verb.touch"

# verb_state ITEM SCREEN HOST TOUCH_RC [EXTRA_PATH] — what `lanes state` printed
# for ITEM, as `<word> rc=<status> note=<stderr key>`. The state comes off
# stdout and the note off the first `lanes:` line of stderr, kept apart on
# purpose: the probe's answer is reported BESIDE the lane's state and a row that
# folded them could not tell a note from a verdict. A refusal prints no state,
# and its key stands in the state slot. SCREEN `none` stages no pane for the
# item at all, which is the observation a closed window and a duplicated name
# both leave. The pane is staged in session kendex under ITEM's window part,
# so a session-qualified ITEM names it the way a lane record does. VERB_RUN_REPO
# names the checkout whose `lanes` runs, the fixture's unless a control swaps it.
VERB_RUN_REPO="$VERB_REPO"
verb_state() {
  local item="$1" screen="$2" host="$3" touch_rc="$4" extra="${5:-}" out note word rc=0
  if [[ "$screen" == none ]]; then
    : > "$PANE_FIELDS"
  else
    screen_for "$screen" > "$STUB_DIR/pane-%3.txt"
    printf 'kendex\t%s\t%%3\t100\tclaude\n' "${item#*:}" > "$PANE_FIELDS"
  fi
  : > "$VERB_ERR"
  out="$(cd "$VERB_RUN_REPO" && PATH="${extra:+$extra:}$OBS_BIN:$PATH" \
    env STUB_DIR="$STUB_DIR" PANE_FIELDS="$PANE_FIELDS" \
        ORCH_LANE_HOST="$host" LANE_HOST_TOUCH_RC="$touch_rc" \
        LANE_STATE_GREP_FAIL="${VERB_GREP_FAIL:-}" LANE_HOST_TOUCH_LOG="$VERB_TOUCH_LOG" \
        ./scripts/lanes state "$item" 2>"$VERB_ERR")" || rc=$?
  # The first keyed line only, read from the file: a pipe into an early-closing
  # reader is what the shell rules forbid here.
  note="$(awk '/^lanes: /{ sub(/^lanes: /, ""); sub(/ .*/, ""); print; exit }' "$VERB_ERR")"
  word="$out"
  printf '%s rc=%s note=%s' "${word:-${note:-none}}" "$rc" "${note:-none}"
}

# ITEM|SCREEN|HOST|TOUCH RC|WANT
#
# The screen rows are the judge's, reached through the command line rather than
# through a function call, so the verb cannot quietly answer something else.
#
# The host rows are the probe's, and they are the whole of its contract: the
# state is the pane's either way, and the provider only ever adds a note. A
# non-zero `touch` is a probe that failed — schemas/lane-host.md gives the verb
# no "no such lane" reply — so exits 1 and 2 answer alike and neither says
# `gone`, which would send an overseer down the window-gone path onto an item
# whose remote session is still running. Exit 69 is lane-host refusing the
# probe at its per-home cap, which says nothing about the host and is noted as
# lane-host-busy. The `CC-1|idle|ssh` row is the
# inverse: a pane that answered leaves the provider unasked. The
# `kendex:` rows are the SESSION:WINDOW form a lane record carries, which
# selects the pane under that session and answers as the bare name does.
while IFS='|' read -r item screen host touch_rc want; do
  [[ -n "$item" ]] || continue
  assert_eq "$(verb_state "$item" "$screen" "$host" "$touch_rc")" "$want" \
    "lanes state: $item on a $screen pane, host $host, touch $touch_rc"
done <<'ROWS'
CC-1|idle|local|0|idle rc=0 note=none
CC-1|working|local|0|working rc=0 note=none
CC-1|walled|local|0|walled rc=0 note=none
CC-1|asking|local|0|asking rc=0 note=none
CC-404|none|local|0|unjudged rc=0 note=none
CC-404|none|local|1|unjudged rc=0 note=none
CC-404|none|ssh|0|unjudged rc=0 note=none
CC-404|none|ssh|1|unjudged rc=0 note=host-unreachable
CC-404|none|ssh|2|unjudged rc=0 note=host-unreachable
CC-404|none|ssh|69|unjudged rc=0 note=lane-host-busy
CC-1|idle|ssh|1|idle rc=0 note=none
kendex:CC-1|idle|local|0|idle rc=0 note=none
fleet:CC-1|idle|local|0|unjudged rc=0 note=none
kendex:CC-404|none|ssh|1|unjudged rc=0 note=host-unreachable
ROWS

# A window a running fleet record names as a Pi lane's answers from the rows
# its hook wrote in its mailbox, never from its pane: each row stages a screen
# that would answer otherwise. With no row the lane is unjudged, and a window
# no record names keeps the pane, the fallback the help names.
PI_VERB_ROOT="$TMP_ROOT/pi-verb-lane"
mkdir -p "$PI_VERB_ROOT/tmp/lane-mail/CC-1"
(cd "$VERB_REPO" && ./scripts/workflow-state init oversee >/dev/null \
  && ./scripts/workflow-state set oversee lanes "$(jq -nc --arg root "$PI_VERB_ROOT" \
    '[{item: "CC-1", window: "kendex:CC-1", harness: "pi", host: null, mail_root: $root, status: "running"}]')" >/dev/null)
PI_VERB_ROWS="$PI_VERB_ROOT/tmp/lane-mail/CC-1/session-rows.jsonl"
# ROWS|SCREEN|WANT, ROWS being the Pi lane's last row's event, or none
while IFS='|' read -r rows screen want; do
  [[ -n "$rows" ]] || continue
  rm -f -- "${PI_VERB_ROWS:?}"
  [[ "$rows" == none ]] || jq -nc --arg e "$rows" '{at: 1, event: $e, harness: "pi", stop_reason: "stop"}' > "$PI_VERB_ROWS"
  assert_eq "$(verb_state CC-1 "$screen" local 0)" "$want" \
    "lanes state: a Pi lane whose last row is $rows on a $screen pane"
done <<'ROWS'
Stop|working|idle rc=0 note=none
PreToolUse|idle|working rc=0 note=none
none|idle|unjudged rc=0 note=none
ROWS
assert_eq "$(verb_state CC-2 working local 0)" "working rc=0 note=none" \
  "lanes state: a window no running record names is read at its pane, the fallback"
# The verb's Pi control: rows read and never handed to the judge leave the
# pane to answer for a Pi lane.
jq -nc '{at: 1, event: "Stop", harness: "pi", stop_reason: "stop"}' > "$PI_VERB_ROWS"
ROWS_MUTANT_SCRIPTS="$(mutant_scripts verb-rows-mutant lanes)" || exit 1
ROWS_MUTANT_REPO="$(dirname "$ROWS_MUTANT_SCRIPTS")"
git -C "$ROWS_MUTANT_REPO" init -q
cp -R "$VERB_REPO/tmp" "$ROWS_MUTANT_REPO/tmp"
mutate_file "$ROWS_MUTANT_SCRIPTS/lanes" '"$LANE_PANE_SCREEN" "" "" "$STATE_ROWS"' '"$LANE_PANE_SCREEN" "" "" ""'
assert_eq "$(VERB_RUN_REPO="$ROWS_MUTANT_REPO" verb_state CC-1 working local 0)" "working rc=0 note=none" \
  "control: a verb that drops the rows reads a Pi lane's pane"
rm -f -- "${PI_VERB_ROWS:?}"
(cd "$VERB_REPO" && ./scripts/workflow-state set oversee lanes '[]' >/dev/null)

# A window a running fleet record names as a Copilot lane's is judged at its
# pane, and for a lane launched with allow-all the record of the newest
# session in its worktree, under the record's account or, for a record naming
# none, COPILOT_HOME's, is read beside it where a pane carries the window:
# allow_all_enabled false is noted as a stop cause, true as nothing, and a
# record that does not answer as the reason. A lane launched without it reads
# false as well, and is noted as nothing.
COP_VERB_WT="$TMP_ROOT/copilot-verb-lane"
COP_VERB_ACCOUNT="$TMP_ROOT/copilot-verb-account"
COP_VERB_SESSION=cop-verb-1
mkdir -p "$COP_VERB_WT" "$COP_VERB_ACCOUNT/session-state/$COP_VERB_SESSION"
printf 'id: %s\ncwd: %s\n' "$COP_VERB_SESSION" "$(cd "$COP_VERB_WT" && pwd -P)" \
  > "$COP_VERB_ACCOUNT/session-state/$COP_VERB_SESSION/workspace.yaml"
printf '{"type":"session.start"}\n' > "$COP_VERB_ACCOUNT/session-state/$COP_VERB_SESSION/events.jsonl"
# cop_verb_lane ACCOUNT [GRANT] — the fleet's one running record, a Copilot
# lane on ACCOUNT (null for none) in COP_VERB_WT, its launch's allow_all GRANT,
# true unless named.
cop_verb_lane() {
  (cd "$VERB_REPO" && ./scripts/workflow-state set oversee lanes "$(jq -nc --arg root "$COP_VERB_WT" --arg a "$1" --argjson g "${2:-true}" \
    '[{item: "CC-1", window: "kendex:CC-1", harness: "copilot", host: null, mail_root: $root,
       account: (if $a == "null" then null else $a end), status: "running", allow_all: $g}]')" >/dev/null)
}
# cop_verb_record ALLOW — the record copilot-statusline writes for the session
# now, or none at all.
cop_verb_record() {
  rm -rf -- "${COP_VERB_ACCOUNT:?}/lane-status"
  [[ "$1" == none ]] || jq -nc --arg s "$COP_VERB_SESSION" --argjson a "$1" '{session_id: $s, allow_all_enabled: $a}' \
    | COPILOT_HOME="$COP_VERB_ACCOUNT" "$SCRIPTS_DIR/copilot-statusline" >/dev/null
}
# ACCOUNT|GRANT|ALLOW|SCREEN|WANT, COPILOT_HOME naming the account for every row.
while IFS='|' read -r account grant allow screen want; do
  [[ -n "$account" ]] || continue
  cop_verb_lane "${account/ACCOUNT/$COP_VERB_ACCOUNT}" "$grant"
  cop_verb_record "$allow"
  assert_eq "$(COPILOT_HOME="$COP_VERB_ACCOUNT" verb_state CC-1 "$screen" local 0)" "$want" \
    "lanes state: a Copilot lane on account $account, launched with allow_all $grant, whose record says allow_all_enabled $allow, on a $screen pane"
done <<'ROWS'
ACCOUNT|true|false|asking|asking rc=0 note=stop-cause=allow-all-blocked-by-policy
ACCOUNT|true|true|asking|asking rc=0 note=none
ACCOUNT|true|none|idle|idle rc=0 note=session-record=missing
null|true|false|asking|asking rc=0 note=stop-cause=allow-all-blocked-by-policy
ACCOUNT|true|false|none|unjudged rc=0 note=none
ACCOUNT|false|false|asking|asking rc=0 note=none
ROWS
# The verb's Copilot control: a cause read and never printed leaves the
# policy stop out of the report.
cop_verb_lane "$COP_VERB_ACCOUNT"
cop_verb_record false
CAUSE_MUTANT_SCRIPTS="$(mutant_scripts verb-cause-mutant lanes)" || exit 1
CAUSE_MUTANT_REPO="$(dirname "$CAUSE_MUTANT_SCRIPTS")"
git -C "$CAUSE_MUTANT_REPO" init -q
cp -R "$VERB_REPO/tmp" "$CAUSE_MUTANT_REPO/tmp"
mutate_file "$CAUSE_MUTANT_SCRIPTS/lanes" '[[ -z "$COPILOT_SESSION_NOTE" ]] || message' '[[ -n "$COPILOT_SESSION_NOTE" ]] || message'
assert_eq "$(VERB_RUN_REPO="$CAUSE_MUTANT_REPO" verb_state CC-1 asking local 0)" "asking rc=0 note=none" \
  "control: a verb that drops the stop cause reports a policy-blocked Copilot lane as a plain dialog"
# The pane control: a record read for a window no pane here carries, which
# the verb then reports beside an unjudged lane.
mutate_file "$CAUSE_MUTANT_SCRIPTS/lanes" '[[ -n "$COPILOT_SESSION_NOTE" ]] || message' '[[ -z "$COPILOT_SESSION_NOTE" ]] || message'
mutate_file "$CAUSE_MUTANT_SCRIPTS/lanes" '[[ -z "$LANE_PANE_ID" ]] || { rec=' 'false || { rec='
assert_eq "$(VERB_RUN_REPO="$CAUSE_MUTANT_REPO" verb_state CC-1 none local 0)" "unjudged rc=0 note=stop-cause=allow-all-blocked-by-policy" \
  "control: a verb that reads the record with no pane here reports a cause beside an unjudged lane"
(cd "$VERB_REPO" && ./scripts/workflow-state set oversee lanes '[]' >/dev/null)

# The hosted probe names the item, which is the window part of a
# session-qualified name: the provider knows items and never tmux sessions.
# probed NAME [REPO] — the item the provider was asked about for NAME.
probed() {
  : > "$VERB_TOUCH_LOG"
  VERB_RUN_REPO="${2:-$VERB_REPO}" verb_state "$1" none ssh 1 >/dev/null
  cat "$VERB_TOUCH_LOG"
}
for name in kendex:CC-404 CC-404; do
  assert_eq "$(probed "$name")" "CC-404" "lanes state $name probes the provider with the bare item"
done

# The provider's own bytes reach the operator: a note naming only the key would
# leave the reason for the failed probe on the far side of the dispatcher.
verb_state CC-404 none ssh 1 >/dev/null
assert_eq "$(grep -cF -- "$PROBE_STDERR" "$VERB_ERR")" "1" \
  "the host-unreachable note forwards the provider's own message"

screen_for idle > "$STUB_DIR/pane-%3.txt"
printf 'kendex\tCC-1\t%%3\t100\tclaude\n' > "$PANE_FIELDS"
# The word alone on stdout, with nothing beside it. The help, oversee.md and the
# changelog all promise a caller can compare the whole line against `working`,
# and the rows above read the state off the end of the line, so only a raw
# comparison holds a second field out.
assert_eq "$(cd "$VERB_REPO" && PATH="$OBS_BIN:$PATH" \
  env STUB_DIR="$STUB_DIR" PANE_FIELDS="$PANE_FIELDS" ORCH_LANE_HOST=local \
      ./scripts/lanes state CC-1)" 'idle' \
  "lanes state prints the state word and nothing else"
assert_eq "$(cd "$VERB_REPO" && PATH="$OBS_BIN:$PATH" \
  env STUB_DIR="$STUB_DIR" PANE_FIELDS="$PANE_FIELDS" ORCH_LANE_HOST=local \
      ./scripts/lanes state CC-1 --json)" '{"item":"CC-1","state":"idle"}' \
  "lanes state --json names the item and the state"

# A scan that fails is not an answer here either: the verb refuses with its own
# stable key and a non-zero status, rather than printing the `idle` that pane
# plainly shows. Same failing grep as § states, on its own PATH entry so only
# this row sees it.
VERB_FAIL_BIN="$TMP_ROOT/verbfail"; mkdir -p "$VERB_FAIL_BIN"
cat > "$VERB_FAIL_BIN/grep" <<'EOF'
#!/usr/bin/env bash
[[ -z "${LANE_STATE_GREP_FAIL:-}" ]] || { printf 'E_GREP\n' >&2; exit 2; }
exec /usr/bin/grep "$@"
EOF
chmod +x "$VERB_FAIL_BIN/grep"
VERB_GREP_FAIL=1
assert_eq "$(verb_state CC-1 idle local 0 "$VERB_FAIL_BIN")" "lane-scan-failed rc=1 note=lane-scan-failed" \
  "lanes state refuses a failed scan rather than printing the idle the pane shows"
VERB_GREP_FAIL=""

# The key and the status, never the sentence under them: the first line is the
# refusal's contract and the English below it is free to be reworded.
no_item_out=""
no_item_rc=0
no_item_out="$(cd "$VERB_REPO" && PATH="$OBS_BIN:$PATH" ./scripts/lanes state 2>&1)" || no_item_rc=$?
assert_eq "$(head -1 <<<"$no_item_out") rc=$no_item_rc" \
  "lanes: missing-value arg1=state rc=1" \
  "lanes state with no item refuses before it reads a pane"

# The verb's one must-fail control: the probe handed the whole argument again
# asks the provider about an item named after a tmux session. The mutant's
# repository carries the same provider stub the fixture's does.
PROBE_MUTANT_SCRIPTS="$(mutant_scripts verb-probe-mutant lanes)" || exit 1
PROBE_MUTANT_REPO="$(dirname "$PROBE_MUTANT_SCRIPTS")"
rm -- "${PROBE_MUTANT_SCRIPTS:?}/lane-host"
cp "$VERB_REPO/scripts/lane-host" "$PROBE_MUTANT_SCRIPTS/lane-host"
git -C "$PROBE_MUTANT_REPO" init -q
mutate_file "$PROBE_MUTANT_SCRIPTS/lanes" 'touch --item "${LANE_ARG#*:}"' 'touch --item "$LANE_ARG"'
assert_eq "$(probed kendex:CC-404 "$PROBE_MUTANT_REPO")" "kendex:CC-404" \
  "control: probing with the whole argument names the session to the provider"
# The probe's busy arm, the second branch on its status: without it a probe
# lane-host refused at its cap is noted as a host out of reach.
BUSY_MUTANT_SCRIPTS="$(mutant_scripts verb-busy-mutant lanes)" || exit 1
BUSY_MUTANT_REPO="$(dirname "$BUSY_MUTANT_SCRIPTS")"
rm -- "${BUSY_MUTANT_SCRIPTS:?}/lane-host"
cp "$VERB_REPO/scripts/lane-host" "$BUSY_MUTANT_SCRIPTS/lane-host"
git -C "$BUSY_MUTANT_REPO" init -q
mutate_file "$BUSY_MUTANT_SCRIPTS/lanes" 'if [[ "$probe_rc" -eq "$LANE_HOST_BUSY_EXIT" ]]; then' 'if false; then'
assert_eq "$(VERB_RUN_REPO="$BUSY_MUTANT_REPO" verb_state CC-404 none ssh 69)" "unjudged rc=0 note=host-unreachable" \
  "control: without the busy arm a refused probe is noted host-unreachable"

echo "=== lane-state § control: the judge that reads the process and not the pane ==="

# The must-fail inverse the change exists to close. Before this library the wake
# read the harness process and nothing else, so a lane with no /proc entry of
# its own — every hosted lane, whose harness runs on another machine — came back
# `unjudged` however plainly its pane said idle. The mutant restores exactly
# that: the pane rungs cut out, the session read left standing.
MUTANT_LIB="$TMP_ROOT/mutant-lane-state.sh"
# The cut runs from the slice to the marker rung INCLUSIVE, so the mutant keeps
# only the trailing process read. Ending it at the session case instead would
# leave the marker rung behind reading a slice that is no longer computed, and
# the mutant would answer `unjudged` off an unbound variable rather than off the
# judge it is meant to be.
awk '
  /^  _ls_slice="\$\(pane_below_last_turn/ { cut = 1 }
  !cut
  /^  if grep -Eq -- "\$PANE_MARKER_RE" <<<"\$_ls_slice"/ { cut = 0 }
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

# The Copilot composer's signature, the rule under its marker line, cut from
# the slice: the marker line then reads as a turn already taken, the slice
# below it holds no marker, and neither the judge nor the launcher's premise
# sees an idle Copilot lane.
FRAMED_MUTANT="$TMP_ROOT/mutant-framed.sh"
FRAMED_LINE='      framed = (last > 0 && last < NR && line[last + 1] ~ rule)'
assert_eq "$(grep -c -x -F "$FRAMED_LINE" "$SCRIPTS_DIR/lib/lane-state.sh")" 1 \
  "control: the framed line is in the library once"
awk -v l="$FRAMED_LINE" '$0 == l { print "      framed = 0"; next } { print }' "$SCRIPTS_DIR/lib/lane-state.sh" > "$FRAMED_MUTANT"
framed_state="$(
  source "$FRAMED_MUTANT"
  answer=""
  lane_state answer listed node 100 "$(screen_for copilot_idle)" ""
  up=no
  ! pane_harness_up "$(screen_for copilot_idle)" || up=yes
  printf '%s up=%s' "$answer" "$up"
)"
assert_eq "$framed_state" "unjudged up=no" \
  "control: without the framed signature an idle copilot lane is unjudged and not up"

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
