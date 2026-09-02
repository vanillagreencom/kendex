#!/usr/bin/env bash
# Tracker-side controls for oversee-watch triage events.
set -euo pipefail

# shellcheck source=lib/oversee-watch-harness.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/oversee-watch-harness.sh"

echo "=== oversee-watch triage ==="

new_case triage_new
printf '1786957201\n' > "$STUB_DIR/now.epoch"
printf '3\n' > "$STUB_DIR/tracker.want-created-since"
cat > "$STUB_DIR/tracker.out" <<'EOF'
[
  {"id":"KEN-1200","created_at":"2026-08-15T10:00:00.000Z"},
  {"id":"KEN-1202","created_at":"2026-08-15T10:30:00.000Z"},
  {"id":"KEN-1204","created_at":"2026-08-15T11:30:00.000Z"},
  {"id":"KEN-1199","created_at":"2026-08-15T08:59:59.000Z"}
]
EOF
err="$TMP_ROOT/triage-a"
out="$(run_watch -- --since 2026-08-15T09:00:00Z 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "0" "new triage item exits 0" "$err"
assert_eq "$(head -1 <<<"$out")" "EVENT triage KEN-1200" \
  "an item created after --since is a triage event" "$err"
assert_contains "$out" "EVENT triage KEN-1202" \
  "each new item gets its own triage event line" "$err"
assert_contains "$out" "EVENT triage KEN-1204" \
  "a team item with no lane authorship is still emitted" "$err"
assert_eq "$(grep -c '^EVENT triage ' <<<"$out")" "3" \
  "one wake emits one line per new tracker item" "$err"
assert_not_contains "$out" "KEN-1199" "an item before --since is not emitted" "$err"
tracker_args="$(cat "$STUB_DIR/tracker.args")"
assert_contains "$tracker_args" "issues list --team kendex --created-since " \
  "triage reads the live tracker list for the fleet's team" "$err"
assert_contains "$tracker_args" "d --max --format=safe" \
  "triage uses a created-since day window and fetches every result" "$err"
state_file="$STATE_DIR/owner_repo__2026-08-15T09_00_00Z"
assert_not_contains "$(cat "$state_file")" "$(printf 'triage\tKEN-1200')" \
  "printing an event does not acknowledge the item" "$err"
assert_eq "$(find "$STATE_DIR" -maxdepth 1 -type f | wc -l | tr -d '[:space:]')" "1" \
  "triage creates no second state-file class" "$err"
triage_rule="$(grep '^- `triage`' "$REPO_ROOT/skills/orch/workflows/oversee.md")"
assert_contains "$triage_rule" "every emitted team item" \
  "the event rule covers items with no lane authorship" "$err"
assert_contains "$triage_rule" "kept or canceled" \
  "every emitted item gets a terminal triage verdict" "$err"
assert_contains "$triage_rule" "before re-running" \
  "the verdict is recorded before the watcher can repeat" "$err"
heartbeat_rule="$(grep '^- `heartbeat`' "$REPO_ROOT/skills/orch/workflows/oversee.md")"
assert_contains "$heartbeat_rule" "only issues a fleet lane filed" \
  "the heartbeat backstop stays lane-authored only" "$err"
workflow_text="$(cat "$REPO_ROOT/skills/orch/workflows/oversee.md")"
assert_contains "$workflow_text" "triaged is the verdict log, not the watcher baseline" \
  "the workflow separates verdicts from watcher dedup" "$err"
assert_contains "$workflow_text" "first repository's OVERSEE_WATCH_STATE_DIR baseline" \
  "the workflow names the owner-required baseline" "$err"
assert_contains "$workflow_text" "<project-root>/tmp/oversee-watch" \
  "the workflow names the default state directory" "$err"
assert_contains "$workflow_text" "Deleting that baseline resets watcher dedup" \
  "the workflow states reset and rebuild behavior" "$err"

err="$TMP_ROOT/triage-b"
out="$(run_watch -- --max-loops 1 --since 2026-08-15T09:00:00Z 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT triage KEN-1200" \
  "an unacknowledged item repeats on the next run" "$err"

cat > "$STUB_DIR/oversee-state.json" <<'EOF'
{"triaged":[
  {"issue":"KEN-1200","verdict":"kept"},
  {"issue":"KEN-1202","verdict":"canceled"},
  {"issue":"KEN-1204","verdict":"pending"}
]}
EOF
err="$TMP_ROOT/triage-b2"
out="$(run_watch -- --max-loops 1 --since 2026-08-15T09:00:00Z 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT triage KEN-1204" \
  "a pending verdict does not acknowledge the item" "$err"
assert_contains "$(cat "$state_file")" "$(printf 'triage\tKEN-1200')" \
  "a kept verdict rebuilds the watcher baseline" "$err"
assert_contains "$(cat "$state_file")" "$(printf 'triage\tKEN-1202')" \
  "a canceled verdict rebuilds the watcher baseline" "$err"
assert_not_contains "$(cat "$state_file")" "$(printf 'triage\tKEN-1204')" \
  "a pending verdict stays out of watcher dedup" "$err"
assert_contains "$(cat "$STUB_DIR/workflow-state.args")" "kept" \
  "the verdict read accepts kept outcomes" "$err"
assert_contains "$(cat "$STUB_DIR/workflow-state.args")" "canceled" \
  "the verdict read accepts canceled outcomes" "$err"
assert_contains "$(cat "$STUB_DIR/workflow-state.args")" "--state-dir $TMP_ROOT/repo/tmp get oversee" \
  "the verdict read anchors default state to the project tmp directory" "$err"

cat > "$STUB_DIR/oversee-state.json" <<'EOF'
{"triaged":[
  {"issue":"KEN-1200","verdict":"kept"},
  {"issue":"KEN-1202","verdict":"canceled"},
  {"issue":"KEN-1204","verdict":"kept"}
]}
EOF
err="$TMP_ROOT/triage-b3"
out="$(run_watch -- --max-loops 1 --since 2026-08-15T09:00:00Z 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT heartbeat loops=1 interval=0s since=2026-08-15T09:00:00Z" \
  "terminal verdicts close every repeated event" "$err"

cat > "$STUB_DIR/tracker.out" <<'EOF'
[
  {"id":"KEN-1201","created_at":"2026-08-15T11:00:00.000Z"},
  {"id":"KEN-1200","created_at":"2026-08-15T10:00:00.000Z"}
]
EOF
err="$TMP_ROOT/triage-c"
out="$(run_watch -- --since 2026-08-15T09:00:00Z 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT triage KEN-1201" \
  "a later tracker item fires on the next run" "$err"
assert_not_contains "$out" "EVENT triage KEN-1200" "the prior item stays deduplicated" "$err"

# Control: no new item emits no triage event.
new_case triage_empty
printf '[]\n' > "$STUB_DIR/tracker.out"
err="$TMP_ROOT/triage-d"
out="$(run_watch -- --max-loops 1 --since 2026-08-15T09:00:00Z 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT heartbeat loops=1 interval=0s since=2026-08-15T09:00:00Z" \
  "an empty tracker list reaches the heartbeat" "$err"
assert_not_contains "$out" "EVENT triage" "no new item emits no triage event" "$err"

# Read failures and malformed output are unknown fleet state, never empty.
new_case triage_list_failure
printf '2\n' > "$STUB_DIR/tracker.rc"
printf 'Linear API unavailable\n' > "$STUB_DIR/tracker.err"
err="$TMP_ROOT/triage-e"
out="$(run_watch -- --since 2026-08-15T09:00:00Z 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "2" "a tracker list failure exits 2" "$err"
assert_eq "$out" "" "a tracker list failure emits no event" "$err"
assert_contains "$(cat "$err")" "Linear API unavailable" \
  "the tracker failure keeps its real cause" "$err"

new_case triage_malformed
printf '{}\n' > "$STUB_DIR/tracker.out"
err="$TMP_ROOT/triage-f"
out="$(run_watch -- --since 2026-08-15T09:00:00Z 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "2" "malformed tracker output exits 2" "$err"
assert_eq "$out" "" "malformed tracker output emits no event" "$err"
assert_contains "$(cat "$err")" "tracker output is not an array" \
  "the malformed shape is named" "$err"

new_case triage_state_failure
printf '[{"id":"KEN-1200","created_at":"2026-08-15T10:00:00.000Z"}]\n' > "$STUB_DIR/tracker.out"
printf '{"triaged":[{"issue":"KEN-1200","verdict":"kept"}]}\n' > "$STUB_DIR/oversee-state.json"
mkdir -p "$STATE_DIR/owner_repo__2026-08-15T09_00_00Z"
err="$TMP_ROOT/triage-g"
out="$(run_watch OVERSEE_WATCH_PR_WATCH="$TMP_ROOT/bin/absent-pr-watch" -- --since 2026-08-15T09:00:00Z 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "2" "an unwritable triage baseline exits 2" "$err"
assert_eq "$out" "" "a verdict baseline write failure emits no event" "$err"
assert_contains "$(cat "$err")" "could not write the pr-watch state file" \
  "the triage failure names the shared baseline" "$err"

new_case triage_verdict_read_failure
printf '2\n' > "$STUB_DIR/workflow-state.rc"
printf 'oversee state unreadable\n' > "$STUB_DIR/workflow-state.err"
err="$TMP_ROOT/triage-verdict-read"
out="$(run_watch -- --since 2026-08-15T09:00:00Z 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "2" "an unreadable verdict log exits 2" "$err"
assert_eq "$out" "" "an unreadable verdict log emits no event" "$err"
assert_contains "$(cat "$err")" "oversee state unreadable" \
  "the verdict read keeps its original cause" "$err"

new_case triage_invalid_verdict_id
printf '{"triaged":[{"issue":"bad id","verdict":"kept"}]}\n' > "$STUB_DIR/oversee-state.json"
err="$TMP_ROOT/triage-invalid-id"
out="$(run_watch -- --since 2026-08-15T09:00:00Z 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "2" "an invalid verdict issue id exits 2" "$err"
assert_eq "$out" "" "an invalid verdict issue id emits no event" "$err"
assert_contains "$(cat "$err")" "invalid issue id: 'bad id'" \
  "the invalid verdict id is named" "$err"

# Triage keys and reducer keys coexist in the one first-repository baseline.
# A triage rewrite that starts from empty loses the standing reducer edge and
# the next run incorrectly emits pr-watch.
new_case triage_preserves_pr_keys
printf '12\tabcdef01\tthreads-open\t2 unresolved\n' > "$STUB_DIR/prwatch.out"
printf '1\n' > "$STUB_DIR/prwatch.rc"
printf '[{"id":"KEN-1200","created_at":"2026-08-15T10:00:00.000Z"}]\n' > "$STUB_DIR/tracker.out"
printf '{"triaged":[{"issue":"KEN-1200","verdict":"kept"}]}\n' > "$STUB_DIR/oversee-state.json"
err="$TMP_ROOT/triage-coexist-a"
out="$(run_watch -- --max-loops 1 --since 2026-08-15T09:00:00Z 2>"$err")" && rc=0 || rc=$?
state_file="$STATE_DIR/owner_repo__2026-08-15T09_00_00Z"
assert_contains "$(cat "$state_file")" "$(printf '12\tthreads-open')" \
  "triage reconciliation preserves the reducer key" "$err"
assert_contains "$(cat "$state_file")" "$(printf 'triage\tKEN-1200')" \
  "the verdict key shares the reducer baseline" "$err"
err="$TMP_ROOT/triage-coexist-b"
out="$(run_watch -- --max-loops 1 --since 2026-08-15T09:00:00Z 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT heartbeat loops=1 interval=0s since=2026-08-15T09:00:00Z" \
  "unchanged reducer attention stays baselined after triage" "$err"

new_case since_requires_utc_z
err="$TMP_ROOT/triage-h"
out="$(run_watch -- --since 2026-08-15 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "2" "a date-only --since is rejected" "$err"
assert_eq "$out" "" "a date-only --since emits no event" "$err"
assert_contains "$(cat "$err")" "UTC timestamp ending in Z" \
  "the date-only refusal names the documented form" "$err"

new_case since_rejects_offset
err="$TMP_ROOT/triage-i"
out="$(run_watch -- --since 2026-08-15T09:00:00+00:00 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "2" "an offset --since is rejected" "$err"
assert_eq "$out" "" "an offset --since emits no event" "$err"
assert_contains "$(cat "$err")" "UTC timestamp ending in Z" \
  "the offset refusal names the documented form" "$err"

date_harness="$(cat "$REPO_ROOT/skills/orch/tests/lib/oversee-watch-harness.sh")"
assert_contains "$date_harness" "OVERSEE_TEST_REAL_DATE" \
  "the harness resolves date before its PATH shadow" "$err"
assert_not_contains "$date_harness" "exec /usr/bin/date" \
  "the date stub carries no Linux-only absolute fallback" "$err"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
