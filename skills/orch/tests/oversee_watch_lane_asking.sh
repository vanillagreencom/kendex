#!/usr/bin/env bash
# Cross-run state controls for oversee-watch lane-asking events.
set -euo pipefail

# shellcheck source=lib/oversee-watch-harness.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/oversee-watch-harness.sh"

echo "=== oversee-watch lane-asking state ==="

new_case lane_asking_once
printf 'Do you want to proceed?\n   ❯ 1. Yes\n     2. No\n' > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/asking-a"
out="$(run_watch -- --max-loops 1 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT lane-asking gh-2" \
  "a new prompt emits lane-asking" "$err"

err="$TMP_ROOT/asking-b"
out="$(run_watch -- --max-loops 1 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT heartbeat loops=1 interval=0s since=none" \
  "the same prompt is emitted only once" "$err"
assert_not_contains "$out" "EVENT lane-asking" "an unchanged prompt never repeats" "$err"

printf 'Do you want to pick the other path?\n   ❯ 1. Yes\n     2. No\n' > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/asking-c"
out="$(run_watch -- --max-loops 1 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT lane-asking gh-2" \
  "a changed prompt emits a new lane-asking event" "$err"

# Prompt A clears when a later observation sees no prompt, then A is new again.
new_case lane_asking_disappears
printf 'Do you want to proceed?\n   ❯ 1. Yes\n     2. No\n' > "$STUB_DIR/pane-gh-2.txt"
run_watch -- --max-loops 1 gh-1 gh-2 >/dev/null 2>"$TMP_ROOT/asking-reset-a"
printf '⏺ working on it\n' > "$STUB_DIR/pane-gh-2.txt"
run_watch -- --max-loops 1 gh-1 gh-2 >/dev/null 2>"$TMP_ROOT/asking-reset-b"
printf 'Do you want to proceed?\n   ❯ 1. Yes\n     2. No\n' > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/asking-reset-c"
out="$(run_watch -- --max-loops 1 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT lane-asking gh-2" \
  "prompt A emits again after a no-prompt observation" "$err"

# An earlier merged event must not strand the old prompt baseline when the
# pane has already moved through a no-prompt screen.
new_case lane_asking_disappears_before_merge
printf 'Do you want to proceed?\n   ❯ 1. Yes\n     2. No\n' > "$STUB_DIR/pane-gh-2.txt"
run_watch -- --max-loops 1 gh-1 gh-2 >/dev/null 2>"$TMP_ROOT/asking-merge-a"
printf '⏺ working on it\n' > "$STUB_DIR/pane-gh-2.txt"
printf '[{"number":5,"headRefName":"issue-5","mergedAt":"2026-08-15T10:00:00Z"}]\n' > "$STUB_DIR/merged.json"
out="$(run_watch -- --max-loops 1 --item issue-5 gh-1 gh-2 2>"$TMP_ROOT/asking-merge-b")"
assert_eq "$(head -1 <<<"$out")" "EVENT merged 5 issue-5" \
  "the earlier merge event preempts the ordinary lane event pass"
printf '[]\n' > "$STUB_DIR/merged.json"
printf 'Do you want to proceed?\n   ❯ 1. Yes\n     2. No\n' > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/asking-merge-c"
out="$(run_watch -- --max-loops 1 --item issue-5 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT lane-asking gh-2" \
  "prompt A emits after disappearing behind an earlier event" "$err"

# The same text in a replacement pane is a new prompt occurrence.
new_case lane_asking_relaunch
printf '7000 %%2\n' > "$STUB_DIR/pane-key-gh-2.txt"
printf 'Do you want to proceed?\n   ❯ 1. Yes\n     2. No\n' > "$STUB_DIR/pane-gh-2.txt"
run_watch -- --max-loops 1 gh-1 gh-2 >/dev/null 2>"$TMP_ROOT/asking-relaunch-a"
printf '7000 %%9\n' > "$STUB_DIR/pane-key-gh-2.txt"
err="$TMP_ROOT/asking-relaunch-b"
out="$(run_watch -- --max-loops 1 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT lane-asking gh-2" \
  "the same prompt emits in a replacement pane" "$err"

# The prompt text can repeat in one pane after the operator answered it. The
# submitted turn is the occurrence boundary even when the new dialog is equal.
new_case lane_asking_identical_reprompt
printf 'Do you want to proceed?\n   ❯ 1. Yes\n     2. No\n' > "$STUB_DIR/pane-gh-2.txt"
run_watch -- --max-loops 1 gh-1 gh-2 >/dev/null 2>"$TMP_ROOT/asking-reprompt-a"
{
  printf 'Do you want to proceed?\n   ❯ 1. Yes\n     2. No\n'
  printf '❯ 1\n'
  printf 'Do you want to proceed?\n   ❯ 1. Yes\n     2. No\n'
} > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/asking-reprompt-b"
out="$(run_watch -- --max-loops 1 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT lane-asking gh-2" \
  "an identical prompt emits after a submitted answer" "$err"

# A failed fresh capture is a probe error once tmux confirmed the window.
# The failed redirect must not leave a reusable marker or lose stderr.
new_case lane_asking_capture_failure
: > "$STUB_DIR/capture-fail-gh-2"
err="$TMP_ROOT/asking-capture-fail"
out="$(run_watch -- --max-loops 1 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "2" "capture failure exits 2 after the window probe" "$err"
assert_eq "$out" "" "capture failure emits no window-gone event" "$err"
assert_contains "$(cat "$err")" "pane capture failed for 'gh-2'" \
  "capture failure names the probe" "$err"
assert_contains "$(cat "$err")" "capture failed: gh-2" \
  "capture failure preserves tmux stderr" "$err"

# Control: a pane without a prompt emits no lane-asking event.
new_case lane_asking_no_prompt
err="$TMP_ROOT/asking-d"
out="$(run_watch -- --max-loops 1 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT heartbeat loops=1 interval=0s since=none" \
  "a pane with no prompt reaches the heartbeat" "$err"
assert_not_contains "$out" "EVENT lane-asking" "no prompt emits no lane-asking event" "$err"

new_case lane_asking_corrupt_state
mkdir -p "$STATE_DIR"
printf '{bad json\n' > "$STATE_DIR/lane-asking__none.json"
err="$TMP_ROOT/asking-e"
out="$(run_watch -- --max-loops 1 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "2" "a corrupt lane-asking baseline exits 2" "$err"
assert_eq "$out" "" "a corrupt lane-asking baseline emits no event" "$err"
assert_contains "$(cat "$err")" "lane-asking state file is invalid" \
  "the corrupt lane-asking baseline is named" "$err"

new_case lane_asking_state_unwritable
mkdir -p "$STATE_DIR/lane-asking__none.json"
printf 'Do you want to proceed?\n   ❯ 1. Yes\n     2. No\n' > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/asking-f"
out="$(run_watch -- --max-loops 1 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "2" "a lane-asking baseline write failure exits 2" "$err"
assert_eq "$(head -1 <<<"$out")" "EVENT lane-asking gh-2" \
  "the event is delivered before its baseline write" "$err"
assert_contains "$(cat "$err")" "could not write the lane-asking state file" \
  "the baseline write failure names its target" "$err"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
