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
for row in 'verb|0|running|working|working' 'verb|2|running|unjudged|unjudged' 'verb|7|running|unjudged|unjudged' 'verb|7|exited|exited|unjudged' 'verb|0|exited|exited|exited' 'local|0|running|idle|idle' 'absent|0|running|idle|idle'; do
  IFS='|' read -r mode capture_status remote_state direct_want want <<< "$row"
  ROW_CAPS="${CAPS/pane=verb/pane=$mode}"
  [[ "$mode" != absent ]] || ROW_CAPS="${CAPS/$'\tpane=verb'/}"
  export OVERSEE_WATCH_STATE_DIR="$STUB_DIR/cache-$mode-$capture_status"
  export LANE_HOST_STUB_CAPABILITIES="${ROW_CAPS}"
  export LANE_HOST_STUB_CAPTURE_STATUS="$capture_status"
  export LANE_HOST_STUB_HARNESS_STATE="$remote_state"
  # The dormant local shell cannot establish remote exit. Its screen also
  # contradicts the provider's working turn when the legacy route reads it.
  lane_state answer listed bash 9002 "$(cat "$STUB_DIR/pane-gh-2.txt")" '' '' '' issue-2 codex
  assert_eq "$answer" "$direct_want" "lane_state $mode capture=$capture_status status=$remote_state"
  "$SCRIPT_DIR/workflow-state" init oversee >/dev/null
  record="$(jq -cn --arg host "$PROVIDER" '{item:"issue-2",window:"gh-2",host:$host,harness:"codex",status:"running"}')"
  "$SCRIPT_DIR/workflow-state" set oversee lanes "[$record]" >/dev/null
  : > "$STUB_DIR/host.log"
  state="$("$SCRIPTS_DIR/lanes" state gh-2 2>"$STUB_DIR/err")"
  assert_eq "${state%%$'\n'*}" "$want" "lanes state $mode capture=$capture_status" "$STUB_DIR/err"
  if [[ "$mode" == verb ]]; then
    assert_eq "$(grep -c '^capture --item issue-2 ' "$STUB_DIR/host.log" || true)" 1 'lanes state consumes one provider observation'
    assert_eq "$(grep -c '^status --item issue-2 --harness codex ' "$STUB_DIR/host.log" || true)" 1 'lanes state retains process-status proof'
  fi
done
export LANE_HOST_STUB_HARNESS_STATE=running

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
CONTROL="$(OVERSEE_WATCH_STATE_DIR="$STUB_DIR/control-$MUTANT_DIR" ORCH_LANE_HOST="$PROVIDER" LANE_HOST_STUB_CAPABILITIES="$CAPS" LANE_HOST_STUB_CAPTURE_STATUS=0 LANE_HOST_STUB_HARNESS_STATE=exited \
  "$MUTANT_DIR/lanes" state gh-2 2>"$STUB_DIR/control.err")"
assert_eq "${CONTROL%%$'\n'*}" working 'control: omitting hosted identity loses the confirmed process exit'
CONTROL_RED="$(FAIL=0; assert_eq "${CONTROL%%$'\n'*}" exited control >/dev/null; printf '%s' "$FAIL")"
assert_eq "$CONTROL_RED" 1 'the lanes state provider assertion rejects the control'
MUTANT_DIR="$(mutant_scripts observation-control/orch lanes)"
orch_fixture_shared_libs "${MUTANT_DIR%/scripts}"
mutate_file "$MUTANT_DIR/lanes" 'state_source="$LANE_PANE_SOURCE"' 'state_source=""'
: > "$STUB_DIR/host.log"
OVERSEE_WATCH_STATE_DIR="$STUB_DIR/control-$MUTANT_DIR" ORCH_LANE_HOST="$PROVIDER" LANE_HOST_STUB_CAPABILITIES="$CAPS" LANE_HOST_STUB_CAPTURE_STATUS=0 \
  "$MUTANT_DIR/lanes" state gh-2 > "$STUB_DIR/control.out" 2> "$STUB_DIR/control.err"
CONTROL_COUNT="$(grep -c '^capture --item issue-2 ' "$STUB_DIR/host.log" || true)"
CONTROL_RED="$(FAIL=0; assert_eq "$CONTROL_COUNT" 1 control >/dev/null; printf '%s' "$FAIL")"
assert_eq "$CONTROL_RED" 1 'the one-capture assertion rejects a caller that drops observation metadata'

# The overseer reads the diagnostic key and the provider's failure line.
# open-terminal records GitHub items as issue-N and titles their windows gh-N.
# Keep the failed touch private to this row; other provider cases remain neutral.
PROBE_PROVIDER="$STUB_DIR/probe-provider"
cp -p -- "$PROVIDER" "$PROBE_PROVIDER"
mutate_file "$PROBE_PROVIDER" 'touch) [[ "${LANE_HOST_STUB_TOUCH_STATUS:-0}" -eq 0 ]] || exit "$LANE_HOST_STUB_TOUCH_STATUS" ;;' \
  'touch) [[ "$3" == issue-2 ]] || { printf "lane-host-fixture: item-unconfigured item=%s\n" "$3" >&2; exit 2; }; printf "%s\n" "$LANE_HOST_STUB_CAPTURE_ERROR" >&2; exit 7 ;;'
export LANE_HOST_STUB_CAPTURE_ERROR='lane-host-fixture: read-failed cause=connection-lost'
export LANE_HOST_STUB_CAPABILITIES="$CAPS" LANE_HOST_STUB_CAPTURE_STATUS=7
record="$(jq -cn --arg host "$PROBE_PROVIDER" '{item:"issue-2",window:"gh-2",host:$host,harness:"codex",status:"running"}')"
"$SCRIPT_DIR/workflow-state" set oversee lanes "[$record]" >/dev/null
MUTANT_DIR="$(mutant_scripts probe-control/orch lanes)"
orch_fixture_shared_libs "${MUTANT_DIR%/scripts}"
mutate_file "$MUTANT_DIR/lanes" '"$LANE_STATE_ANSWER" == unjudged && "$state_host" != local' \
  '"$LANE_STATE_ANSWER" == unjudged && "${ORCH_LANE_HOST:-local}" != local'
mutate_file "$MUTANT_DIR/lanes" 'probe_err="$(ORCH_LANE_HOST="$state_host" "$SCRIPT_DIR/lane-host" touch' \
  'probe_err="$("$SCRIPT_DIR/lane-host" touch'
ITEM_MUTANT_DIR="$(mutant_scripts probe-item-control/orch lanes)"
orch_fixture_shared_libs "${ITEM_MUTANT_DIR%/scripts}"
mutate_file "$ITEM_MUTANT_DIR/lanes" 'touch --item "$state_probe_item"' 'touch --item "${LANE_ARG#*:}"'
for row in "$SCRIPTS_DIR|verb|0" "$SCRIPTS_DIR|pane|0" "$MUTANT_DIR|verb|1" "$ITEM_MUTANT_DIR|verb|1"; do
  IFS='|' read -r probe_scripts status_mode want_red <<< "$row"
  export OVERSEE_WATCH_STATE_DIR="$STUB_DIR/probe-$status_mode-$probe_scripts"
  export LANE_HOST_STUB_CAPABILITIES="${CAPS/status=verb/status=$status_mode}"
  : > "$STUB_DIR/host.log"
  probe_rc=0
  state="$(env -u ORCH_LANE_HOST "$probe_scripts/lanes" state gh-2 2>"$STUB_DIR/probe.err")" || probe_rc=$?
  assert_eq "$state" unjudged 'a recorded host with no ambient provider retains unjudged'
  assert_eq "$probe_rc" 0 'the failed advisory probe retains exit 0'
  PROBE_RED="$(FAIL=0; assert_file_contains "$STUB_DIR/probe.err" "$LANE_HOST_STUB_CAPTURE_ERROR" 'recorded host failure reaches the overseer' >/dev/null; printf '%s' "$FAIL")"
  assert_eq "$PROBE_RED" "$want_red" 'the recorded-host diagnostic assertion rejects the pre-fix control'
  if [[ "$want_red" == 0 ]]; then
    assert_file_contains "$STUB_DIR/probe.err" 'lanes: host-unreachable item=gh-2 state=unjudged' 'the overseer receives the unavailable-host category'
    assert_file_contains "$STUB_DIR/host.log" 'touch --item issue-2 ' 'the probe names the recorded item even without process status capability'
  fi
done

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
