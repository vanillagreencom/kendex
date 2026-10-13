#!/usr/bin/env bash
# Surface: lane_state and the lanes state caller's provider-pane observation.
# Inputs: scripts/lib/lane-state.sh, scripts/lanes, scripts/lib,
# tests/fixtures/lane-host and tests/lib/oversee-watch-harness.sh.
set -euo pipefail
TEST_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$TEST_DIR/lib/git-env.sh"
source "$TEST_DIR/lib/oversee-watch-harness.sh"
source "$TEST_DIR/lib/shared-skill-libs.sh"
SCRIPTS_DIR="$REPO_ROOT/skills/orch/scripts"
SCRIPT_DIR="$SCRIPTS_DIR"
source "$SCRIPT_DIR/lib/lane-state.sh"
PROVIDER="$REPO_ROOT/skills/orch/tests/fixtures/lane-host"
CAPS=$'kind=ssh\tlaunch=ssh\tchannel=mailbox\tfiles=verb\tstatus=verb\tstop=verb\trelaunch=resume\tpark=none\taccounts=none\tpool=plan\tland=lane\tpane=verb'
new_case provider
export STUB_DIR
export PATH="$TMP_ROOT/bin:$PATH"
export LANE_HOST_STUB_LOG="$STUB_DIR/host.log"
export LANE_HOST_STUB_CAPTURE_FILE="$STUB_DIR/provider-screen"
export LANE_HOST_STUB_CAPABILITIES="$CAPS"
export ORCH_LANE_HOST="$PROVIDER"
export ORCH_STATE_DIR="$STUB_DIR/workflow"
cd -- "$TMP_ROOT/repo"
printf 'stub\tgh-2\t%%2\t9002\tbash\n' > "$STUB_DIR/panes.txt"
printf '› Type a prompt\n  ? for shortcuts\n' > "$STUB_DIR/pane-gh-2.txt"
cp "$STUB_DIR/pane-gh-2.txt" "$STUB_DIR/pane-%2.txt"
printf '› task\n  press to interrupt\n' > "$LANE_HOST_STUB_CAPTURE_FILE"
for row in 'verb|0|working' 'verb|2|unjudged' 'verb|7|unjudged' 'local|0|idle' 'absent|0|idle'; do
  IFS='|' read -r mode capture_status want <<< "$row"
  ROW_CAPS="${CAPS/pane=verb/pane=$mode}"
  [[ "$mode" != absent ]] || ROW_CAPS="${CAPS/$'\tpane=verb'/}"
  export OVERSEE_WATCH_STATE_DIR="$STUB_DIR/cache-$mode-$capture_status"
  export LANE_HOST_STUB_CAPABILITIES="${ROW_CAPS}"
  export LANE_HOST_STUB_CAPTURE_STATUS="$capture_status"
  # The dormant local shell cannot establish remote exit. Its screen also
  # contradicts the provider's working turn when the legacy route reads it.
  lane_state answer listed bash 9002 "$(cat "$STUB_DIR/pane-gh-2.txt")" '' '' '' issue-2 codex
  assert_eq "$answer" "$want" "lane_state $mode capture=$capture_status"
  "$SCRIPT_DIR/workflow-state" init oversee >/dev/null
  record="$(jq -cn --arg host "$PROVIDER" '{item:"issue-2",window:"gh-2",host:$host,harness:"codex",status:"running"}')"
  "$SCRIPT_DIR/workflow-state" set oversee lanes "[$record]" >/dev/null
  state="$("$SCRIPTS_DIR/lanes" state gh-2 2>"$STUB_DIR/err")"
  assert_eq "${state%%$'\n'*}" "$want" "lanes state $mode capture=$capture_status" "$STUB_DIR/err"
done

"$SCRIPT_DIR/workflow-state" set oversee lanes '[]' >/dev/null
for row in 'verb|unjudged' 'local|exited'; do
  IFS='|' read -r mode want <<< "$row"
  export OVERSEE_WATCH_STATE_DIR="$STUB_DIR/unrecorded-$mode"
  export LANE_HOST_STUB_CAPABILITIES="${CAPS/pane=verb/pane=$mode}" LANE_HOST_STUB_CAPTURE_STATUS=0
  state="$("$SCRIPTS_DIR/lanes" state gh-2 2>"$STUB_DIR/err")"
  assert_eq "${state%%$'\n'*}" "$want" "an unrecorded $mode lane cannot use a dormant shell to prove remote exit"
done
"$SCRIPT_DIR/workflow-state" set oversee lanes "[$record]" >/dev/null

MUTANT_DIR="$(mutant_scripts capture-control/orch lib/lane-state.sh)"
orch_fixture_shared_libs "${MUTANT_DIR%/scripts}"
mutate_file "$MUTANT_DIR/lib/lane-state.sh" 'if [[ "$_ls_mode" == verb ]]; then' 'if false; then'
CONTROL="$(OVERSEE_WATCH_STATE_DIR="$STUB_DIR/control-$MUTANT_DIR" ORCH_LANE_HOST="$PROVIDER" LANE_HOST_STUB_CAPABILITIES="$CAPS" LANE_HOST_STUB_CAPTURE_STATUS=0 \
  "$BASH" -c 'SCRIPT_DIR="$1"; source "$1/lib/lane-state.sh"; lane_state answer listed bash 9002 "$(cat "$2")" "" "" "" issue-2 codex; printf "%s" "$answer"' \
  _ "$MUTANT_DIR" "$STUB_DIR/pane-gh-2.txt")"
assert_eq "$CONTROL" idle 'control: skipping provider capture lets local text change lane_state'
CONTROL_RED="$(FAIL=0; assert_eq "$CONTROL" working control >/dev/null; printf '%s' "$FAIL")"
assert_eq "$CONTROL_RED" 1 'the lane_state provider assertion rejects the control'
MUTANT_DIR="$(mutant_scripts caller-control/orch lanes)"
orch_fixture_shared_libs "${MUTANT_DIR%/scripts}"
mutate_file "$MUTANT_DIR/lanes" '"$STATE_ROWS" "$state_item" "$state_harness"' '"$STATE_ROWS" "" ""'
CONTROL="$(OVERSEE_WATCH_STATE_DIR="$STUB_DIR/control-$MUTANT_DIR" ORCH_LANE_HOST="$PROVIDER" LANE_HOST_STUB_CAPABILITIES="$CAPS" LANE_HOST_STUB_CAPTURE_STATUS=0 \
  "$MUTANT_DIR/lanes" state gh-2 2>"$STUB_DIR/control.err")"
assert_eq "${CONTROL%%$'\n'*}" exited 'control: omitting hosted identity lets the dormant local shell establish exit'
CONTROL_RED="$(FAIL=0; assert_eq "${CONTROL%%$'\n'*}" working control >/dev/null; printf '%s' "$FAIL")"
assert_eq "$CONTROL_RED" 1 'the lanes state provider assertion rejects the control'

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
