#!/usr/bin/env bash
# Surface: open-terminal's replacement of a fleet lane record.
# Inputs: scripts/open-terminal, scripts/lib/, scripts/workflow-state and
# lib/open-terminal-hosted-world.sh with its shared launch fixtures.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
TMP_ROOT="$(mktemp -d)" || { echo "open-terminal-cloud-archive: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "open-terminal-cloud-archive: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "open-terminal-cloud-archive: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
source "$(dirname "${BASH_SOURCE[0]}")/lib/open-terminal-hosted-world.sh"

WS="$SCRIPTS_DIR/workflow-state"
STATE="$TMP_ROOT/fleet"
CLOUD_ACCOUNT="$H/.9claude"
# Daytona uses the ssh host kind. The provider fixture supplies its file and
# launch verbs without a live sandbox.
HOST_STUB="$TMP_ROOT/lane-host-daytona"
ln -s "$TEST_DIR/fixtures/lane-host" "$HOST_STUB"

replace_lane() { # KIND MODE
  local args=()
  [[ "$2" != relaunch ]] || args+=(--relaunch)
  "$WS" --state-dir "$STATE" init oversee >/dev/null || exit 1
  "$WS" --state-dir "$STATE" update oversee --arg kind "$1" --arg account "$CLOUD_ACCOUNT" \
    --arg host "$HOST_STUB" --arg landing_account "$H/.eclaude" \
    '.fleet_log = [] | .lanes = [{item: "KEN-1", tracker: "linear", harness: "claude",
      kind: $kind, host: (if $kind == "claude-cloud" then "claude-cloud" else $host end),
      session_id: (if $kind == "claude-cloud" then "session_01CLOUD" else null end),
      account: (if $kind == "claude-cloud" then $account else $landing_account end),
      status: "running", launched_at: "2026-10-01T00:00:00Z"}]' >/dev/null || exit 1
  run_ot "$HARNESS_UP;$CHOICE;LANE_HOST_STUB_SELECTION=fresh" --state-dir "$STATE" \
    --host "$HOST_STUB" --harness claude --lane "$H/.eclaude" --repo o/r \
    ${args[@]+"${args[@]}"} KEN-1
}

# This is the archive read from schemas/workflow-state.md, Recording policy.
archive_read() {
  "$WS" --state-dir "$STATE" get oversee \
    '[.fleet_log[] | select(.kind == "close") | .text | capture("session=(?<session>[^ ]+) account=(?<account>[^ ]+)")]
     | group_by(.account)[] | "\(.[0].account) \(map(.session) | join(" "))"'
}
assert_archived() {
  assert_eq "$(archive_read)" "$CLOUD_ACCOUNT session_01CLOUD" \
    'the archive lists the replaced cloud session with its account'
}

while IFS='|' read -r kind mode rows; do
  replace_lane "$kind" "$mode"
  printf '%s\n' "$OUT" > "$RUN/launch.out"
  assert_eq "$RC" 0 "$kind $mode completes the landing launch" "$RUN/launch.out"
  assert_eq "$("$WS" --state-dir "$STATE" get oversee '.lanes[0] | [.kind, .account] | join(" ")')" \
    "ssh $H/.eclaude" "$kind $mode replaces the cloud launch fields"
  assert_eq "$("$WS" --state-dir "$STATE" get oversee '[.fleet_log[] | select(.kind == "close" and .item == "KEN-1")] | length')" \
    "$rows" "$kind $mode writes only the cloud predecessor's close row"
  if [[ "$kind" == claude-cloud ]]; then
    assert_archived
  else
    assert_eq "$(archive_read)" '' 'a Daytona relaunch adds no archived cloud session'
  fi
done <<'ROWS'
claude-cloud|launch|1
claude-cloud|relaunch|1
ssh|relaunch|0
ROWS

OPEN_TERMINAL="$(mutant_scripts cloud-close-control/orch open-terminal)/open-terminal" || exit 1
orch_fixture_shared_libs "$TMP_ROOT/cloud-close-control/orch"
mutate_file "$OPEN_TERMINAL" '  if [[ "$mode" != wake ]]; then' '  if [[ "$mode" != wake ]] && false; then'
replace_lane claude-cloud relaunch
assert_eq "$RC" 0 'control: the unchanged landing route still launches'
assert_eq "$(archive_read)" '' 'control: the missing close row leaves the archive empty'
CONTROL_FAILURES="$(FAIL=0; assert_archived > "$TMP_ROOT/archive-control.out"; printf '%s' "$FAIL")"
assert_eq "$CONTROL_FAILURES" 1 'control: the archive assertion rejects the lost session'

lane_suite_end
