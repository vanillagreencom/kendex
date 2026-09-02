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
