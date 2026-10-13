#!/usr/bin/env bash
# Surface: pane-write hosted window and pane input routing.
# Inputs: scripts/pane-write, scripts/lib, tests/fixtures/lane-host,
# tests/lib/growth-state.sh, tests/lib/shared-skill-libs.sh.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
TEST_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TMP_ROOT="$(mktemp -d)" || exit 1
[[ -d "$TMP_ROOT" && ! -L "$TMP_ROOT" ]] || exit 1
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || exit 1
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
source "$TEST_DIR/lib/assertions.sh"
source "$TEST_DIR/lib/growth-state.sh"
source "$TEST_DIR/lib/shared-skill-libs.sh"
SCRIPTS="$(mutant_scripts provider-write/orch pane-write)"
orch_fixture_shared_libs "${SCRIPTS%/scripts}"
mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/repo"
git -C "$TMP_ROOT/repo" init -q
git -C "$TMP_ROOT/repo" config gc.auto 0
git -C "$TMP_ROOT/repo" config maintenance.auto false
rm -- "$SCRIPTS/workflow-state"
cat > "$SCRIPTS/workflow-state" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == --state-dir ]]; then
  [[ "$2" == "$PANE_TEST_STATE" ]] || exit 1
  shift 2
fi
case "$1" in
  exists) printf '{"exists":true}\n' ;;
  get) cat "$PANE_TEST_RECORD" ;;
  *) exit 2 ;;
esac
SH
cat > "$TMP_ROOT/bin/tmux" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$PANE_TEST_TMUX"
case "$1" in
  list-panes)
    if [[ "$*" == *window_name* ]]; then printf 'stub\tKEN-40\t%%2\t1\t%s\n' "${LOCAL_PROCESS:-bash}"
    else printf '%%2 1 %s\n' "${LOCAL_PROCESS:-bash}"; fi ;;
  display-message)
    if [[ "$*" == *session_name* ]]; then printf 'stub:KEN-40\n'; else printf '0\n'; fi ;;
esac
SH
chmod +x "$SCRIPTS/workflow-state" "$TMP_ROOT/bin/tmux"
PROVIDER="$TEST_DIR/fixtures/lane-host"
CAPS=$'kind=ssh\tlaunch=ssh\tchannel=mailbox\tfiles=verb\tstatus=verb\tstop=verb\trelaunch=resume\tpark=none\taccounts=none\tpool=plan\tland=lane\tpane=verb'
export PANE_TEST_STATE="$TMP_ROOT/fleet"
export PATH="$TMP_ROOT/bin:$PATH" PANE_TEST_RECORD="$TMP_ROOT/record"
export PANE_TEST_TMUX="$TMP_ROOT/local-input" LANE_HOST_STUB_LOG="$TMP_ROOT/provider-calls"
export LANE_HOST_STUB_SENT_FILE="$TMP_ROOT/delivered"
printf 'continue the task' > "$TMP_ROOT/input"
# Another session with the same window name must not redirect input.
jq -cn --arg host "$PROVIDER" '[{item:"OTHER",window:"other:KEN-40",host:$host,harness:"claude",status:"running"},{item:"KEN-40",window:"stub:KEN-40",host:$host,harness:"codex",status:"running"}]' > "$PANE_TEST_RECORD"
cd -- "$TMP_ROOT/repo"
for row in 'window|ssh|file|0|0|0|1' 'pane|ssh|key|0|0|0|1' 'window|codex|file|0|0|0|1' 'window|claude|file|0|0|1|0' 'window|ssh|file|7|0|1|0' 'window|ssh|file|0|7|2|0' 'window|ssh|file|0|0|1|0|exited'; do
  IFS='|' read -r target_kind expect action probe_status send_status want_rc delivered harness_state <<< "$row"
  : > "$PANE_TEST_TMUX"; : > "$LANE_HOST_STUB_LOG"; : > "$LANE_HOST_STUB_SENT_FILE"
  target=stub:KEN-40; [[ "$target_kind" != pane ]] || target=%2
  value="$TMP_ROOT/input"; [[ "$action" != key ]] || value=Enter
  rc=0
  LANE_HOST_STUB_CAPABILITIES="$CAPS" LANE_HOST_STUB_PROBE_STATUS="$probe_status" LANE_HOST_STUB_SEND_STATUS="$send_status" LANE_HOST_STUB_HARNESS_STATE="${harness_state:-running}" \
    "$SCRIPTS/pane-write" "--$target_kind" "$target" --expect "$expect" "--$action" "$value" --state-dir "$PANE_TEST_STATE" 2>"$TMP_ROOT/err" || rc=$?
  assert_eq "$rc" "$want_rc" "$target_kind/$expect/$action process=$probe_status send=$send_status" "$TMP_ROOT/err"
  assert_eq "$(grep -cE '^(load-buffer|paste-buffer|send-keys) ' "$PANE_TEST_TMUX" || true)" 0 'provider input leaves the dormant local pane untouched'
  [[ "$delivered" == 0 ]] || assert_eq "$(grep -c '^send --item KEN-40 ' "$LANE_HOST_STUB_LOG" || true)" 1 'provider send addresses the correct recorded item'
  if [[ "$delivered" == 1 ]]; then
    [[ "$action" != file ]] || assert_eq "$(cat "$LANE_HOST_STUB_SENT_FILE")" 'continue the task' 'file bytes arrive through the provider'
    [[ "$action" != key ]] || assert_eq "$(cat "$LANE_HOST_STUB_SENT_FILE")" Enter 'key arrives through the provider'
  else assert_eq "$(cat "$LANE_HOST_STUB_SENT_FILE")" '' 'a refused write delivers nothing'; fi
done
: > "$PANE_TEST_TMUX"
rc=0
OVERSEE_WATCH_STATE_DIR="$TMP_ROOT/cache-local" LANE_HOST_STUB_CAPABILITIES="${CAPS/$'\tpane=verb'/}" \
  "$SCRIPTS/pane-write" --window stub:KEN-40 --expect ssh --file "$TMP_ROOT/input" 2>"$TMP_ROOT/err" || rc=$?
assert_eq "$rc" 1 'a legacy provider retains the local wrong-process refusal'

cp "$PANE_TEST_RECORD" "$TMP_ROOT/record-saved"
printf '[]\n' > "$PANE_TEST_RECORD"
for row in 'verb|1' 'local|0'; do
  IFS='|' read -r mode want_rc <<< "$row"
  : > "$PANE_TEST_TMUX"
  rc=0
  ORCH_LANE_HOST="$PROVIDER" OVERSEE_WATCH_STATE_DIR="$TMP_ROOT/unrecorded-$mode" LANE_HOST_STUB_CAPABILITIES="${CAPS/pane=verb/pane=$mode}" \
    "$SCRIPTS/pane-write" --window stub:KEN-40 --expect shell --file "$TMP_ROOT/input" 2>"$TMP_ROOT/err" || rc=$?
  assert_eq "$rc" "$want_rc" "an unrecorded $mode target input route"
  if [[ "$mode" == verb ]]; then
    assert_eq "$(grep -cE '^(load-buffer|paste-buffer|send-keys) ' "$PANE_TEST_TMUX" || true)" 0 'an unrecorded hosted target types nothing into the dormant local pane'
  fi
done
mv -- "$TMP_ROOT/record-saved" "$PANE_TEST_RECORD"

cp "$SCRIPTS/lib/lane-claims.sh" "$TMP_ROOT/lane-claims-control"
rm -- "$SCRIPTS/lib/lane-claims.sh"
mv -- "$TMP_ROOT/lane-claims-control" "$SCRIPTS/lib/lane-claims.sh"
mutate_file "$SCRIPTS/lib/lane-claims.sh" '$scope == "session"' '$scope == "unused"'
: > "$LANE_HOST_STUB_LOG"
LANE_HOST_STUB_CAPABILITIES="$CAPS" "$SCRIPTS/pane-write" --window stub:KEN-40 --expect ssh --file "$TMP_ROOT/input" 2>"$TMP_ROOT/err"
CONTROL_RED="$(FAIL=0; assert_eq "$(grep -c '^send --item KEN-40 ' "$LANE_HOST_STUB_LOG" || true)" 1 control >/dev/null; printf '%s' "$FAIL")"
assert_eq "$CONTROL_RED" 1 'control: omitting the session check sends input to another hosted item'
mutate_file "$SCRIPTS/lib/lane-claims.sh" '$scope == "unused"' '$scope == "session"'

mutate_file "$SCRIPTS/pane-write" 'if [[ "$mode" == verb ]]; then' 'if false; then'
rc=0
LANE_HOST_STUB_CAPABILITIES="$CAPS" "$SCRIPTS/pane-write" --window stub:KEN-40 --expect ssh --file "$TMP_ROOT/input" 2>"$TMP_ROOT/err" || rc=$?
assert_eq "$rc" 1 'control: local process validation refuses input to the remote running harness'
CONTROL_RED="$(FAIL=0; assert_eq "$rc" 0 control >/dev/null; printf '%s' "$FAIL")"
assert_eq "$CONTROL_RED" 1 'the provider input assertion rejects the local control'
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
