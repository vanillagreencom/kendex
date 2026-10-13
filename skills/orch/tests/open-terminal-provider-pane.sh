#!/usr/bin/env bash
# Surface: open-terminal provider-pane launch, verification and input.
# Inputs: scripts/open-terminal, scripts/lib, tests/fixtures/lane-host,
# tests/lib/open-terminal-lane-world.sh and its shared helpers.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
TMP_ROOT="$(mktemp -d)" || exit 1
[[ -d "$TMP_ROOT" && ! -L "$TMP_ROOT" ]] || exit 1
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || exit 1
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
source "$(dirname "${BASH_SOURCE[0]}")/lib/open-terminal-lane-world.sh"

HOST_STUB="$TEST_DIR/fixtures/lane-host"
CAPS=$'kind=ssh\tlaunch=ssh\tchannel=mailbox\tfiles=verb\tstatus=verb\tstop=verb\trelaunch=resume\tpark=none\taccounts=none\tpool=plan\tland=lane\tpane=verb'
cat > "$OT_STUB_BIN/ssh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" > "$LANE_HOST_STUB_LOG.ssh"
[[ "$1" == -T && "$2" == -o && "$3" == BatchMode=yes && "$4" == -- && $# == 6 ]] || exit 1
[[ -z "$(cat)" ]] || exit 1
[[ -z "${SSH_PANE_CONTROL:-}" ]] || tmux send-keys -t %1 Enter
[[ "${SSH_FAIL:-0}" == 0 ]] || exit "$SSH_FAIL"
exec "$BASH" -c "$6"
SH
cat > "$TMP_ROOT/provider-prefix" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
command="${1//\/srv\/lane/$LANE_HOST_STUB_DIR/srv/lane}"
exec "$BASH" -c "$command"
SH
cat > "$OT_STUB_BIN/claude" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "$LANE_HOST_STUB_LOG.started"
SH
chmod +x "$OT_STUB_BIN/ssh" "$OT_STUB_BIN/claude" "$TMP_ROOT/provider-prefix"
export LANE_HOST_STUB_CREATE_LINE=$'ssh-target=lane.example\tpath=/srv/lane\tremote-prefix='"$TMP_ROOT/provider-prefix"
CURRENT="$TMP_ROOT/provider-screen"
READY="$TMP_ROOT/provider-ready"
DELIVERED="$TMP_ROOT/provider-delivered"
printf '\xe2\x9d\xaf\xc2\xa0\n' > "$READY"
printf '/orch start KEN-40\n' > "$DELIVERED"

local_input_count() { grep -cE '^(load-buffer|paste-buffer|send-keys) ' "$RUN/tmux.log" || true; }
launch_contract() { printf '%s\n' "$OUT" > "$RUN/launch-errors"; assert_eq "rc=$RC local=$(local_input_count)" 'rc=0 local=0' "$1" "$RUN/launch-errors"; }

for row in 'delivered|0|0' 'composer|0|1' 'dialog|2|1'; do
  IFS='|' read -r initial viewer_status needs_send <<< "$row"
  case "$initial" in
    delivered) cp "$DELIVERED" "$CURRENT" ;;
    composer) cp "$READY" "$CURRENT" ;;
    dialog) printf 'Choose theme\n' > "$CURRENT" ;;
  esac
  run_ot "$CHOICE;$COMPACTION_OFF_ALL;ORCH_LANE_HOST=$HOST_STUB;LANE_HOST_STUB_CAPABILITIES=$CAPS;LANE_HOST_STUB_CAPTURE_FILE=$CURRENT;LANE_HOST_STUB_SENT_FILE=$TMP_ROOT/sent-$initial;LANE_HOST_STUB_AFTER_KEY=$READY;LANE_HOST_STUB_AFTER_FILE=$DELIVERED;LANE_HOST_STUB_VIEWER_STATUS=$viewer_status;LANE_HOST_STUB_VIEWER_LINE=ssh human-viewer;OT_PANE_TEXT=Choose theme" \
    --harness claude --lane "$H/.eclaude" --repo o/r KEN-40
  launch_contract "$initial launch uses the provider with a contradicting local dialog"
  assert_eq "$(grep -c '^/orch start KEN-40' "$RUN/host.log.started" || true)" 1 \
    "$initial provider prefix executes the harness with its rendered brief"
  assert_eq "$(grep -c '^capture --item KEN-40 --history ' "$RUN/host.log" || true)" \
    "$([[ "$needs_send" == 0 ]] && echo 1 || echo 2)" "$initial verification reads provider history"
  assert_eq "$(grep -c '^send --item KEN-40 --file ' "$RUN/host.log" || true)" "$needs_send" \
    "$initial brief goes through provider send"
  assert_eq "$(grep -c '^send --item KEN-40 --key Enter ' "$RUN/host.log" || true)" \
    "$([[ "$initial" == dialog ]] && echo 1 || echo 0)" "$initial nudge goes through provider send"
  assert_eq "$(grep -c '^set-option .* @lane-viewer-command ssh human-viewer$' "$RUN/tmux.log" || true)" \
    "$([[ "$viewer_status" == 0 ]] && echo 1 || echo 0)" "$initial optional viewer command"
  assert_eq "$(grep -c '^capture-pane ' "$RUN/tmux.log" || true)" 0 "$initial reads no local screen"
  assert_eq "$(grep -cE '^new-window .* -d( |$)' "$RUN/tmux.log" || true)" 1 "$initial dormant window stays unselected"
done

cp "$READY" "$CURRENT"
run_ot "$CHOICE;$COMPACTION_OFF_ALL;ORCH_LANE_HOST=$HOST_STUB;LANE_HOST_STUB_CAPABILITIES=$CAPS;LANE_HOST_STUB_CAPTURE_FILE=$CURRENT;OT_PANE_TEXT=Choose theme" \
  --harness claude --lane "$H/.eclaude" --repo o/r --relaunch KEN-40
launch_contract 'relaunch harness wait reads the provider composer'
assert_eq "$(grep -c '^capture --item KEN-40 ' "$RUN/host.log" || true)" 1 'harness wait uses provider viewport'

cp "$READY" "$CURRENT"
run_ot "$CHOICE;$COMPACTION_OFF_ALL;ORCH_LANE_HOST=$HOST_STUB;LANE_HOST_STUB_CAPABILITIES=$CAPS;LANE_HOST_STUB_CAPTURE_FILE=$CURRENT;LANE_HOST_STUB_SENT_FILE=$TMP_ROOT/sent-refused;LANE_HOST_STUB_PROBE_STATUS=7" \
  --harness claude --lane "$H/.eclaude" --repo o/r KEN-40
assert_eq "rc=$RC sends=$(grep -c '^send ' "$RUN/host.log" || true) local=$(local_input_count)" \
  'rc=1 sends=0 local=0' 'a failed process read refuses launch input'

for failure in 'SSH_FAIL=7' 'LANE_HOST_STUB_VIEWER_STATUS=7'; do
  cp "$DELIVERED" "$CURRENT"
  run_ot "$CHOICE;$COMPACTION_OFF_ALL;ORCH_LANE_HOST=$HOST_STUB;LANE_HOST_STUB_CAPABILITIES=$CAPS;LANE_HOST_STUB_CAPTURE_FILE=$CURRENT;$failure" \
    --harness claude --lane "$H/.eclaude" --repo o/r KEN-40
  assert_eq "rc=$RC local=$(local_input_count)" 'rc=1 local=0' "host launch refuses $failure"
done

cp "$DELIVERED" "$CURRENT"
run_ot "$CHOICE;$COMPACTION_OFF_ALL;ORCH_LANE_HOST=$HOST_STUB;LANE_HOST_STUB_CAPABILITIES=$CAPS;LANE_HOST_STUB_CAPTURE_FILE=$CURRENT;SSH_PANE_CONTROL=1" \
  --harness claude --lane "$H/.eclaude" --repo o/r KEN-40
CONTROL_RC=0
( FAIL=0; launch_contract 'control'; [[ "$FAIL" == 0 ]] ) > "$TMP_ROOT/control.log" 2>&1 || CONTROL_RC=$?
assert_eq "$CONTROL_RC" 1 'control: a transport that types into the local pane fails the launch contract'

SHIPPED_OPEN_TERMINAL="$OPEN_TERMINAL"
CLEANUP_MUTANT="$(mutant_scripts detached-cleanup/orch open-terminal)/open-terminal"
orch_fixture_shared_libs "$TMP_ROOT/detached-cleanup/orch"
mutate_file "$CLEANUP_MUTANT" 'host_pane_stop() {' 'host_pane_stop() { return 0;'
for row in '0|live|stopped|1' '7|live|running|0' '7|control|stopped|1'; do
  IFS='|' read -r stop_status code status killed <<< "$row"
  fleet="$TMP_ROOT/cleanup-$stop_status-$code"
  ot_fleet_state "$SCRIPTS_DIR/workflow-state" "$fleet" "$PWD"
  record="$(jq -cn --arg host "$HOST_STUB" --arg account "$H/.eclaude" '{item:"KEN-40",window:"stub:KEN-40",host:$host,kind:"ssh",harness:"claude",account:$account,mail_root:"/srv/lane",status:"running",launched_at:"2026-10-01T00:00:00Z"}')"
  "$SCRIPTS_DIR/workflow-state" --state-dir "$fleet" set oversee lanes "[$record]" >/dev/null
  printf 'Choose theme\n' > "$CURRENT"
  OPEN_TERMINAL="$SHIPPED_OPEN_TERMINAL"
  [[ "$code" != control ]] || OPEN_TERMINAL="$CLEANUP_MUTANT"
  run_ot "$CHOICE;$COMPACTION_OFF_ALL;ORCH_LANE_HOST=$HOST_STUB;LANE_HOST_STUB_CAPABILITIES=$CAPS;LANE_HOST_STUB_CAPTURE_FILE=$CURRENT;LANE_HOST_STUB_STOP_STATUS=$stop_status" \
    --harness claude --lane "$H/.eclaude" --repo o/r --state-dir "$fleet" --relaunch KEN-40
  got="rc=$RC status=$("$SCRIPTS_DIR/workflow-state" --state-dir "$fleet" get oversee '.lanes[0].status') killed=$(grep -c '^kill-window ' "$RUN/tmux.log" || true)"
  assert_eq "$got" "rc=1 status=$status killed=$killed" "detached $code relaunch stop=$stop_status"
  if [[ "$code" == control ]]; then
    CONTROL_RED="$(FAIL=0; assert_eq "$got" 'rc=1 status=running killed=0' control >/dev/null; printf '%s' "$FAIL")"
    assert_eq "$CONTROL_RED" 1 'a failed provider stop cannot be hidden by closing its dormant local window'
  else
    assert_eq "$(grep -c '^stop --item KEN-40 --harness claude ' "$RUN/host.log" || true)" \
      "$([[ "$stop_status" == 0 ]] && echo 2 || echo 1)" 'detached relaunch stops the old harness and any failed new attempt through the provider'
  fi
done
OPEN_TERMINAL="$SHIPPED_OPEN_TERMINAL"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
