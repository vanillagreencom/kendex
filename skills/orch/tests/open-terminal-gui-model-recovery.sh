#!/usr/bin/env bash
# Surface: open-terminal fresh GUI identity through model-switch recovery.
# Inputs: skills/orch/scripts/** skills/github/scripts/lib/** skills/mailbox/scripts/** hooks/lane-mail-check.sh hooks/lane-mail-model-switch.sh hooks/tests/lib/lane-mail-world.sh
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
TEST_ROOT="$(cd -- "${BASH_SOURCE[0]%/*}/../../.." && pwd -P)"
source "$TEST_ROOT/hooks/tests/lib/lane-mail-world.sh"
source "$TEST_ROOT/skills/orch/tests/lib/assertions.sh"
source "$TEST_ROOT/skills/orch/tests/lib/shared-skill-libs.sh"
source "$TEST_ROOT/skills/orch/tests/lib/growth-state.sh"
source "$TEST_ROOT/skills/orch/scripts/lib/lane-state.sh"

mkdir -p "$TMP_ROOT/bin/hold"
cp -- "$(command -v sleep)" "$TMP_ROOT/bin/hold/claude"
cat > "$TMP_ROOT/bin/claude" <<'HARNESS'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "$MODEL_ARGV"
printf '%s\n' "$$" > "$MODEL_PID"
exec "$MODEL_HOLD" 90
HARNESS
cat > "$TMP_ROOT/bin/terminal" <<'TERMINAL'
#!/usr/bin/env bash
set -euo pipefail
# Execute the GUI command without loading this host's login profile.
exec "$BASH" -c "${!#}"
TERMINAL
cat > "$TMP_ROOT/bin/worktree" <<'WORKTREE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$MODEL_WORKTREE"
WORKTREE
cat > "$TMP_ROOT/bin/lanes" <<'LANES'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" != list ]] || printf '[]\n'
LANES
chmod +x "$TMP_ROOT/bin/claude" "$TMP_ROOT/bin/terminal" "$TMP_ROOT/bin/worktree" "$TMP_ROOT/bin/lanes"

cleanup_gui() {
  local file pid start
  for file in "$TMP_ROOT"/*/tmp/harness.pid; do
    if [[ -s "$file" && -s "$file.start" ]]; then
      read -r pid < "$file"
      read -r start < "$file.start"
      lane_stop_identity "$pid" "$start" claude 2>/dev/null || :
    fi
  done
  stop_wake_processes
  rm -rf -- "${TMP_ROOT:?}"
}
trap cleanup_gui EXIT

recovery_contract() { # STATE ARGUMENTS
  assert_eq "$(jq '[.fleet_log[]? | select(.kind=="model-switched")]|length' "$1")" 1 'fresh GUI fallback writes one model-switched row'
  assert_eq "$(cat "$2" 2>/dev/null || :)" '--dangerously-skip-permissions --model claude-opus-4-8 --effort high' 'fresh GUI fallback relaunches on the launched model'
}

while IFS='|' read -r name control; do
  new_lane "$name" KEN-4022
  mkdir -p "$LANE/tmp"
  S="$LANE/.agents/skills/orch/scripts"
  rm -- "$S"
  cp -R -- "$REPO_ROOT/skills/orch/scripts" "$S"
  rm -- "$LANE/.agents/skills/mailbox/scripts"
  orch_fixture_shared_libs "${S%/scripts}"
  if [[ "$control" == old ]]; then
    # Disable the launch binding while keeping its body: old production leaves
    # both session_id and launch null, so the real hook reports unavailable.
    mutate_file "$S/open-terminal" 'if [[ "$FLEET" == true && "$LANE_HOST" == local && "$TERMINAL_MODE" != tmux && "$WAKE" != true && "$HARNESS" == claude && -z "$CMD_TEMPLATE" ]]; then' \
      'if [[ "$FLEET" == true && "$LANE_HOST" == local && "$TERMINAL_MODE" != tmux && "$WAKE" != true && "$HARNESS" == claude && -z "$CMD_TEMPLATE" ]] && false; then'
  fi
  # No tmux server and no --ghostty: this is the fresh local GUI route.
  (cd -- "$LANE" && env -u TMUX -u TMUX_PANE ORCH_TMUX_SESSION= ORCH_LANE_HOST=local ORCH_LANE_PREFERENCE= \
    "PATH=$TMP_ROOT/bin:$PATH" "TERMINAL=$TMP_ROOT/bin/terminal" "WORKTREE_CLI=$TMP_ROOT/bin/worktree" \
    "LANES_CLI=$TMP_ROOT/bin/lanes" "LANES_HOME=$OFFLINE_HOME" "CLAUDE_CONFIG_DIR=$OFFLINE_HOME" \
    "MODEL_WORKTREE=$LANE" "MODEL_ARGV=$LANE/tmp/fresh.argv" "MODEL_PID=$LANE/tmp/harness.pid" \
    "MODEL_HOLD=$TMP_ROOT/bin/hold/claude" LINEAR_TEAM= ORCH_STATE_DIR=tmp \
    "$S/open-terminal" --state-dir "$LANE/tmp" --harness claude \
      --launch-flags '--dangerously-skip-permissions --model claude-opus-4-8 --effort high' KEN-4022) > "$LANE/tmp/launch.log" 2>&1
  deadline=$((SECONDS + 15))
  while [[ ! -s "$LANE/tmp/harness.pid" ]]; do
    [[ "$SECONDS" -lt "$deadline" ]] || { cat "$LANE/tmp/launch.log"; exit 1; }
    sleep 0.05
  done
  read -r pid < "$LANE/tmp/harness.pid"
  start="$(lane_process_start "$pid")"
  printf '%s\n' "$start" > "$LANE/tmp/harness.pid.start"
  session="$(awk 'prev=="--session-id" { print; exit } {prev=$0}' "$LANE/tmp/fresh.argv")"
  [[ -n "$session" ]] || session=old-native-session
  if [[ "$control" == current ]]; then
    assert_eq "$(jq -r --arg s "$session" '.lanes[0] | [.session_id==$s, .launch.pid!=null, .launch.start!=null, .launch.pane==null, .surface=="gui"] | all' "$LANE/tmp/workflow-state-oversee.json")" true 'fresh GUI records its native session and process without a pane'
    identity="$(jq -r '.lanes[0].launch | "\(.pid) \(.start)"' "$LANE/tmp/workflow-state-oversee.json")"
    assert_eq "$(lane_harness_identity "${identity%% *}" claude | cut -d ' ' -f1)" "$pid" 'the recorded process owns the launched harness'
  fi
  # Only the final launch dependency is captured. The hook, recovery claim,
  # process stop, argument selection and state writes remain production code.
  cat > "$S/open-terminal" <<'RELAUNCH'
#!/usr/bin/env bash
set -euo pipefail
while [[ "$1" != --launch-flags ]]; do shift; done
printf '%s\n' "$2" > "$MODEL_RECOVERY_ARGV"
RELAUNCH
  chmod +x "$S/open-terminal"
  install_hook "$REPO_ROOT/hooks/lane-mail-model-switch.sh" "$LANE/.claude/hooks/lane-mail-model-switch.sh"
  CALL_ENV=("PATH=$TMP_ROOT/bin:$PATH" "MODEL_RECOVERY_ARGV=$LANE/tmp/recovery.argv" ORCH_MODEL_RECOVERY_LIMIT=3)
  payload="$(jq -nc --arg s "$session" '{hook_event_name:"PostModelSwitch",session_id:$s,to_model:"claude-sonnet-4-6"}')"
  run_payload "$payload"
  state="$LANE/tmp/workflow-state-oversee.json"
  if [[ "$control" == current ]]; then
    deadline=$((SECONDS + 15))
    while [[ "$(jq -r '.fleet_log[]? | select(.kind=="model-switched") | .recovery' "$state")" != replaced ]]; do
      [[ "$SECONDS" -lt "$deadline" ]] || { cat "$LANE/tmp/model-recovery-KEN-4022.log"; exit 1; }
      sleep 0.05
    done
    run_payload "$payload"
    recovery_contract "$state" "$LANE/tmp/recovery.argv"
    process_state="$(lane_process_state "$pid")"
    case "$process_state" in ''|Z) process_state=stopped ;; esac
    assert_eq "$process_state" stopped 'recovery stops the launched GUI harness'
  else
    assert_eq "$(jq -r --arg s "$session" '.model_checks[$s].cause' "$LANE/tmp/workflow-state-KEN-4022.json")" launch-unbound 'old production reports unavailable'
    control_failures="$(FAIL=0; recovery_contract "$state" "$LANE/tmp/recovery.argv" > "$LANE/tmp/control.log"; printf '%s' "$FAIL")"
    assert_eq "$control_failures" 2 'control: old launch binding fails both recovery guarantees'
    lane_stop_identity "$pid" "$start" claude
  fi
done <<'ROWS'
fresh-gui|current
old-gui|old
ROWS

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
