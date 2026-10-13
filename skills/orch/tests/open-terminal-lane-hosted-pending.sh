#!/usr/bin/env bash
# Tests for the hosted pending launch contract.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
# Physical: on macOS the temp root sits under /var -> /private/var, and the
# scripts print the resolved path.
TMP_ROOT="$(mktemp -d)" || { echo "open-terminal-lane-hosted: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "open-terminal-lane-hosted: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "open-terminal-lane-hosted: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
# shellcheck source=lib/open-terminal-hosted-world.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/open-terminal-hosted-world.sh"


# An accepted create is durable even when the next dispatcher call is busy.
# This provider logs create once, then refuses repeated create as item-owned.
# Its one busy call models the dispatcher's 69 without a provider effect.
PENDING_PROVIDER="$TMP_ROOT/pending-provider"
cat > "$PENDING_PROVIDER" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == create ]]; then
  [[ ! -f "$PENDING_CREATED" ]] || exit 75
  : > "$PENDING_CREATED"
  "$PENDING_STUB" "$@"
  exit "$PENDING_CREATE_EXIT"
elif [[ "$1" == "$PENDING_BUSY_VERB" && ! -f "$PENDING_BUSY" ]]; then
  : > "$PENDING_BUSY"
  exit 69
fi
exec "$PENDING_STUB" "$@"
STUB
chmod +x "$PENDING_PROVIDER"
pending_launch_case() { # NAME STEP CREATE_EXIT [fleet]
  local name="$1" step="$2" code="$3" line state env_list record_path pending_query prepare_query
  local fleet_args=()
  state="$TMP_ROOT/pending-$name"
  mkdir -p "$state"
  record_path="$state/workflow-state-KEN-3241.json"
  prepare_query='.host_launch.status + ":" + .host_launch.step'
  pending_query='has("host_launch")'
  if [[ "${4:-}" == fleet ]]; then
    fleet_args=(--state-dir "$state")
    record_path="$state/workflow-state-oversee.json"
    prepare_query='.lanes[0].status + ":" + .lanes[0].prepare.step'
    pending_query='any(.lanes[]; .status == "preparing")'
  fi
  line=$'ssh-target=lane.example\tpath=/srv/lane\tremote-prefix=exec bash -lc'
  [[ "$step" != wait && "$code" != 75 ]] || line+=$'\tstate=preparing'
  env_list="ORCH_STATE_DIR=$state;ORCH_LANE_ALIASES=eclaude=work;PENDING_STUB=$HOST_STUB;PENDING_CREATED=$state/created;PENDING_BUSY=$state/busy;PENDING_CREATE_EXIT=$code;PENDING_BUSY_VERB=$([[ "$step" == wait ]] && echo wait || echo cat);LANE_HOST_STUB_CREATE_LINE=$line;LANE_HOST_STUB_LOG=$state/calls;$CHOICE_CMD"
  [[ "${4:-}" != fleet ]] || env_list+=" $COMPACTION_OFF_ALL;ORCH_OVERSEER_LANES=1"
  run_ot "$env_list" ${fleet_args[@]+"${fleet_args[@]}"} --host "$PENDING_PROVIDER" --harness claude --lane "$H/.eclaude" --repo o/r KEN-3241
  assert_eq "rc=$RC record=$(jq -r "$prepare_query" "$record_path") preparing=$(grep -c 'preparing=1' <<<"$OUT" || true) failed=$(grep -c 'failed=0' <<<"$OUT" || true)" \
    "rc=0 record=preparing:$step preparing=1 failed=1" "busy $step after create $code keeps the pending launch"
  if [[ "${4:-}" == fleet ]]; then
    run_ot "$env_list" "${fleet_args[@]}" --host "$PENDING_PROVIDER" --harness claude --lane "$H/.eclaude" --repo o/r KEN-3242
    assert_eq "rc=$RC creates=$(grep -c '^create ' "$state/calls") refused=$(awk '$2 == "cap-reached" { print $3 }' <<<"$OUT")" \
      "rc=1 creates=1 refused=item=KEN-3242" "another item cannot consume the full fleet's saved slot"
  fi
  if [[ "${5:-}" == defer ]]; then
    PENDING_CASE_ENV="$env_list" PENDING_CASE_STATE="$state"
    return 0
  fi
  run_ot "$env_list" ${fleet_args[@]+"${fleet_args[@]}"} --host "$PENDING_PROVIDER" --harness claude --lane "$H/.eclaude" --repo o/r KEN-3241
  [[ "$name" != control && "$name" != cap-control ]] || return 0
  assert_eq "rc=$RC creates=$(grep -c '^create ' "$state/calls") waits=$(grep -c '^wait ' "$state/calls" || true) pending=$(jq "$pending_query" "$record_path") launched=$(typed "clear; ssh 'lane.example'")" \
    "rc=0 creates=1 waits=$([[ "$step" == wait || "$code" == 75 ]] && echo 1 || echo 0) pending=false launched=1" "the next $step launch reuses the accepted sandbox from create $code"
}
while IFS='|' read -r step code; do
  pending_launch_case "$step-$code" "$step" "$code"
done <<'ROWS'
wait|0
wait|75
marker|0
marker|75
ROWS
pending_launch_case fleet-marker marker 0 fleet
# Remove only the saved-line read in a disposable script. The second create
# is then refused 75, and the retry cannot reach wait or launch the sandbox.
PENDING_OT_SHIPPED="$OPEN_TERMINAL"
OPEN_TERMINAL="$(mutant_scripts ctl-pending-resume/orch open-terminal)/open-terminal" || exit 1
orch_fixture_shared_libs "$TMP_ROOT/ctl-pending-resume/orch"
mutate_file "$OPEN_TERMINAL" '    host_launch_resume || { failed=$((failed + 1)); continue; }' '    host_line=""'
pending_launch_case control wait 0
control_launched="$(typed "clear; ssh 'lane.example'")"
assert_eq "creates=$(grep -c '^create ' "$TMP_ROOT/pending-control/calls") waits=$(grep -c '^wait ' "$TMP_ROOT/pending-control/calls" || true) pending=$(jq 'has("host_launch")' "$TMP_ROOT/pending-control/workflow-state-KEN-3241.json") launched=${control_launched:-0}" \
  "creates=1 waits=0 pending=true launched=0" "control: ignoring the saved line skips the owned sandbox before wait"
OPEN_TERMINAL="$PENDING_OT_SHIPPED"

PENDING_OT_SHIPPED="$OPEN_TERMINAL"
OPEN_TERMINAL="$(mutant_scripts ctl-pending-cap/orch open-terminal)/open-terminal" || exit 1
orch_fixture_shared_libs "$TMP_ROOT/ctl-pending-cap/orch"
rm "${OPEN_TERMINAL%/*}/lib/lane-cap.sh"
cp "$SCRIPTS_DIR/lib/lane-cap.sh" "${OPEN_TERMINAL%/*}/lib/lane-cap.sh"
mutate_file "${OPEN_TERMINAL%/*}/lib/lane-cap.sh" '( "$RELAUNCH" == true || -n "$host_line" )' '"$RELAUNCH" == true'
pending_launch_case cap-control marker 0 fleet
assert_eq "rc=$RC refused=$(awk '$2 == "cap-reached" { print $3 }' <<<"$OUT")" "rc=1 refused=item=KEN-3241" \
  "control: a cap that admits only relaunch blocks continuation of its own preparation"
OPEN_TERMINAL="$PENDING_OT_SHIPPED"

IDENTITY_OT_SHIPPED="$OPEN_TERMINAL"
IDENTITY_OT="$(mutant_scripts ctl-pending-identity/orch open-terminal)/open-terminal" || exit 1
orch_fixture_shared_libs "$TMP_ROOT/ctl-pending-identity/orch"
mutate_file "$IDENTITY_OT" '.host == $host and .account == $account and .harness == $harness and .relaunch == $relaunch' 'true'
while IFS='|' read -r identity harness lane relaunch; do
  pending_launch_case "identity-$identity" marker 0 '' defer
  retry_args=()
  [[ "$relaunch" != true ]] || retry_args=(--relaunch)
  identity_env="$PENDING_CASE_ENV"
  [[ "$harness" != codex ]] || identity_env+=';cmd=true -m gpt-6-astra -c model_reasoning_effort=high'
  run_ot "$identity_env" --host "$PENDING_PROVIDER" --harness "$harness" --lane "$lane" --repo o/r ${retry_args[@]+"${retry_args[@]}"} KEN-3241
  assert_eq "rc=$RC creates=$(grep -c '^create ' "$PENDING_CASE_STATE/calls") pending=$(jq 'has("host_launch")' "$PENDING_CASE_STATE/workflow-state-KEN-3241.json") mismatch=$(awk '$2 == "host-launch-mismatch" { print $3 }' <<<"$OUT")" \
    "rc=1 creates=1 pending=true mismatch=item=KEN-3241" "a changed $identity cannot use the accepted launch identity"
  OPEN_TERMINAL="$IDENTITY_OT"
  run_ot "$identity_env" --host "$PENDING_PROVIDER" --harness "$harness" --lane "$lane" --repo o/r ${retry_args[@]+"${retry_args[@]}"} KEN-3241
  assert_eq "rc=$RC pending=$(jq 'has("host_launch")' "$PENDING_CASE_STATE/workflow-state-KEN-3241.json")" "rc=0 pending=false" \
    "control: dropping identity validation permits a different $identity"
  OPEN_TERMINAL="$IDENTITY_OT_SHIPPED"
done <<ROWS
account|claude|$H/.claude|false
harness|codex|$H/.eclaude|false
relaunch|claude|$H/.eclaude|true
ROWS

terminal_case() { # NAME STEP [CONTROL]
  local name="$1" step="$2" failure
  pending_launch_case "$name" "$step" 0 '' defer
  if [[ "$step" == wait ]]; then failure=LANE_HOST_STUB_WAIT_STATUS=1
  else failure='LANE_HOST_STUB_CAT_STATUS=1;LANE_HOST_STUB_CAT_PATH=/srv/lane/.git'; fi
  run_ot "$PENDING_CASE_ENV;$failure" --host "$PENDING_PROVIDER" --harness claude --lane "$H/.eclaude" --repo o/r KEN-3241
  TERMINAL_RESULT="rc=$RC creates=$(grep -c '^create ' "$PENDING_CASE_STATE/calls") pending=$(jq 'has("host_launch")' "$PENDING_CASE_STATE/workflow-state-KEN-3241.json")"
  [[ "${3:-}" == control ]] || assert_eq "$TERMINAL_RESULT" "rc=1 creates=1 pending=false" "terminal $step failure removes the saved continuation"
}
terminal_case terminal-wait wait
terminal_case terminal-marker marker
PENDING_OT_SHIPPED="$OPEN_TERMINAL"
OPEN_TERMINAL="$(mutant_scripts ctl-pending-clear/orch open-terminal)/open-terminal" || exit 1
orch_fixture_shared_libs "$TMP_ROOT/ctl-pending-clear/orch"
mutate_file "$OPEN_TERMINAL" '    "$WORKFLOW_STATE" update "$wt_id" '\''del(.host_launch)'\'' >/dev/null' '    return 0'
terminal_case terminal-control wait control
assert_eq "$TERMINAL_RESULT" "rc=1 creates=1 pending=true" "control: skipping terminal cleanup retains an invalid continuation"
OPEN_TERMINAL="$PENDING_OT_SHIPPED"

# The real dispatcher refuses the next short call after a provider effect
# occupies its pool. The blocked call itself never reaches the provider.
RECOVERY_PROVIDER="$TMP_ROOT/recovery-provider"
cat > "$RECOVERY_PROVIDER" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == create ]]; then
  [[ ! -f "$RECOVERY_CREATED" ]] || exit 75
  : > "$RECOVERY_CREATED"
fi
rc=0
"$RECOVERY_STUB" "$@" || rc=$?
if [[ "$1" == "$RECOVERY_BLOCK_VERB" && "${4:-}" == "$RECOVERY_BLOCK_PATH" && ! -f "$RECOVERY_BLOCKED" ]]; then
  : > "$RECOVERY_BLOCKED"
  mkdir -p "$HOME/.cache/orch/lane-host-slots/short"
  : > "$HOME/.cache/orch/lane-host-slots/short/slot.$RECOVERY_OWNER"
fi
exit "$rc"
STUB
chmod +x "$RECOVERY_PROVIDER"
recovery_case() { # NAME HARNESS BLOCK_VERB BLOCK_PATH STEP [CONTROL]
  local name="$1" harness="$2" verb="$3" path="$4" step="$5" state env_list first_starts retry_starts record
  state="$TMP_ROOT/recovery-$name"; mkdir -p "$state/disk/srv/lane" "$state/disk/pi/packages/@vanillagreen/pi-hooks/extensions"
  printf 'gitdir: /srv/clone/.git/worktrees/lane\n' > "$state/disk/srv/lane/.git"
  printf '%s\n' '{"compaction":{"enabled":false}}' > "$state/disk/pi/settings.json"
  printf '%s\n' '{"pi":{"extensions":["./extensions/hooks.ts","./extensions/lane-mail-wake.ts"]}}' > "$state/disk/pi/packages/@vanillagreen/pi-hooks/package.json"
  printf 'export const f = { context_window: 1 };\n' > "$state/disk/pi/packages/@vanillagreen/pi-hooks/extensions/vocab.ts"
  record="$state/workflow-state-oversee.json"
  if [[ "$name" == codex-cat* ]]; then
    jq -n '{lanes:[{item:"KEN-3241",harness:"codex",account:"previous",model:"previous-model",effort:"low",status:"stopped"}]}' >"$record"
  fi
  env_list="HOME=$state/home;ORCH_STATE_DIR=$state;ORCH_OVERSEER_LANES=1;ORCH_LANE_ALIASES=eclaude=work;RECOVERY_STUB=$HOST_STUB;RECOVERY_CREATED=$state/created;RECOVERY_BLOCKED=$state/blocked;RECOVERY_OWNER=$$;RECOVERY_BLOCK_VERB=$verb;RECOVERY_BLOCK_PATH=$path;ORCH_LANE_HOST_SHORT_MAX_CALLS=1;ORCH_LANE_HOST_SHORT_BUSY_WAIT_SECS=0;LANE_HOST_STUB_LOG=$state/calls;LANE_HOST_STUB_DIR=$state/disk;LANE_HOST_STUB_SELECTION=fresh;LANE_HOST_STUB_CREATE_LINE=ssh-target=lane.example"$'\t'"path=/srv/lane"$'\t'"remote-prefix=exec bash -lc"$'\t'"pi-root=/pi;$HARNESS_UP"
  if [[ "$harness" == codex ]]; then env_list+=';flags=-m gpt-6-astra -c model_reasoning_effort=high'
  else env_list+=";ORCH_LANE_COPILOT_POOL=$H/.eclaude=1/10;flags=--model github-copilot/opus --thinking high"; fi
  run_ot "$env_list" --state-dir "$state" --host "$RECOVERY_PROVIDER" --harness "$harness" --lane "$H/.eclaude" --repo o/r --relaunch KEN-3241
  first_starts="$(typed "clear; ssh 'lane.example'")"; first_starts="${first_starts:-0}"
  assert_eq "rc=$RC step=$(jq -r '.lanes[0].prepare.step' "$record") failed=$(awk '$2 == "summary" { for (i=3;i<=NF;i++) if ($i ~ /^failed=/) print $i }' <<<"$OUT")" \
    "rc=0 step=$step failed=failed=0" "dispatcher busy during $name retains the accepted preparation"
  if [[ "$name" == codex-cat* ]]; then
    assert_eq "$(jq -r '.lanes[0] | [.account,.model,.effort] | join(":")' "$record")" \
      "$H/.eclaude:gpt-6-astra:high" 'the started selection replaces the previous launch identity'
    env_list="${env_list/flags=-m gpt-6-astra -c model_reasoning_effort=high/flags=-m gpt-6.1-sol -c model_reasoning_effort=medium}"
  fi
  rm -f "$state/home/.cache/orch/lane-host-slots/short/slot.$$"
  run_ot "$env_list" --state-dir "$state" --host "$RECOVERY_PROVIDER" --harness "$harness" --lane "$H/.eclaude" --repo o/r --relaunch KEN-3241
  retry_starts="$(typed "clear; ssh 'lane.example'")"; retry_starts="${retry_starts:-0}"
  RECOVERY_RESULT="rc=$RC creates=$(grep -c '^create ' "$state/calls") starts=$((first_starts + retry_starts)) status=$(jq -r '.lanes[0].status' "$record") pending=$(jq 'has("prepare")' <<<"$(jq '.lanes[0]' "$record")")"
  [[ "${6:-}" == control ]] || assert_eq "$RECOVERY_RESULT" "rc=0 creates=1 starts=1 status=running pending=false" "retry after $name starts one harness in the accepted sandbox"
  if [[ "$name" == codex-cat ]]; then
    assert_eq "$(jq -r '.lanes[0] | [.account,.model,.effort] | join(":")' "$record")" \
      "$H/.eclaude:gpt-6-astra:high" 'a record-only retry keeps the started model and effort despite new invocation flags'
  fi
}
while IFS='|' read -r name harness verb path step; do
  recovery_case "$name" "$harness" "$verb" "$path" "$step"
done <<'ROWS'
codex-put|codex|create|--repo|marker
codex-cat|codex|put|/srv/lane/tmp/lane-mail/KEN-3241/context.json|selection
pi-settings|pi|create|--repo|marker
pi-carrier|pi|cat|/srv/lane/.pi/settings.json|marker
ROWS

RECOVERY_OT_SHIPPED="$OPEN_TERMINAL"
OPEN_TERMINAL="$(mutant_scripts ctl-selection-step/orch open-terminal)/open-terminal" || exit 1
orch_fixture_shared_libs "$TMP_ROOT/ctl-selection-step/orch"
mutate_file "$OPEN_TERMINAL" '        host_pending_step=selection' '        host_pending_step=marker'
recovery_case selection-control codex put /srv/lane/tmp/lane-mail/KEN-3241/context.json marker control
assert_eq "$RECOVERY_RESULT" "rc=0 creates=1 starts=2 status=running pending=false" "control: losing the post-start step launches a second harness"
OPEN_TERMINAL="$RECOVERY_OT_SHIPPED"
OPEN_TERMINAL="$(mutant_scripts ctl-selection-identity/orch open-terminal)/open-terminal" || exit 1
orch_fixture_shared_libs "$TMP_ROOT/ctl-selection-identity/orch"
mutate_file "$OPEN_TERMINAL" '    LAUNCH_PREPARE="$host_pending_record"' '    LAUNCH_PREPARE=""'
recovery_case codex-cat-control codex put /srv/lane/tmp/lane-mail/KEN-3241/context.json selection control
assert_eq "$(jq -r '.lanes[0] | [.account,.model,.effort] | join(":")' "$TMP_ROOT/recovery-codex-cat-control/workflow-state-oversee.json")" \
  "$H/.eclaude:gpt-6.1-sol:medium" 'control: losing the saved identity records retry flags for the already-started harness'
OPEN_TERMINAL="$RECOVERY_OT_SHIPPED"

lane_suite_end
