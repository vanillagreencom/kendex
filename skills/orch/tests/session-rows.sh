#!/usr/bin/env bash
# Surface: session_rows_lane_write and session_rows_lane_verdict.
# Inputs: scripts/lib/session-rows.sh and mailbox's locked append library.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TMP_ROOT="$(mktemp -d)" || { echo 'session-rows: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo 'session-rows: scratch=not-a-directory' >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo 'session-rows: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
PASS=0 FAIL=0
source "$TEST_DIR/lib/assertions.sh"
source "$TEST_DIR/lib/growth-state.sh"
source "$REPO_ROOT/skills/mailbox/scripts/lib/file-lock.sh"
source "$REPO_ROOT/skills/mailbox/scripts/lib/mailbox-append.sh"
source "$REPO_ROOT/skills/orch/scripts/lib/session-rows.sh"
# Stop error rows keep the existing account-limit judgement.
source "$REPO_ROOT/skills/orch/scripts/lib/lane-state.sh"

rows() {
  local payload want count got rc shape transcript reason
  mkdir -p "$TMP_ROOT/box"
  # The Pi usage-limit message also used by lane-state.sh, in Pi's transcript form.
  printf '%s\n' '{"type":"message","message":{"role":"assistant","stopReason":"error","errorMessage":"429 Usage limit reached for this model"}}' > "$TMP_ROOT/limit.jsonl"
  while IFS='|' read -r payload count shape want; do
    transcript="" reason=absent
    if [ "$shape" = limit ]; then
      transcript="$TMP_ROOT/limit.jsonl" reason=error
    fi
    rm -f -- "$TMP_ROOT/box/session-rows.jsonl"
    session_rows_lane_write "$TMP_ROOT/box" pi Stop "$transcript" "$payload"
    rc=0
    session_rows_lane_verdict "$TMP_ROOT/box/session-rows.jsonl" || rc=$?
    got="$(jq -r 'if has("working_agents") then (.working_agents | tojson) else "absent" end' "$TMP_ROOT/box/session-rows.jsonl")"
    assert_eq "count=$got reason=$(jq -r '.stop_reason // "absent"' "$TMP_ROOT/box/session-rows.jsonl") verdict=$SESSION_ROWS_VERDICT rc=$rc" \
      "count=$count reason=$reason $want" "Stop $shape count $count"
  done <<'ROWS'
{"working_agents":1}|1|normal|verdict=working rc=0
{"working_agents":0}|0|normal|verdict=idle rc=0
{}|absent|normal|verdict=idle rc=0
{"working_agents":null}|null|normal|verdict=none rc=2
{"working_agents":1}|1|limit|verdict=working rc=0
{"working_agents":null}|null|limit|verdict=none rc=2
{"working_agents":0}|0|limit|verdict=walled rc=0
ROWS
  session_rows_lane_write "$TMP_ROOT/box" pi Stop "" '{"working_agents":1}'
  session_rows_lane_write "$TMP_ROOT/box" pi PreToolUse
  session_rows_lane_verdict "$TMP_ROOT/box/session-rows.jsonl"
  assert_eq "$SESSION_ROWS_VERDICT" working 'a later tool row keeps the lead working'
  session_rows_lane_write "$TMP_ROOT/box" pi Stop "" '{"working_agents":0}'
  session_rows_lane_verdict "$TMP_ROOT/box/session-rows.jsonl"
  assert_eq "$SESSION_ROWS_VERDICT" idle 'the last child report and lead settle end the working state'
}
rows

control() { # NAME OLD NEW FAILED-ROW...
  local log rc=0 failed_row
  cp "$REPO_ROOT/skills/orch/scripts/lib/session-rows.sh" "$TMP_ROOT/$1.sh"
  mutate_file "$TMP_ROOT/$1.sh" "$2" "$3"
  log="$(
    source "$TMP_ROOT/$1.sh"
    PASS=0 FAIL=0
    rows
    [[ "$FAIL" -eq 0 ]]
  )" || rc=$?
  assert_eq "$rc" 1 "control $1 rejects the changed result"
  for failed_row in "${@:4}"; do
    assert_eq "$(grep -Fxc "  FAIL  $failed_row" <<<"$log" || true)" 1 "control $1 reaches $failed_row"
  done
}
control idle 'if [ "$fields" -gt 0 ]; then' 'if false && [ "$fields" -gt 0 ]; then' 'Stop normal count 1'
control no-count 'then {working_agents: $payload.working_agents} else {} end)' 'then ({working_agents: $payload.working_agents} | del(.working_agents)) else {} end)' 'Stop normal count 1'
control unknown '[ "$fields" != unknown ] || return 2' '[ "$fields" != unknown ] || return 0' 'Stop normal count null'
control error-skips-count 'if [ "$has_count" = true ]; then' \
  'if [ "$has_count" = true ] && [ "$(jq -r '\''.stop_reason // ""'\'' <<<"$SESSION_ROW")" != error ]; then' \
  'Stop limit count 1' 'Stop limit count null'
printf '\npass: %s fail: %s\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
