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
source "$TEST_ROOT/skills/orch/scripts/lib/lane-launch.sh"

mkdir -p "$TMP_ROOT/bin/hold"
cp -- "$(command -v sleep)" "$TMP_ROOT/bin/hold/claude"
cat > "$TMP_ROOT/bin/claude" <<'HARNESS'
#!/usr/bin/env bash
set -euo pipefail
# Freeze the production record at harness entry, before any acknowledgement.
# A later read could hide a harness that ran before launch_record_finish.
record=null
[[ ! -r "$MODEL_WORKTREE/tmp/workflow-state-oversee.json" ]] || record="$(< "$MODEL_WORKTREE/tmp/workflow-state-oversee.json")"
printf '%s\n' "$@" > "$MODEL_ARGV"
. "$MODEL_SCRIPTS/lib/lane-state.sh"
session="$(awk 'prev=="--session-id" {print;exit} {prev=$0}' "$MODEL_ARGV")"
lane="$(jq -c '[.lanes[]? | select(.item=="KEN-4022")] | first // null' <<<"$record")"
root="$(jq -r '.launch.pid // empty' <<<"$lane")"
start="$(jq -r '.launch.start // empty' <<<"$lane")"
process_matches=false
if [[ -n "$root" && -n "$start" ]] && lane_identity_status "$root" "$start"; then
  table="$(lane_process_table)"
  process_matches="$(lane_process_below "$table" "$root" '' 1 '' pids | awk -v pid="$$" '$2==pid {found=1} END {print found ? "true" : "false"}')"
fi
jq -nc --arg session "$session" --argjson lane "$lane" --argjson process_matches "$process_matches" \
  '{session:$session,lane:$lane,process_matches:$process_matches}' > "$MODEL_WORKTREE/tmp/startup.$$.json"
lane_identity_record "$MODEL_WORKTREE/tmp/process.$$"
printf '%s\n' "$$" >> "$MODEL_STARTS"
printf '%s\n' "$$" > "$MODEL_PID"
exec "$MODEL_HOLD" 90
HARNESS
cat > "$TMP_ROOT/bin/terminal" <<'TERMINAL'
#!/usr/bin/env bash
set -euo pipefail
# Execute the GUI command without loading this host's login profile.
[[ "${MODEL_DELAY:-0}" == 0 ]] || sleep "$MODEL_DELAY"
rc=0
"$BASH" -c "${!#}" >> "$MODEL_TERMINAL_LOG" 2>&1 || rc=$?
printf '%s\n' "$rc" > "$MODEL_TERMINAL_DONE"
exit "$rc"
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

# The launch table owns Claude's full-bypass spelling.
GUI_BYPASS="$(launch_choice_permission_write claude)" || { echo 'open-terminal-gui-model-recovery: bypass=unread' >&2; exit 1; }
[[ -n "$GUI_BYPASS" ]] || { echo 'open-terminal-gui-model-recovery: bypass=empty' >&2; exit 1; }
GUI_FLAGS="$GUI_BYPASS --model claude-opus-4-8 --effort high"

cleanup_gui() {
  local file
  for file in "$TMP_ROOT"/*/tmp/process.*; do
    if lane_identity_read "$file"; then
      lane_stop_identity "$LANE_IDENTITY_PID" "$LANE_IDENTITY_START" claude 2>/dev/null || :
    fi
  done
  stop_wake_processes
  rm -rf -- "${TMP_ROOT:?}"
}
trap cleanup_gui EXIT

startup_contract() { # DIRECTORY PID LABEL
  assert_eq "$(jq -r '.session!="" and .lane.session_id==.session and .lane.status=="running" and .lane.surface=="gui" and .lane.launch.pid!=null and .lane.launch.start!=null and .process_matches' "$1/startup.$2.json")" \
    true "$3 sees its own session and verified process binding before acknowledging start"
}

recovery_contract() { # STATE ARGUMENTS STARTS
  assert_eq "$(jq '[.fleet_log[]? | select(.kind=="model-switched")]|length' "$1")" 1 'fresh GUI fallback writes one model-switched row'
  assert_eq "$(wc -l < "$3" | tr -d ' ')" 2 'the real replacement launcher starts a second harness'
  assert_eq "$(jq -r '.lanes[0] | .status=="running" and .surface=="gui" and .launch.pid!=null and .launch.start!=null' "$1")" true 'the replacement is a recorded GUI launch'
  assert_eq "$(awk -v bypass="$GUI_BYPASS" '/^--model$/{getline;model=$0} /^--effort$/{getline;effort=$0} $0==bypass{permissions="bypass"} END{print model "|" effort "|" permissions}' "$2")" \
    'claude-opus-4-8|high|bypass' 'the real replacement keeps the launched model, effort and permissions'
  startup_contract "${3%/*}" "$(tail -n 1 "$3")" 'the replacement harness'
}

while IFS='|' read -r name control; do
  new_lane "$name" KEN-4022
  mkdir -p "$LANE/tmp"
  S="$LANE/.agents/skills/orch/scripts"
  rm -- "$S"
  cp -R -- "$REPO_ROOT/skills/orch/scripts" "$S"
  rm -- "$LANE/.agents/skills/mailbox/scripts"
  orch_fixture_shared_libs "${S%/scripts}"
  GUI_ENV=("PATH=$TMP_ROOT/bin:$PATH" "TERMINAL=$TMP_ROOT/bin/terminal" "WORKTREE_CLI=$TMP_ROOT/bin/worktree"
    "LANES_CLI=$TMP_ROOT/bin/lanes" "LANES_HOME=$OFFLINE_HOME" "CLAUDE_CONFIG_DIR=$OFFLINE_HOME"
    "MODEL_WORKTREE=$LANE" "MODEL_ARGV=$LANE/tmp/fresh.argv" "MODEL_PID=$LANE/tmp/harness.pid"
    "MODEL_SCRIPTS=$S" "MODEL_STARTS=$LANE/tmp/starts" "MODEL_TERMINAL_DONE=$LANE/tmp/terminal.done"
    "MODEL_TERMINAL_LOG=$LANE/tmp/terminal.log"
    "MODEL_HOLD=$TMP_ROOT/bin/hold/claude" ORCH_TMUX_SESSION= ORCH_LANE_HOST=local ORCH_LANE_PREFERENCE= LINEAR_TEAM= ORCH_STATE_DIR=tmp)
  if [[ "$control" == old ]]; then
    # Disable the launch binding while keeping its body: old production leaves
    # both session_id and launch null, so the real hook reports unavailable.
    mutate_file "$S/open-terminal" 'if [[ "$FLEET" == true && "$LANE_HOST" == local && "$TERMINAL_MODE" != tmux && "$WAKE" != true && "$HARNESS" == claude && -z "$CMD_TEMPLATE" ]]; then' \
      'if [[ "$FLEET" == true && "$LANE_HOST" == local && "$TERMINAL_MODE" != tmux && "$WAKE" != true && "$HARNESS" == claude && -z "$CMD_TEMPLATE" ]] && false; then'
  fi
  if [[ "$control" == tmux ]]; then
    mutate_file "$S/lib/lane-relaunch.sh" 'terminal=--ghostty' 'terminal=--tmux'
  fi
  if [[ "$control" == early ]]; then
    # Preserve the ready barrier below this insertion. The mutation starts
    # the real harness before that barrier and exits when its harness ends.
    mutate_file "$S/open-terminal" '  lane_identity_record "$gui_dir/identity" || exit 1' \
      '  lane_identity_record "$gui_dir/identity" || exit 1
  eval "$3"
  exit $?'
  fi
  expected_failure="" expected_cause=""
  case "$control" in
    slow) GUI_ENV+=(MODEL_DELAY=6); expected_failure=launch-identity-unread; expected_cause=startup ;;
    uuid|git|scratch)
      mkdir -p "$LANE/bin"
      GUI_ENV+=("PATH=$LANE/bin:$TMP_ROOT/bin:$PATH")
      case "$control" in
        uuid)
          printf '#!%s\nexit 7\n' "$BASH" > "$LANE/bin/python3"
          chmod +x "$LANE/bin/python3"
          expected_failure=launch-session-failed; expected_cause=failed ;;
        git)
          # Marker setup reads the same git property first. Its completion
          # acknowledges that this fault belongs to GUI startup itself.
          GUI_ENV+=("MODEL_MARKER_DONE=$LANE/tmp/marker.done")
          mv -- "$S/lane-marker" "$S/lane-marker.actual"
          printf '#!%s\n"$0.actual" "$@" && : > "$MODEL_MARKER_DONE"\n' "$BASH" > "$S/lane-marker"
          chmod +x "$S/lane-marker"
          printf '#!%s\nif [[ -e "$MODEL_MARKER_DONE" ]]; then for a in "$@"; do [[ "$a" != --absolute-git-dir ]] || exit 7; done; fi\nexec %q "$@"\n' "$BASH" "$(command -v git)" > "$LANE/bin/git"
          chmod +x "$LANE/bin/git"
          expected_failure=launch-identity-unread; expected_cause=git-dir ;;
        scratch)
          printf '#!%s\n[[ "$*" != *gui-launch.* ]] || exit 7\nexec %q "$@"\n' "$BASH" "$(command -v mktemp)" > "$LANE/bin/mktemp"
          chmod +x "$LANE/bin/mktemp"
          expected_failure=launch-identity-unread; expected_cause=scratch ;;
      esac ;;
  esac
  : > "$LANE/tmp/starts"
  # No tmux server and no --ghostty: this is the fresh local GUI route.
  launch_rc=0
  (cd -- "$LANE" && env -u TMUX -u TMUX_PANE "${GUI_ENV[@]}" \
    "$S/open-terminal" --state-dir "$LANE/tmp" --harness claude \
      --launch-flags "$GUI_FLAGS" KEN-4022) > "$LANE/tmp/launch.log" 2>&1 || launch_rc=$?
  if [[ -n "$expected_failure" ]]; then
    assert_eq "$launch_rc" 1 "$name refuses the failed startup"
    assert_eq "$(awk -v key="$expected_failure" '$1=="open-terminal:" && $2==key {print $2;exit}' "$LANE/tmp/launch.log")" "$expected_failure" "$name names its failed startup operation"
    assert_eq "$(awk -v key="$expected_failure" '$1=="open-terminal:" && $2==key {for(i=3;i<=NF;i++) if($i~/^cause=/){sub(/^cause=/,"",$i);print $i;exit}}' "$LANE/tmp/launch.log")" "$expected_cause" "$name records its specific failure cause"
    assert_eq "$(jq 'any(.lanes[]?; .status=="running")' "$LANE/tmp/workflow-state-oversee.json")" false "$name records no running lane"
    if [[ "$control" == slow ]]; then
      # This row checks the real startup timer. Terminal completion is the
      # acknowledgement that a late shell has observed its cancellation.
      deadline=$((SECONDS + 15))
      while [[ ! -s "$LANE/tmp/terminal.done" ]]; do
        [[ "$SECONDS" -lt "$deadline" ]] || exit 1
        sleep 0.05
      done
    fi
    assert_eq "$(wc -l < "$LANE/tmp/starts" | tr -d ' ')" 0 "$name starts no untracked harness"
    continue
  fi
  assert_eq "$launch_rc" 0 "$name starts its initial GUI lane"
  deadline=$((SECONDS + 15))
  while [[ ! -s "$LANE/tmp/harness.pid" ]]; do
    [[ "$SECONDS" -lt "$deadline" ]] || { cat "$LANE/tmp/launch.log"; exit 1; }
    sleep 0.05
  done
  read -r pid < "$LANE/tmp/harness.pid"
  session="$(awk 'prev=="--session-id" { print; exit } {prev=$0}' "$LANE/tmp/fresh.argv")"
  [[ -n "$session" ]] || session=old-native-session
  if [[ "$control" == early ]]; then
    control_failures="$(FAIL=0; startup_contract "$LANE/tmp" "$pid" 'the initial harness' > "$LANE/tmp/control.log"; printf '%s' "$FAIL")"
    assert_eq "$control_failures" 1 'control: the startup assertion rejects a harness run before the ready barrier'
    continue
  fi
  if [[ "$control" != old ]]; then
    startup_contract "$LANE/tmp" "$pid" 'the initial harness'
    assert_eq "$(jq -r --arg s "$session" '.lanes[0] | [.session_id==$s, .launch.pid!=null, .launch.start!=null, .launch.pane==null, .surface=="gui"] | all' "$LANE/tmp/workflow-state-oversee.json")" true 'fresh GUI records its native session and process without a pane'
    identity="$(jq -r '.lanes[0].launch | "\(.pid) \(.start)"' "$LANE/tmp/workflow-state-oversee.json")"
    assert_eq "$(lane_harness_identity "${identity%% *}" claude | cut -d ' ' -f1)" "$pid" 'the recorded process owns the launched harness'
  fi
  install_hook "$REPO_ROOT/hooks/lane-mail-model-switch.sh" "$LANE/.claude/hooks/lane-mail-model-switch.sh"
  CALL_ENV=("${GUI_ENV[@]}" ORCH_MODEL_RECOVERY_LIMIT=3)
  payload="$(jq -nc --arg s "$session" '{hook_event_name:"PostModelSwitch",session_id:$s,to_model:"claude-sonnet-4-6"}')"
  run_payload "$payload"
  state="$LANE/tmp/workflow-state-oversee.json"
  if [[ "$control" != old ]]; then
    deadline=$((SECONDS + 15))
    while [[ "$(jq -r '.fleet_log[]? | select(.kind=="model-switched") | .recovery // "starting"' "$state")" == starting ]]; do
      [[ "$SECONDS" -lt "$deadline" ]] || { cat "$LANE/tmp/model-recovery-KEN-4022.log"; exit 1; }
      sleep 0.05
    done
    if [[ "$control" == current ]]; then
      while [[ "$(wc -l < "$LANE/tmp/starts" | tr -d ' ')" != 2 ]]; do
        [[ "$SECONDS" -lt "$deadline" ]] || { cat "$LANE/tmp/model-recovery-KEN-4022.log" "$LANE/tmp/terminal.log"; exit 1; }
        sleep 0.05
      done
    fi
    run_payload "$payload"
    if [[ "$control" == current ]]; then
      recovery_contract "$state" "$LANE/tmp/fresh.argv" "$LANE/tmp/starts"
      assert_eq "$(jq -r '.fleet_log[] | select(.kind=="model-switched") | .recovery' "$state")" replaced 'recovery confirms the real replacement launch'
    else
      control_failures="$(FAIL=0; recovery_contract "$state" "$LANE/tmp/fresh.argv" "$LANE/tmp/starts" > "$LANE/tmp/control.log"; printf '%s' "$FAIL")"
      assert_eq "$([[ "$control_failures" -gt 0 ]] && echo detected || echo missed)" detected 'control: forcing tmux breaks the real replacement contract'
      assert_eq "$(jq -r '.fleet_log[] | select(.kind=="model-switched") | .recovery' "$state")" failed 'the real launcher refuses the forced tmux route'
    fi
    process_state="$(lane_process_state "$pid")"
    case "$process_state" in ''|Z) process_state=stopped ;; esac
    assert_eq "$process_state" stopped 'recovery stops the launched GUI harness'
  else
    assert_eq "$(jq -r --arg s "$session" '.model_checks[$s].cause' "$LANE/tmp/workflow-state-KEN-4022.json")" launch-unbound 'old production reports unavailable'
    control_failures="$(FAIL=0; recovery_contract "$state" "$LANE/tmp/fresh.argv" "$LANE/tmp/starts" > "$LANE/tmp/control.log"; printf '%s' "$FAIL")"
    assert_eq "$([[ "$control_failures" -gt 0 ]] && echo detected || echo missed)" detected 'control: old launch binding fails the recovery contract'
    assert_eq "$(wc -l < "$LANE/tmp/starts" | tr -d ' ')" 1 'old production starts no replacement'
  fi
done <<'ROWS'
fresh-gui|current
old-gui|old
forced-tmux|tmux
early-harness|early
late-terminal|slow
uuid-failed|uuid
git-dir-failed|git
scratch-failed|scratch
ROWS

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
