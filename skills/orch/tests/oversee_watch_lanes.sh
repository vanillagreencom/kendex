#!/usr/bin/env bash
# Regression tests for the pane side of orch/scripts/oversee-watch: what the
# watch reads off a lane's tmux window. The GitHub side — pr-watch, merged,
# the heartbeat and the process-wide failures — is oversee_watch.sh; both
# build their sandbox from lib/oversee-watch-harness.sh.
#
# Covered here:
#   3.  a listed lane window that no longer exists
#   3b. a live window whose pane holds a bare shell with no child process on
#       two consecutive passes — the harness exited (pane tail follows); one
#       pass alone, and a shell followed by a live command, are not events; a
#       login shell (-bash) counts; a shell WITH a child is a live lane (the
#       wrapper typed at a prompt) and costs one ps per pass; a live pane
#       command is not an event and never reaches ps; an unreadable pane
#       command is window-gone
#   3c. usage-limit: a limit banner under a still-running harness fires on
#       one pass, for either harness's wording, under a wrapped shell, ahead
#       of a question on the same screen, and names the config dir a live
#       lane claim maps the window to; a pruned claim names none; a healthy
#       pane never fires; a banner under an exited harness is lane-exited
#       instead; and a banner above a later user turn is scrollback, while
#       one below that turn still fires
#   4.  a lane pane showing a question prompt (pane tail follows), under a
#       wrapped shell too
#   4b. idle-after-return: a harness at its composer with nothing in flight
#       on two consecutive passes (either harness's prompt, and under a
#       wrapped shell); one pass alone, a working indicator alongside the
#       prompt, and an idle pass followed by a working one are not events
set -euo pipefail

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
assert_eq "$(grep -c . "$STUB_DIR/ps.calls")" "2" \
  "one ps per bare-shell lane per pass (2 passes, 1 shell lane)" "$err"
assert_not_contains "$(cat "$STUB_DIR/ps.calls")" "9001" \
  "a lane whose foreground IS the harness is never handed to ps" "$err"

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

# an unreadable pane command is window-gone, never a silent skip
new_case lane_cmd_unreadable
rm -f "$STUB_DIR/cmd-gh-2.txt"
err="$TMP_ROOT/e3d"
out="$(run_watch -- gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT window-gone gh-2" "an unreadable pane command is window-gone" "$err"

# --- 3c. usage-limit: the harness is alive, the account is spent ------------
new_case usage_limit
{
  printf '⏺ Working through the queue.\n'
  printf "You've hit your usage limit \xc2\xb7 resets 21:00\n"
  printf 'Run /usage-credits to raise it\n'
  printf '❯ \n'
} > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/e3f"
out="$(run_watch -- --max-loops 1 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "0" "usage-limit exits 0" "$err"
assert_eq "$(head -1 <<<"$out")" "EVENT usage-limit gh-2" \
  "a limit banner under a live harness is the event on ONE pass" "$err"
assert_contains "$out" "usage limit" "the pane tail follows the usage-limit event" "$err"

# Codex words it its own way; one regex covers both harnesses
new_case usage_limit_codex
printf 'codex\n' > "$STUB_DIR/cmd-gh-2.txt"
printf 'Usage limit reached. Increase your limits to continue.\n' > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/e3f2"
out="$(run_watch -- --max-loops 1 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT usage-limit gh-2" "the codex limit banner fires too" "$err"

# A spent account outranks a prompt left on the same screen
new_case usage_limit_before_question
{
  printf "You've hit your session limit \xc2\xb7 resets 21:00\n"
  printf 'Do you want to proceed?\n❯ 1. Yes\n  2. No\n'
} > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/e3g"
out="$(run_watch -- --max-loops 1 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT usage-limit gh-2" \
  "a limit banner above a stale prompt is usage-limit, not question" "$err"
assert_not_contains "$out" "EVENT question" "question never preempts a spent account" "$err"

# The banner and the prompt are read on the same liveness answer, so a lane
# wrapped in a shell still gets its banner seen
new_case usage_limit_wrapped_shell
printf 'fish\n' > "$STUB_DIR/cmd-gh-2.txt"
printf '2747883\n' > "$STUB_DIR/kids-9002.txt"
printf "You've hit your weekly limit \xc2\xb7 resets Sunday\n" > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/e3f3"
out="$(run_watch -- --max-loops 1 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT usage-limit gh-2" \
  "a wrapped lane's limit banner is still the event" "$err"

# An account that has since reset leaves its old banner on the visible screen.
# A user turn below it says the harness took another turn, so the banner is
# scrollback and the lane needs nothing.
new_case usage_limit_stale_banner
{
  printf '⏺ Working through the queue.\n'
  printf "You've hit your usage limit \xc2\xb7 resets 21:00\n"
  printf '❯ pick the round back up\n'
  printf '⏺ Teammate @dev-ken832-r3 finished\n'
  printf '❯ \n'
} > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/e3f4"
out="$(run_watch -- --max-loops 1 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT heartbeat loops=1 interval=0s since=none" \
  "a banner the lane has since worked past is not the event" "$err"
assert_not_contains "$out" "EVENT usage-limit" \
  "a stale banner above a later user turn never fires" "$err"

# The must-fail control for the case above: the same screen with the banner
# BELOW the turn — the account is spent right now
new_case usage_limit_after_turn
{
  printf '❯ pick the round back up\n'
  printf '⏺ Working through the queue.\n'
  printf "You've hit your usage limit \xc2\xb7 resets 21:00\n"
  printf '❯ \n'
} > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/e3f5"
out="$(run_watch -- --max-loops 1 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT usage-limit gh-2" \
  "a banner below the last user turn is the event" "$err"

# The must-fail control: a lane with no banner at all
new_case usage_limit_healthy
printf '⏺ All green, nothing blocking.\n❯ \n' > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/e3h"
out="$(run_watch -- --max-loops 1 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT heartbeat loops=1 interval=0s since=none" \
  "a lane with no limit banner reaches the heartbeat" "$err"
assert_not_contains "$out" "EVENT usage-limit" "a healthy lane never fires usage-limit" "$err"

# The account is the actionable part: a live claim maps the window to it
new_case usage_limit_claim
printf '900 %%3\n' > "$STUB_DIR/panes.txt"
printf '900 %%3\n' > "$STUB_DIR/pane-key-gh-2.txt"
mkdir -p "$STATE_DIR/claims"
# Read first by glob order, so anything matching on the window NAME alone
# would answer with one of these instead of the pane actually captured: one
# claim from another live server, one from THIS server on another pane —
# window names repeat across sessions as well as across servers.
printf '%s\t%%3\t/home/me/.otherclaude\tgh-2\t2026-08-16T00:00:00Z\n' "$$" > "$STATE_DIR/claims/a.claim"
printf '900\t%%9\t/home/me/.thirdclaude\tgh-2\t2026-08-16T00:00:00Z\n' > "$STATE_DIR/claims/b.claim"
printf '900\t%%3\t/home/me/.eclaude\tgh-2\t2026-08-16T00:00:00Z\n' > "$STATE_DIR/claims/c.claim"
printf "You've hit your weekly limit\n" > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/e3i"
out="$(run_watch -- --max-loops 1 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT usage-limit gh-2 /home/me/.eclaude" \
  "the event names the config dir the lane was claimed on" "$err"
assert_not_contains "$out" "otherclaude" \
  "a same-named window on another tmux server never answers for this lane" "$err"
assert_not_contains "$out" "thirdclaude" \
  "a same-named window on another pane of this server never answers either" "$err"

# ... and a claim whose pane is gone is pruned rather than reported
new_case usage_limit_claim_stale
printf '900 %%9\n' > "$STUB_DIR/panes.txt"
printf '900 %%3\n' > "$STUB_DIR/pane-key-gh-2.txt"
mkdir -p "$STATE_DIR/claims"
printf '900\t%%3\t/home/me/.eclaude\tgh-2\t2026-08-16T00:00:00Z\n' > "$STATE_DIR/claims/a.claim"
printf "You've hit your weekly limit\n" > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/e3j"
out="$(run_watch -- --max-loops 1 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT usage-limit gh-2" \
  "a claim whose pane is gone names no account" "$err"
assert_eq "$(ls -1 "$STATE_DIR/claims" | wc -l | tr -d '[:space:]')" "0" \
  "a dead claim is pruned on read, not left to accumulate" "$err"

# --- 4. question -----------------------------------------------------------
new_case question
{
  printf '⏺ I found two ways to do this.\n\n'
  printf 'Do you want to proceed?\n'
  printf '❯ 1. Yes\n  2. No\n'
} > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/e4"
out="$(run_watch -- gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "0" "question exits 0" "$err"
assert_eq "$(head -1 <<<"$out")" "EVENT question gh-2" "lane with a question prompt is the event" "$err"
assert_contains "$out" "❯ 1. Yes" "pane tail follows the event line" "$err"
assert_not_contains "$out" "gh-1" "a working lane is not reported" "$err"
assert_not_contains "$out" "EVENT idle-after-return" \
  "a selection prompt is a question, never an idle prompt" "$err"

# The question check reads the same liveness answer, so a lane wrapped in a
# shell still gets its prompt answered
new_case question_wrapped_shell
printf 'fish\n' > "$STUB_DIR/cmd-gh-2.txt"
printf '2747883\n' > "$STUB_DIR/kids-9002.txt"
printf 'Do you want to proceed?\n❯ 1. Yes\n  2. No\n' > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/e4a3"
out="$(run_watch -- --max-loops 1 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT question gh-2" \
  "a wrapped lane's question is still the event" "$err"

# A tmux window name carries any character, so two lanes can differ only
# outside a filename-safe set. Their pane snapshots must stay separate or each
# lane is classified on the other's screen.
new_case pane_snapshot_per_lane
printf 'a+b\na:b\n' > "$STUB_DIR/windows.txt"
printf 'claude\n' > "$STUB_DIR/cmd-a+b.txt"
printf 'claude\n' > "$STUB_DIR/cmd-a:b.txt"
printf 'Do you want to proceed?\n❯ 1. Yes\n  2. No\n' > "$STUB_DIR/pane-a+b.txt"
printf '⏺ working on it\n' > "$STUB_DIR/pane-a:b.txt"
err="$TMP_ROOT/e4a2"
out="$(run_watch -- --max-loops 1 'a+b' 'a:b' 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "0" "colliding lane names exit 0" "$err"
assert_eq "$(head -1 <<<"$out")" "EVENT question a+b" \
  "lanes whose names flatten to one slug keep separate pane snapshots" "$err"

# --- 4b. idle-after-return: the round is over and nobody is driving ---------
new_case idle_after_return
{
  printf '⏺ Done: the PR is merged and the worktree is gone.\n'
  printf '❯ \n'
  printf '  bypass permissions on\n'
} > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/e4b"
out="$(run_watch -- gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "0" "idle-after-return exits 0" "$err"
assert_eq "$(head -1 <<<"$out")" "EVENT idle-after-return gh-2" \
  "an idle prompt on two consecutive passes is the event" "$err"
assert_contains "$out" "the PR is merged" "the pane tail follows the idle event" "$err"

# Codex's ready prompt reads differently and counts the same
new_case idle_after_return_codex
printf 'codex\n' > "$STUB_DIR/cmd-gh-2.txt"
printf '· Ran the test suite\n  ⏎ to submit message\n' > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/e4b2"
out="$(run_watch -- gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT idle-after-return gh-2" \
  "a codex lane at its submit prompt is idle too" "$err"

# The idle check reads the same liveness answer too
new_case idle_after_return_wrapped_shell
printf 'fish\n' > "$STUB_DIR/cmd-gh-2.txt"
printf '2747883\n' > "$STUB_DIR/kids-9002.txt"
printf '⏺ Done: the PR is merged.\n❯ \n' > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/e4b7"
out="$(run_watch -- gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT idle-after-return gh-2" \
  "a wrapped lane at its composer is idle, not exited" "$err"

# One pass is not enough: the screen between two tool calls reads the same
new_case idle_after_return_debounce
printf '⏺ Done.\n❯ \n' > "$STUB_DIR/pane-gh-2.txt"
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
  printf '❯ \n'
} > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/e4b4"
out="$(run_watch -- gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT heartbeat loops=2 interval=0s since=none" \
  "a working lane showing its composer prompt is not idle" "$err"
assert_not_contains "$out" "EVENT idle-after-return" "the token counter keeps a busy lane out" "$err"

# The other two working shapes: the interrupt hint and a foreground shell
new_case idle_after_return_working_hints
printf '⏺ Thinking (esc to interrupt)\n❯ \n' > "$STUB_DIR/pane-gh-1.txt"
printf '⎿  (ctrl+b ctrl+b (twice) to run in background)\n❯ \n' > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/e4b5"
out="$(run_watch -- gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT heartbeat loops=2 interval=0s since=none" \
  "the interrupt hint and the background-shell hint both mean busy" "$err"
assert_not_contains "$out" "EVENT idle-after-return" "neither working hint reads as idle" "$err"

# Idle then working is a lane that picked itself back up, not a return
new_case idle_after_return_transient
printf '⏺ Done.\n❯ \n' > "$STUB_DIR/pane-gh-2.1.txt"
printf '✶ Germinating… (2m 4s \xc2\xb7 ↓ 5.0k tokens)\n❯ \n' > "$STUB_DIR/pane-gh-2.2.txt"
err="$TMP_ROOT/e4b6"
out="$(run_watch -- gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT heartbeat loops=2 interval=0s since=none" \
  "an idle pass followed by a working one is not the event" "$err"
assert_not_contains "$out" "EVENT idle-after-return" "a non-consecutive idle reading never fires" "$err"

# A pane keeps its last screen after the harness exits, so a stale prompt
# under a bare shell is not a question anyone can answer — and firing it every
# pass would starve the lane-exited that the second pass earns.
new_case question_bare_shell
printf 'bash\n' > "$STUB_DIR/cmd-gh-2.txt"
printf 'Do you want to proceed?\n❯ 1. Yes\n  2. No\n' > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/e4c"
out="$(run_watch -- --max-loops 1 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT heartbeat loops=1 interval=0s since=none" \
  "a stale prompt under an exited harness is not a question" "$err"
assert_not_contains "$out" "EVENT question" "an exited lane never fires question" "$err"
# ...and the second pass reports it as what it is
err="$TMP_ROOT/e4c2"
out="$(run_watch -- gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT lane-exited gh-2" \
  "the exited lane is reported as exited rather than starved by its stale prompt" "$err"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
