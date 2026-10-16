#!/usr/bin/env bash
# Surface: lane_model_recovery's consecutive successful replacement bound.
# Inputs: skills/orch/scripts/** skills/github/scripts/lib/** skills/mailbox/scripts/** skills/orch/tests/fixtures/lane-model-recovery-base.sh
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
TEST_DIR="$(cd -- "${BASH_SOURCE[0]%/*}" && pwd -P)"
source "$TEST_DIR/lib/assertions.sh"
source "$TEST_DIR/lib/shared-skill-libs.sh"
TMP_ROOT="$(mktemp -d)" || { echo 'lane_model_recovery: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo 'lane_model_recovery: scratch=not-a-directory' >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo 'lane_model_recovery: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
S="$TMP_ROOT/orch/scripts"
mkdir -p "$S"
cp -R -- "$TEST_DIR/../scripts/." "$S/"
orch_fixture_shared_libs "$TMP_ROOT/orch"
cat > "$S/lane-host" <<'HOST'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  capabilities) printf 'kind=ssh\tlaunch=ssh\tchannel=mailbox\tfiles=verb\tstatus=verb\tstop=verb\trelaunch=resume\tpark=none\taccounts=none\tpool=plan\tland=lane\n' ;;
  stop) printf 'stopped item=%s processes=1\n' "$3" ;;
  *) exit 2 ;;
esac
HOST
cat > "$S/open-terminal" <<'LAUNCH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' launched >> "$MODEL_STARTS"
exit "${MODEL_LAUNCH_EXIT:-0}"
LAUNCH
chmod +x "$S/lane-host" "$S/open-terminal"

run_recovery() { # [BASE FUNCTION]
  RC=0
  env ORCH_MODEL_RECOVERY_LIMIT="$BOUND" MODEL_STARTS="$CASE/starts" MODEL_LAUNCH_EXIT="$LAUNCH_EXIT" \
    "$BASH" -euo pipefail -c '
      cd -- "$1"
      . "$2/lib/lane-state.sh"
      . "$2/lib/lane-launch.sh"
      . "$2/lib/lane-capabilities.sh"
      . "$2/lib/lane-relaunch.sh"
      [[ -z "$4" ]] || . "$4"
      lane_model_recovery "$3" "$1" "$2" current
    ' _ "$CASE" "$S" "$RECORD" "${1:-}" > "$CASE/out" 2> "$CASE/err" || RC=$?
}

# Each row uses the same real dispatcher, fleet-state lock and launch boundary.
# A starting predecessor has already produced the current live mismatch.
while IFS='|' read -r NAME PRIOR BOUND LAUNCH_EXIT WANT; do
  CASE="$TMP_ROOT/$NAME"
  mkdir -p "$CASE"
  : > "$CASE/starts"
  RECORD="$(jq -nc --arg cwd "$CASE" --arg host "$S/lane-host" '
    {item:"KEN-4033",harness:"claude",session_id:"current",model:"claude-fable-5-1",
     effort:"high",status:"running",tracker:"linear",host:$host,launched_at:"original",
     launch:{pane:"%current",server:1},recovery:{cwd:$cwd,flags:"--model claude-fable-5-1 --effort high",refresh:false,session:"test"}}')"
  "$S/workflow-state" --state-dir "$CASE" init oversee >/dev/null
  "$S/workflow-state" --state-dir "$CASE" update oversee '
    ($r | {launch,launched_at}) as $identity
    | .lanes=[$r + {model_check:{session_id:"current",outcome:"switched",launch_identity:$identity}}]
    | .fleet_log=($prior | split(",") | to_entries | map(
        if .value == "reset" then {kind:"model-recovery-reset",item:"KEN-4033"}
        elif .value == "other" then {kind:"model-switched",item:"KEN-other",recovery:"replaced"}
        elif .value == "unavailable" then {kind:"model-unavailable",item:"KEN-4033"}
        elif .value == "" then empty
        else {kind:"model-switched",item:"KEN-4033",recovery:.value,launch_identity:{launch:{pane:(.key|tostring)},launched_at:"original"}} end))
      + [{kind:"model-switched",item:"KEN-4033",session_id:"current",launch_identity:$identity}]
    ' --argjson r "$RECORD" --arg prior "$PRIOR" >/dev/null
  run_recovery
  GOT="$RC|$(wc -l < "$CASE/starts" | tr -d ' ')|$(jq '[.fleet_log[] | select(.kind=="model-recovery-limit")]|length' "$CASE/workflow-state-oversee.json")"
  assert_eq "$GOT" "$WANT" "$NAME replacement and refusal result"
  if [[ "$RC" -eq 0 ]]; then
    assert_eq "$(jq -r '.fleet_log[-1].recovery' "$CASE/workflow-state-oversee.json")" replaced "$NAME records a successful replacement"
  elif [[ "$NAME" != launch-failed ]]; then
    # The model-recovery log and fleet row are the issue's accepted report channels.
    KEY="$(sed -n '1s/ item=.*//p' "$CASE/err")"
    assert_eq "$KEY" 'lane-relaunch: model-recovery=limit' "$NAME emits the keyed refusal"
    assert_eq "$(jq -r '.fleet_log[-1] | [.recoveries,.limit]|join("|")' "$CASE/workflow-state-oversee.json")" '2|3' "$NAME records the bound and successful replacements"
    run_recovery
    assert_eq "$(jq '[.fleet_log[] | select(.kind=="model-recovery-limit")]|length' "$CASE/workflow-state-oversee.json")" 1 "$NAME duplicate adds no refusal row"
    assert_eq "$RC" 0 "$NAME duplicate is already claimed"
    if [[ "$NAME" == nth ]]; then
      "$S/workflow-state" --state-dir "$CASE" update oversee 'del(.lanes[0].model_check.recovery_started)' >/dev/null
      run_recovery "$TEST_DIR/fixtures/lane-model-recovery-base.sh"
      assert_eq "$RC|$(wc -l < "$CASE/starts" | tr -d ' ')" '0|1' 'base control starts the refused Nth replacement'
    fi
  else
    assert_eq "$(jq -r '.fleet_log[-1].recovery' "$CASE/workflow-state-oversee.json")" failed 'a failed launch is not a successful replacement'
  fi
done <<'ROWS'
first||3|0|0|1|0
n-minus-one|replaced|3|0|0|1|0
nth|replaced,replaced|3|0|1|0|1
pending-predecessor|replaced,starting|3|0|1|0|1
reset|replaced,replaced,reset|3|0|0|1|0
other-item|replaced,other|3|0|0|1|0
failed-prior|replaced,failed,unavailable|3|0|0|1|0
launch-failed||3|7|7|1|0
ROWS

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
