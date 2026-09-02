#!/usr/bin/env bash
# Tracker-side controls for oversee-watch triage events.
set -euo pipefail

# shellcheck source=lib/oversee-watch-harness.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/oversee-watch-harness.sh"

echo "=== oversee-watch triage ==="

new_case triage_new
cat > "$STUB_DIR/tracker.out" <<'EOF'
[
  {"id":"KEN-1200","created_at":"2026-08-15T10:00:00.000Z"},
  {"id":"KEN-1202","created_at":"2026-08-15T10:30:00.000Z"},
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
assert_eq "$(grep -c '^EVENT triage ' <<<"$out")" "2" \
  "one wake emits one line per new tracker item" "$err"
assert_not_contains "$out" "KEN-1199" "an item before --since is not emitted" "$err"
tracker_args="$(cat "$STUB_DIR/tracker.args")"
assert_contains "$tracker_args" "issues list --team kendex --created-since " \
  "triage reads the live tracker list for the fleet's team" "$err"
assert_contains "$tracker_args" "d --max --format=safe" \
  "triage uses a created-since day window and fetches every result" "$err"
assert_eq "$(cat "$STUB_DIR/workflow-state.args")" \
  "get oversee .triaged // [] | map(.issue) | .[]" \
  "triage deduplicates against the fleet's verdict log" "$err"

printf 'KEN-1200\nKEN-1202\n' > "$STUB_DIR/tracker-triaged.txt"
err="$TMP_ROOT/triage-b"
out="$(run_watch -- --max-loops 1 --since 2026-08-15T09:00:00Z 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT heartbeat loops=1 interval=0s since=2026-08-15T09:00:00Z" \
  "an already-triaged item does not repeat" "$err"
assert_not_contains "$out" "EVENT triage" "the triage verdict closes the event" "$err"

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

new_case triage_log_failure
printf '[{"id":"KEN-1200","created_at":"2026-08-15T10:00:00.000Z"}]\n' > "$STUB_DIR/tracker.out"
printf '2\n' > "$STUB_DIR/workflow-state.rc"
printf 'fleet state is corrupt\n' > "$STUB_DIR/workflow-state.err"
err="$TMP_ROOT/triage-g"
out="$(run_watch -- --since 2026-08-15T09:00:00Z 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "2" "an unreadable fleet triage log exits 2" "$err"
assert_eq "$out" "" "an unreadable fleet triage log emits no event" "$err"
assert_contains "$(cat "$err")" "fleet state is corrupt" \
  "the fleet triage log keeps its real failure" "$err"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
