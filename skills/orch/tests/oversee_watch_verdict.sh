#!/usr/bin/env bash
# The queue-verdict event: oversee-watch's wake for a lane whose detached
# `queue-wait` has published a verdict file. merge-pr.md § 5 step 1 names those
# files and owns the four states a lane reads them by; this suite covers only
# which of them the watch turns into an event.
#
# Its own suite rather than a block inside oversee_watch.sh: the fixtures are
# files under the sandbox repo rather than stub-driven `gh` and tmux replies,
# and they have to be cleared between cases, which is a different setup from
# every case there.
#
# The sandbox is lib/oversee-watch-harness.sh, shared with the two suites
# either side of it.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/oversee-watch-harness.sh"

echo "=== oversee-watch queue-verdict ==="

# The check reads the tree the watch runs in, so the fixtures go under the
# sandbox repo and are cleared between cases.
VERDICT_DIR="$TMP_ROOT/repo/tmp"
clear_verdicts() { rm -rf -- "${VERDICT_DIR:?}"; mkdir -p "$VERDICT_DIR"; }

new_case queue_verdict
clear_verdicts
printf '{"status":"complete","verdict":"conflicting","cause":"base_conflict"}\n' \
  > "$VERDICT_DIR/queue-verdict-issue-5-abc123.json"
err="$TMP_ROOT/e1b"
out="$(run_watch -- --item issue-5 --item issue-6 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "0" "a published verdict exits 0" "$err"
assert_contains "$out" "EVENT queue-verdict issue-5" \
  "a published verdict file wakes its lane" "$err"
assert_contains "$out" "queue-verdict-issue-5-abc123.json" \
  "the event names the file the lane reads" "$err"
assert_eq "$(grep -c '^EVENT' <<<"$out")" "1" "one event, for the item that has one" "$err"

# The part file is an unfinished wait: no event, or the lane races the writer.
new_case queue_verdict_part
clear_verdicts
printf '' > "$VERDICT_DIR/queue-verdict-issue-5-abc123.json.part"
err="$TMP_ROOT/e1b2"
out="$(run_watch -- --item issue-5 2>"$err")" && rc=0 || rc=$?
assert_not_contains "$out" "EVENT queue-verdict" \
  "an unpublished .part file is not an event" "$err"

# A published file that does not parse is the lane's hand-back to read, not a
# wake: an event on it would loop the overseer against a file nothing consumes.
new_case queue_verdict_unparsable
clear_verdicts
printf 'setsid: command not found\n' > "$VERDICT_DIR/queue-verdict-issue-5-abc123.json"
err="$TMP_ROOT/e1b3"
out="$(run_watch -- --item issue-5 2>"$err")" && rc=0 || rc=$?
assert_not_contains "$out" "EVENT queue-verdict" \
  "an unparsable verdict file is not an event" "$err"

# A verdict belongs to the item that armed it.
new_case queue_verdict_other_item
clear_verdicts
printf '{"status":"complete","verdict":"merged"}\n' \
  > "$VERDICT_DIR/queue-verdict-issue-9-abc123.json"
err="$TMP_ROOT/e1b4"
out="$(run_watch -- --item issue-5 2>"$err")" && rc=0 || rc=$?
assert_not_contains "$out" "EVENT queue-verdict" \
  "another item's verdict does not wake this fleet" "$err"
clear_verdicts

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
