#!/usr/bin/env bash
# bash-runtime: 3.2
# Surface: shared parked interval accounting and check_lane_long.
# Inputs: scripts/lib/watch-host-kinds.sh, tests/lib/*.sh.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/assertions.sh"
TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "${2:-$TEST_DIR/../scripts/lib/watch-host-kinds.sh}"

FLEET_STATE='{"lanes":[{"item":"test","launched_at":"2026-10-22T22:00:00Z","parked":{"at":"2026-10-22T22:30:00Z"}}]}'
PASS_NOW=1792717200
# All times are injected. The cutoff is 2026-10-23 01:00 UTC.
LAUNCH=1792706400
if [[ "${1:-}" != --long-only ]]; then
for row in \
  '{"parked":{"at":"2026-10-22T22:30:00Z"}}|9000' \
  '{"pauses":[{"cause":"parked","from":"2026-10-22T22:30:00Z","to":"2026-10-22T23:30:00Z"},{"cause":"parked","from":"2026-10-22T23:00:00Z","to":"2026-10-23T00:00:00Z"}],"parked":{"at":"2026-10-23T00:00:00Z"}}|9000' \
  '{"parked":{"at":"invalid"}}|unavailable' \
  '{"parked":{"at":"2026-10-24T00:00:00Z"}}|unavailable' \
  '{"parked":{"at":"2026-10-22T22:30:00Z","timing_unread":true}}|unavailable'; do
  IFS='|' read -r record expected <<<"$row"
  got="$(jq -er --argjson from "$LAUNCH" --argjson to "$PASS_NOW" "$LANE_INTERVALS_JQ"'lane_parked_seconds($from;$to)' <<<"$record" 2>/dev/null)" || got=unavailable
  assert_eq "$got" "$expected" 'parked intervals union open/completed pauses and reject unread timings'
done
split="$(jq -r "$LANE_INTERVALS_JQ"'
  .lanes[0] | lane_pauses(true) as $spans
  | [covered_seconds($spans;1792706400;1792713600),covered_seconds($spans;1792713600;1792717200)] | @tsv' <<<"$FLEET_STATE")"
assert_eq "$split" $'5400\t3600' 'calendar-day clipping splits a confirmed pause at midnight'

fi

# Keep the state and stage readers at their ordinary dependency boundary.
lane_row_get() { :; }
lane_row_set() { printf '%s' "$4"; }
lane_row_prune() { printf '%s' "$2"; }
lane_row_commit() { :; }
lane_step() { LANE_STEP=parked; }
lane_long_rounds() {
  LANE_REVIEW_ROUNDS=0 LANE_FIX_RECEIPTS=0 LANE_VALIDATION_RUNS=0 LANE_RESTACKS=0 LANE_REPEATED_CLASS_ROUNDS=0
}
ow_message() { printf '%s\n' "$*" >&2; }
PW_SEEN=('')
while IFS='|' read -r LANE_AGE_SECS ages lanes events unavailable label; do
  read -r -a LANE_AGES <<<"$ages"
  FLEET_STATE="{\"lanes\":$lanes}"
  RECORDED_ITEMS=(test unread young)
  output="$(check_lane_long 2>&1)"
  assert_eq "$(awk '/^EVENT lane-long / {print $3 "=" $4}' <<<"$output")" "$events" "$label"
  assert_eq "$(awk '/^lane-time-unavailable / {print $2}' <<<"$output")" "$unavailable" "$label preserves unavailable timing per lane"
done <<'ROWS'
2000|test=1792706400|[{"item":"test","parked":{"at":"2026-10-22T22:30:00Z"}}]|||parked compute time alone cannot trigger a long-lane event
1000|test=1792706400|[{"item":"test","parked":{"at":"2026-10-22T22:30:00Z"}}]|test=age=1800||the long-lane event retains work before the park
2000|young=1792716300|[{"item":"young","parked":{"at":"invalid"}}]|||a raw age below the threshold needs no interval judgment
1000|unread=1792706400 test=1792706400|[{"item":"unread","parked":{"at":"invalid"}},{"item":"test","parked":{"at":"2026-10-22T22:30:00Z"}}]|test=age=1800|item=unread|unread timing does not hide a readable due sibling
1000|test=1792706400 unread=1792706400|[{"item":"test","parked":{"at":"2026-10-22T22:30:00Z"}},{"item":"unread","parked":{"at":"2026-10-22T22:30:00Z","timing_unread":true}}]|test=age=1800|item=unread|unconfirmed timing does not change a readable sibling's active age
ROWS
if [[ "${1:-}" != --long-only ]]; then
  TMP_ROOT="$(mktemp -d)" || { echo "lane_park_time: scratch=mktemp-failed" >&2; exit 1; }
  [[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "lane_park_time: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
  TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "lane_park_time: scratch=resolve-failed" >&2; exit 1; }
  trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
  source "$TEST_DIR/lib/growth-state.sh"
  cp -- "${2:-$TEST_DIR/../scripts/lib/watch-host-kinds.sh}" "$TMP_ROOT/intervals.sh"
  mutate_file "$TMP_ROOT/intervals.sh" 'catch "unavailable") as $paused' \
    'catch "unavailable" | if . == "unavailable" then error(.) else . end) as $paused'
  control_rc=0
  "$BASH" "$TEST_DIR/lane_park_time.sh" --long-only "$TMP_ROOT/intervals.sh" > "$TMP_ROOT/control.out" 2>&1 || control_rc=$?
  assert_eq "$control_rc" 1 'control: failing a whole batch on unread timing loses the readable due sibling'
  assert_contains "$(cat -- "$TMP_ROOT/control.out")" '  FAIL  unread timing does not hide a readable due sibling' \
    'control: the mixed timing row rejects the lost sibling'
fi
printf '\npass: %s   fail: %s\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
