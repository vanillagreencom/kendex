#!/usr/bin/env bash
# Surface: oversee-watch observe_lanes provider captures and failed reads.
# Inputs: scripts/oversee-watch, scripts/lib, tests/fixtures/lane-host,
# tests/lib/oversee-watch-harness.sh.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/oversee-watch-harness.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/shared-skill-libs.sh"
PROVIDER="$REPO_ROOT/skills/orch/tests/fixtures/lane-host"
CAPS=$'kind=ssh\tlaunch=ssh\tchannel=mailbox\tfiles=verb\tstatus=verb\tstop=verb\trelaunch=resume\tpark=none\taccounts=none\tpool=plan\tland=lane\tpane=verb'
MUTANT_DIR="$(mutant_scripts observe-control/orch oversee-watch)"
orch_fixture_shared_libs "${MUTANT_DIR%/scripts}"
mutate_file "$MUTANT_DIR/oversee-watch" 'lane_pane_capture "$pane_mode" "$pane_host" "$pane_item" "$target"' 'lane_pane_capture local "$pane_host" "$pane_item" "$target"'
for row in 'verb|0|live|true|0' 'verb|2|live|false|0' 'verb|7|live|false|0' 'local|0|live|false|1' 'absent|0|live|false|1' 'verb|0|control|false|1'; do
  IFS='|' read -r mode capture_status kind asking local_reads <<< "$row"
  ROW_CAPS="${CAPS/pane=verb/pane=$mode}"
  [[ "$mode" != absent ]] || ROW_CAPS="${CAPS/$'\tpane=verb'/}"
  new_case "provider-$mode-$capture_status-$kind"
  printf 'bash\n' > "$STUB_DIR/cmd-gh-2.txt"
  printf '› task\n  press to interrupt\n' > "$STUB_DIR/pane-gh-2.txt"
  cp "$CODEX_PANES/codex-dialog-trust.txt" "$STUB_DIR/provider-screen"
  mkdir -p "$STUB_DIR/remote/srv/lane/tmp"
  printf 'gitdir: /srv/clone/.git/worktrees/issue-2\n' > "$STUB_DIR/remote/srv/lane/.git"
  printf 'started\n' > "$STUB_DIR/remote/srv/lane/tmp/lane-status-issue-2.md"
  jq -cn --arg host "$PROVIDER" '{issue_id:"oversee",triaged:[],lanes:[{item:"issue-2",window:"gh-2",host:$host,mail_root:"/srv/lane",harness:"codex",status:"running"}]}' > "$STUB_DIR/fleet.json"
  TARGET="$REPO_ROOT/skills/orch/scripts/oversee-watch"
  [[ "$kind" != control ]] || TARGET="$MUTANT_DIR/oversee-watch"
  OUT="$(WATCH_BIN="$TARGET" run_watch LANE_HOST_STUB_CAPABILITIES="${ROW_CAPS}" \
    LANE_HOST_STUB_LOG="$STUB_DIR/host.log" LANE_HOST_STUB_DIR="$STUB_DIR/remote" \
    LANE_HOST_STUB_CAPTURE_FILE="$STUB_DIR/provider-screen" LANE_HOST_STUB_CAPTURE_STATUS="$capture_status" \
    -- --state "$STUB_DIR/fleet.json" --max-loops 1 2>"$STUB_DIR/err")"
  seen=false
  [[ "$OUT" != *'EVENT lane-asking gh-2'* ]] || seen=true
  assert_eq "$seen" "$asking" "observe_lanes $mode/$capture_status/$kind uses provider dialog" "$STUB_DIR/err"
  if [[ "$kind" == control ]]; then
    CONTROL_RED="$(FAIL=0; assert_eq "$seen" true control >/dev/null; printf '%s' "$FAIL")"
    assert_eq "$CONTROL_RED" 1 'the watch provider assertion rejects local capture'
  fi
  assert_eq "$(cat "$STUB_DIR/pane-gh-2.calls" 2>/dev/null || echo 0)" "$local_reads" \
    "observe_lanes $mode/$capture_status/$kind local screen reads"
  assert_eq "$(grep -c '^capture --item issue-2 ' "$STUB_DIR/host.log" || true)" \
    "$([[ "$mode" == verb && "$kind" == live ]] && echo 1 || echo 0)" 'watch captures a provider pane once per pass'
done
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
