#!/usr/bin/env bash
# Regression tests for the pane side of orch/scripts/oversee-watch: what the
# watch reads off a lane's tmux window. Spent-account banners and their reset
# clauses are oversee_watch_usage_limit.sh; the GitHub side — pr-watch,
# merged, the heartbeat and the process-wide failures — is oversee_watch.sh.
# All build their sandbox from lib/oversee-watch-harness.sh.
#
# Covered here: window absence versus probe failure; shell-exit debounce; live
# versus answered prompts for both harnesses; idle-return debounce; scrollback
# boundaries; and one-capture classification.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

# shellcheck source=lib/oversee-watch-harness.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/oversee-watch-harness.sh"

echo "=== oversee-watch lanes ==="

# --- 3. window-gone --------------------------------------------------------
new_case window_gone
printf 'gh-1\n' > "$STUB_DIR/windows.txt"
err="$TMP_ROOT/e3"
out="$(run_watch -- gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "0" "window-gone exits 0" "$err"
assert_eq "$out" "EVENT window-gone gh-2" "missing lane window is the event" "$err"

# --- 3b. lane-exited: window alive, harness gone ----------------------------
# open-terminal runs the harness inside a shell, so a session that hit its
# limit or crashed leaves a live window whose pane matches no question prompt.
new_case lane_exited
printf 'bash\n' > "$STUB_DIR/cmd-gh-2.txt"
{
  printf '⏺ I will keep going.\n\n'
  printf "You've hit your session limit · resets 21:00\n"
  printf '$ \n'
} > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/e3b"
out="$(run_watch -- gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "0" "lane-exited exits 0" "$err"
assert_eq "$(head -1 <<<"$out")" "EVENT lane-exited gh-2" "a bare shell on two consecutive passes is the event" "$err"
assert_contains "$out" "session limit" "the pane tail follows, carrying the exit reason" "$err"
assert_not_contains "$out" "EVENT window-gone" "a live window is not reported gone" "$err"
assert_not_contains "$out" "EVENT usage-limit" "a limit banner under an EXITED harness is lane-exited, not usage-limit" "$err"
assert_not_contains "$out" "EVENT idle-after-return" "a bare shell is never idle-after-return" "$err"

# one pass is not enough: a live harness can hold a shell in the foreground
# for a single poll, and relaunching a working lane costs more than a wait
new_case lane_exited_debounce
printf 'bash\n' > "$STUB_DIR/cmd-gh-2.txt"
err="$TMP_ROOT/e3b2"
out="$(run_watch -- --max-loops 1 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT heartbeat loops=1 interval=0s since=none" "one pass of shell is not the event" "$err"
assert_not_contains "$out" "EVENT lane-exited" "a single shell reading never fires" "$err"

# a shell on one pass followed by a live command is a transient, not an exit
new_case lane_exited_transient
printf 'bash\n' > "$STUB_DIR/cmd-gh-2.1.txt"
err="$TMP_ROOT/e3b3"
out="$(run_watch -- gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT heartbeat loops=2 interval=0s since=none" "shell then live is not an exit" "$err"
assert_not_contains "$out" "EVENT lane-exited" "a non-consecutive shell reading never fires" "$err"

# a login shell reports itself as -bash
new_case lane_exited_login_shell
printf -- '-bash\n' > "$STUB_DIR/cmd-gh-2.txt"
err="$TMP_ROOT/e3b4"
out="$(run_watch -- gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT lane-exited gh-2" "a login shell (-bash) counts as a bare shell" "$err"

# A lane resumed by typing the wrapper at an interactive prompt keeps the
# shell as the pane process with the harness as its child, so the pane reads
# `fish` for the lane's whole life. The child is what tells it from an exit.
new_case lane_shell_with_child
printf 'fish\n' > "$STUB_DIR/cmd-gh-2.txt"
printf '2747883\n' > "$STUB_DIR/kids-9002.txt"
err="$TMP_ROOT/e3b5"
out="$(run_watch -- gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT heartbeat loops=2 interval=0s since=none" \
  "a shell pane with a child process is a live lane, not an exit" "$err"
assert_not_contains "$out" "EVENT lane-exited" "a wrapped lane is never dropped from the watch" "$err"
assert_eq "$(grep -c . "$STUB_DIR/pgrep.calls")" "2" \
  "one probe per bare-shell lane per pass (2 passes, 1 shell lane)" "$err"
assert_not_contains "$(cat "$STUB_DIR/pgrep.calls")" "9001" \
  "a lane whose foreground IS the harness is never probed" "$err"

# A probe that cannot run at all is not an answer. `ps --ppid` is procps-only
# and BSD ps rejects it with the same status it uses for no match, which read
# every pane as childless; whatever the cause, an unjudgeable lane stays
# watched rather than being retired on a failure.
new_case lane_probe_unusable
printf 'fish\n' > "$STUB_DIR/cmd-gh-2.txt"
: > "$STUB_DIR/probe-fail-9002"
err="$TMP_ROOT/e3b7"
out="$(run_watch -- gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT heartbeat loops=2 interval=0s since=none" \
  "a lane whose child probe cannot run is never reported exited" "$err"
assert_not_contains "$out" "EVENT lane-exited" "a failed probe never manufactures an exit" "$err"
assert_contains "$(cat "$err")" "could not list the children of the pane behind 'gh-2'" \
  "the unusable probe is named on stderr" "$err"
assert_contains "$(cat "$err")" "pgrep -P exited 2" \
  "the note carries the status that actually occurred" "$err"
assert_eq "$(grep -c 'could not list the children' "$err")" "1" \
  "the probe note is printed once per run, not per pass" "$err"

# ...and the status it names is the one that occurred, not a fixed one: pgrep
# reports 2 for a syntax error and 3 for a fatal one, and a pgrep missing from
# PATH leaves 127, so a note hardcoding any of them misdirects the overseer.
new_case lane_probe_unusable_fatal
printf 'fish\n' > "$STUB_DIR/cmd-gh-2.txt"
printf '3' > "$STUB_DIR/probe-fail-9002"
err="$TMP_ROOT/e3ba"
out="$(run_watch -- gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_not_contains "$out" "EVENT lane-exited" "a fatal probe never manufactures an exit" "$err"
assert_contains "$(cat "$err")" "pgrep -P exited 3" \
  "the note names the fatal status, not the syntax-error one" "$err"
assert_not_contains "$(cat "$err")" "pgrep -P exited 2" \
  "the note never reports a status that did not occur" "$err"

# The must-fail control for the case above: the same bare shell with nothing
# under it — a lane typed at a prompt whose harness has quit
new_case lane_exited_fish_prompt
printf 'fish\n' > "$STUB_DIR/cmd-gh-2.txt"
printf 'method@box ~/dev/kendex (main)>\n' > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/e3b6"
out="$(run_watch -- gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT lane-exited gh-2" \
  "a bare fish prompt with no child is the event on the second pass" "$err"

# a live harness under the same conditions is no event
new_case lane_live
printf 'codex\n' > "$STUB_DIR/cmd-gh-2.txt"
err="$TMP_ROOT/e3c"
out="$(run_watch -- gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT heartbeat loops=2 interval=0s since=none" "a live pane command is not an exit" "$err"
assert_not_contains "$out" "EVENT lane-exited" "a live lane never fires lane-exited" "$err"

# an exited lane whose pane holds only blank lines still reports the event:
# the pane tail is a grep miss there, which pipefail would turn into an abort
new_case lane_exited_blank_pane
printf 'zsh\n' > "$STUB_DIR/cmd-gh-2.txt"
printf '   \n\n\t\n' > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/e3e"
out="$(run_watch -- gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "0" "an exited lane with a blank pane still exits 0" "$err"
assert_eq "$(head -1 <<<"$out")" "EVENT lane-exited gh-2" "a blank pane does not swallow the event" "$err"

# The liveness reply has one shape, `<pid> <command>`, and anything else is a
# tmux that did not answer for this pane: a pid with no command behind it, or
# a first field that is not a pid at all. Neither may be split into a pid and
# an empty command and then judged.
new_case lane_obs_missing_command
printf '9002\n' > "$STUB_DIR/obs-gh-2.txt"
err="$TMP_ROOT/e3b8"
out="$(run_watch -- gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "2" "a liveness reply with no command exits 2" "$err"
assert_eq "$out" "" "a malformed liveness reply emits no window-gone event" "$err"
assert_contains "$(cat "$err")" "malformed result for 'gh-2': 9002" \
  "the malformed liveness result is preserved" "$err"

new_case lane_obs_non_numeric_pid
printf 'fish fish\n' > "$STUB_DIR/obs-gh-2.txt"
err="$TMP_ROOT/e3b9"
out="$(run_watch -- gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "2" "a liveness reply with a non-pid exits 2" "$err"
assert_eq "$out" "" "a non-pid liveness reply emits no window-gone event" "$err"
assert_contains "$(cat "$err")" "malformed result for 'gh-2': fish fish" \
  "the non-pid liveness result is preserved" "$err"

# An unreadable pane command is a fail-closed probe error, never window-gone.
new_case lane_cmd_unreadable
rm -f "$STUB_DIR/cmd-gh-2.txt"
err="$TMP_ROOT/e3d"
out="$(run_watch -- gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "2" "an unreadable pane command exits 2" "$err"
assert_eq "$out" "" "an unreadable pane command emits no window-gone event" "$err"
assert_contains "$(cat "$err")" "pane command probe failed for 'gh-2': can't find window: gh-2" \
  "the pane command failure preserves tmux stderr" "$err"

# --- 4. lane-asking --------------------------------------------------------
new_case question
{
  printf '⏺ I found two ways to do this.\n\n'
  printf 'Do you want to proceed?\n'
  printf '   ❯ 1. Yes\n     2. No\n'
} > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/e4"
out="$(run_watch -- gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "0" "lane-asking exits 0" "$err"
assert_eq "$(head -1 <<<"$out")" "EVENT lane-asking gh-2" "lane with a question prompt is the event" "$err"
assert_contains "$out" "   ❯ 1. Yes" "pane tail follows the event line" "$err"
assert_not_contains "$out" "gh-1" "a working lane is not reported" "$err"
assert_not_contains "$out" "EVENT idle-after-return" \
  "a selection prompt is a question, never an idle prompt" "$err"

# The question check reads the same liveness answer, so a lane wrapped in a
# shell still gets its prompt answered
new_case question_wrapped_shell
printf 'fish\n' > "$STUB_DIR/cmd-gh-2.txt"
printf '2747883\n' > "$STUB_DIR/kids-9002.txt"
printf 'Do you want to proceed?\n   ❯ 1. Yes\n     2. No\n' > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/e4a3"
out="$(run_watch -- --max-loops 1 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT lane-asking gh-2" \
  "a wrapped lane's question is still the event" "$err"

# Codex on a dialog. It marks the row it has selected with `›`, not `❯`, and
# words its key hints its own way, so nothing Claude Code draws reaches these
# two screens: before KEN-863 both fell through every predicate and the pass
# said nothing about the lane. The marker is the whole signature — these two
# cases are what proves a Codex enter hint would be redundant.
new_case question_codex_dialog_trust
printf 'codex\n' > "$STUB_DIR/cmd-gh-2.txt"
cat "$CODEX_PANES/codex-dialog-trust.txt" > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/e4c1"
out="$(run_watch -- --max-loops 1 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT lane-asking gh-2" \
  "a codex directory-trust dialog is a question" "$err"
assert_contains "$out" "Do you trust the contents of this directory?" \
  "the pane tail carries what the lane is being asked" "$err"

new_case question_codex_dialog_model
printf 'codex\n' > "$STUB_DIR/cmd-gh-2.txt"
cat "$CODEX_PANES/codex-dialog-model.txt" > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/e4c2"
out="$(run_watch -- --max-loops 1 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT lane-asking gh-2" \
  "a codex model picker is a question" "$err"
assert_contains "$out" "Select Model and Effort" \
  "the pane tail carries the choice on offer" "$err"

# A tmux window name carries any character, so two lanes can differ only
# outside a filename-safe set. Their pane snapshots must stay separate or each
# lane is classified on the other's screen.
new_case pane_snapshot_per_lane
printf 'a+b\na:b\n' > "$STUB_DIR/windows.txt"
printf 'claude\n' > "$STUB_DIR/cmd-a+b.txt"
printf 'claude\n' > "$STUB_DIR/cmd-a:b.txt"
printf 'Do you want to proceed?\n   ❯ 1. Yes\n     2. No\n' > "$STUB_DIR/pane-a+b.txt"
printf '⏺ working on it\n' > "$STUB_DIR/pane-a:b.txt"
err="$TMP_ROOT/e4a2"
out="$(run_watch -- --max-loops 1 'a+b' 'a:b' 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "0" "colliding lane names exit 0" "$err"
assert_eq "$(head -1 <<<"$out")" "EVENT lane-asking a+b" \
  "lanes whose names flatten to one slug keep separate pane snapshots" "$err"

# A dialog the lane already answered stays on the screen. Only the slice below
# the last user turn is a question still waiting: read off the whole pane, an
# answered list re-fires every pass and masks the event the lane is really at.
new_case question_answered_dialog_above_turn
{
  printf '⏺ I found two ways to do this.\n'
  printf 'Do you want to proceed?\n'
  printf '   ❯ 1. Yes\n     2. No\n'
  printf '❯ go with the first one\n'
  printf '⏺ Done: the PR is merged and the worktree is gone.\n'
  printf '\xe2\x9d\xaf\xc2\xa0\n'
  printf '  bypass permissions on\n'
} > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/e4a4"
out="$(run_watch -- gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "0" "an answered dialog exits 0" "$err"
assert_not_contains "$out" "EVENT lane-asking" \
  "a selection list above the last user turn is answered, not waiting" "$err"
assert_eq "$(head -1 <<<"$out")" "EVENT idle-after-return gh-2" \
  "the lane reaches the idle event the answered list was masking" "$err"

# ...and its must-fail control: the same list BELOW the last user turn is a
# question nobody has answered, so the slice can never pass by muting the check
new_case question_live_dialog_below_turn
{
  printf '❯ go ahead and refactor it\n'
  printf '⏺ I found two ways to do this.\n'
  printf 'Do you want to proceed?\n'
  printf '   ❯ 1. Yes\n     2. No\n'
} > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/e4a5"
out="$(run_watch -- --max-loops 1 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT lane-asking gh-2" \
  "a selection list below the last user turn is still the event" "$err"
assert_contains "$out" "   ❯ 1. Yes" "the pane tail follows the event line" "$err"

# --- 4b. idle-after-return: the round is over and nobody is driving ---------
new_case idle_after_return
{
  printf '⏺ Done: the PR is merged and the worktree is gone.\n'
  printf '\xe2\x9d\xaf\xc2\xa0\n'
  printf '  bypass permissions on\n'
} > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/e4b"
out="$(run_watch -- gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "0" "idle-after-return exits 0" "$err"
assert_eq "$(head -1 <<<"$out")" "EVENT idle-after-return gh-2" \
  "an idle prompt on two consecutive passes is the event" "$err"
assert_contains "$out" "the PR is merged" "the pane tail follows the idle event" "$err"

# Codex's ready prompt reads differently and counts the same. The fixture is
# the state this event is named for: a lane that finished its turn and is
# waiting. Codex draws no submit hint at its composer — only the marker and
# either the placeholder or an unsent draft — so the marker carries idleness,
# and the hint this case used to assert on renders on none of these screens.
new_case idle_after_return_codex
printf 'codex\n' > "$STUB_DIR/cmd-gh-2.txt"
cat "$CODEX_PANES/codex-idle-after-turn.txt" > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/e4b2"
out="$(run_watch -- gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT idle-after-return gh-2" \
  "a codex lane that finished its turn is idle too" "$err"
assert_not_contains "$(cat "$STUB_DIR/pane-gh-2.txt")" "to submit message" \
  "the real composer carries no submit hint, so the marker alone decides" "$err"

# ...a composer the lane never took a turn at, and one holding an unsent
# draft, which has the same shape as a turn already taken
new_case idle_after_return_codex_composer
printf 'codex\n' > "$STUB_DIR/cmd-gh-2.txt"
cat "$CODEX_PANES/codex-composer-idle.txt" > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/e4b2a"
out="$(run_watch -- gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT idle-after-return gh-2" \
  "a codex lane at a fresh composer is idle too" "$err"

new_case idle_after_return_codex_draft
printf 'codex\n' > "$STUB_DIR/cmd-gh-2.txt"
cat "$CODEX_PANES/codex-composer-draft.txt" > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/e4b2b"
out="$(run_watch -- gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT idle-after-return gh-2" \
  "a codex composer holding a draft is idle too" "$err"

# The gate that makes the Codex marker safe to read as an idle prompt. Codex
# draws its composer BELOW the working indicator, so the marker is on screen
# for the whole turn and WORKING_RE alone keeps a busy lane out. It matches
# through `to interrupt`, which is what `• Working (8s • esc to interrupt)`
# carries; refresh this capture against a Codex that words it differently and
# this case goes red rather than waking every busy lane.
new_case idle_after_return_codex_working
printf 'codex\n' > "$STUB_DIR/cmd-gh-2.txt"
cat "$CODEX_PANES/codex-working.txt" > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/e4b2c"
out="$(run_watch -- gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_contains "$(cat "$STUB_DIR/pane-gh-2.txt")" "› Ask Codex to do anything" \
  "a busy codex screen draws its composer, so the marker cannot decide alone" "$err"
assert_contains "$(cat "$STUB_DIR/pane-gh-2.txt")" "esc to interrupt" \
  "the interrupt hint is the alternative carrying the gate, not the token counter" "$err"
assert_eq "$(head -1 <<<"$out")" "EVENT heartbeat loops=2 interval=0s since=none" \
  "a working codex lane is not idle, its marker notwithstanding" "$err"
assert_not_contains "$out" "EVENT idle-after-return" \
  "WORKING_RE is what keeps the codex marker from waking a busy lane" "$err"

# The idle check reads the same liveness answer too
new_case idle_after_return_wrapped_shell
printf 'fish\n' > "$STUB_DIR/cmd-gh-2.txt"
printf '2747883\n' > "$STUB_DIR/kids-9002.txt"
printf '⏺ Done: the PR is merged.\n\xe2\x9d\xaf\xc2\xa0\n' > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/e4b7"
out="$(run_watch -- gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT idle-after-return gh-2" \
  "a wrapped lane at its composer is idle, not exited" "$err"

# One pass is not enough: the screen between two tool calls reads the same
new_case idle_after_return_debounce
printf '⏺ Done.\n\xe2\x9d\xaf\xc2\xa0\n' > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/e4b3"
out="$(run_watch -- --max-loops 1 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT heartbeat loops=1 interval=0s since=none" \
  "one idle pass is not the event" "$err"
assert_not_contains "$out" "EVENT idle-after-return" "a single idle reading never fires" "$err"

# The must-fail control: a WORKING lane shows the same composer prompt, so the
# prompt alone can never decide idleness
new_case idle_after_return_working
{
  printf '✶ Germinating… (29m 16s \xc2\xb7 ↓ 58.7k tokens)\n'
  printf '\xe2\x9d\xaf\xc2\xa0\n'
} > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/e4b4"
out="$(run_watch -- gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT heartbeat loops=2 interval=0s since=none" \
  "a working lane showing its composer prompt is not idle" "$err"
assert_not_contains "$out" "EVENT idle-after-return" "the token counter keeps a busy lane out" "$err"

# The other two working shapes: the interrupt hint and a foreground shell
new_case idle_after_return_working_hints
printf '⏺ Thinking (esc to interrupt)\n\xe2\x9d\xaf\xc2\xa0\n' > "$STUB_DIR/pane-gh-1.txt"
printf '⎿  (ctrl+b ctrl+b (twice) to run in background)\n\xe2\x9d\xaf\xc2\xa0\n' > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/e4b5"
out="$(run_watch -- gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT heartbeat loops=2 interval=0s since=none" \
  "the interrupt hint and the background-shell hint both mean busy" "$err"
assert_not_contains "$out" "EVENT idle-after-return" "neither working hint reads as idle" "$err"

# Idle then working is a lane that picked itself back up, not a return
new_case idle_after_return_transient
printf '⏺ Done.\n\xe2\x9d\xaf\xc2\xa0\n' > "$STUB_DIR/pane-gh-2.1.txt"
printf '✶ Germinating… (2m 4s \xc2\xb7 ↓ 5.0k tokens)\n\xe2\x9d\xaf\xc2\xa0\n' > "$STUB_DIR/pane-gh-2.2.txt"
err="$TMP_ROOT/e4b6"
out="$(run_watch -- gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT heartbeat loops=2 interval=0s since=none" \
  "an idle pass followed by a working one is not the event" "$err"
assert_not_contains "$out" "EVENT idle-after-return" "a non-consecutive idle reading never fires" "$err"

# Scrollback never goes away, so a working indicator the lane has since taken
# a turn past would suppress this event for good — the debounce cannot help,
# the line is not transient. Only the slice below the last user turn is work
# in flight now.
new_case idle_after_return_working_above_turn
{
  printf '⏺ Thinking (esc to interrupt)\n'
  printf '❯ actually stop there and write it up\n'
  printf '⏺ Done: the PR is merged and the worktree is gone.\n'
  printf '\xe2\x9d\xaf\xc2\xa0\n'
  printf '  bypass permissions on\n'
} > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/e4b8"
out="$(run_watch -- gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "0" "an interrupt hint in scrollback exits 0" "$err"
assert_eq "$(head -1 <<<"$out")" "EVENT idle-after-return gh-2" \
  "an interrupt hint above the last user turn is scrollback, not work in flight" "$err"

# ...and its must-fail control: the same hint BELOW the last user turn is a
# lane really working, so the slice can never pass by muting the check
new_case idle_after_return_working_below_turn
{
  printf '❯ go ahead and refactor it\n'
  printf '⏺ Thinking (esc to interrupt)\n'
  printf '\xe2\x9d\xaf\xc2\xa0\n'
} > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/e4b9"
out="$(run_watch -- gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT heartbeat loops=2 interval=0s since=none" \
  "an interrupt hint below the last user turn still means busy" "$err"
assert_not_contains "$out" "EVENT idle-after-return" "the slice does not mute the working check" "$err"

# The prompt half of the same rule: a submitted user turn opens with the same
# marker the composer does, so read off the whole pane a lane that is nowhere
# near its composer satisfies the idle prompt off scrollback alone.
new_case idle_after_return_prompt_above_turn
{
  printf '❯ run the suite\n'
  printf '⏺ Bash(cargo test)\n'
  printf '  ⎿ Compiling kendex v5.0.0\n'
} > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/e4b10"
out="$(run_watch -- gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT heartbeat loops=2 interval=0s since=none" \
  "a scrollback user turn is not the composer the lane is sitting at" "$err"
assert_not_contains "$out" "EVENT idle-after-return" "a marker above the last user turn never reads as idle" "$err"

# A pane keeps its last screen after the harness exits, so a stale prompt
# under a bare shell is not a question anyone can answer — and firing it every
# pass would starve the lane-exited that the second pass earns.
new_case question_bare_shell
printf 'bash\n' > "$STUB_DIR/cmd-gh-2.txt"
printf 'Do you want to proceed?\n   ❯ 1. Yes\n     2. No\n' > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/e4c"
out="$(run_watch -- --max-loops 1 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT heartbeat loops=1 interval=0s since=none" \
  "a stale prompt under an exited harness is not a question" "$err"
assert_not_contains "$out" "EVENT lane-asking" "an exited lane never fires lane-asking" "$err"
# ...and the second pass reports it as what it is
err="$TMP_ROOT/e4c2"
out="$(run_watch -- gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT lane-exited gh-2" \
  "the exited lane is reported as exited rather than starved by its stale prompt" "$err"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
