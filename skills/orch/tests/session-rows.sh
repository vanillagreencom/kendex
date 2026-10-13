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
  local payload want count got rc
  mkdir -p "$TMP_ROOT/box"
  while IFS='|' read -r payload count want; do
    rm -f -- "$TMP_ROOT/box/session-rows.jsonl"
    session_rows_lane_write "$TMP_ROOT/box" pi Stop "" "$payload"
    rc=0
    session_rows_lane_verdict "$TMP_ROOT/box/session-rows.jsonl" || rc=$?
    got="$(jq -r 'if has("working_agents") then (.working_agents | tojson) else "absent" end' "$TMP_ROOT/box/session-rows.jsonl")"
    assert_eq "count=$got verdict=$SESSION_ROWS_VERDICT rc=$rc" "count=$count $want" "Stop count $count"
  done <<'ROWS'
{"working_agents":1}|1|verdict=working rc=0
{"working_agents":0}|0|verdict=idle rc=0
{}|absent|verdict=idle rc=0
{"working_agents":null}|null|verdict=none rc=2
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

control() { # NAME OLD NEW FAILED-ROW
  local log rc=0
  cp "$REPO_ROOT/skills/orch/scripts/lib/session-rows.sh" "$TMP_ROOT/$1.sh"
  mutate_file "$TMP_ROOT/$1.sh" "$2" "$3"
  log="$(
    source "$TMP_ROOT/$1.sh"
    PASS=0 FAIL=0
    rows
    [[ "$FAIL" -eq 0 ]]
  )" || rc=$?
  assert_eq "$rc" 1 "control $1 rejects the changed result"
  assert_eq "$(grep -Fxc "  FAIL  $4" <<<"$log" || true)" 1 "control $1 reaches $4"
}
control idle 'if [ "$fields" -gt 0 ]; then' 'if false && [ "$fields" -gt 0 ]; then' 'Stop count 1'
control no-count 'then {working_agents: $payload.working_agents} else {} end)' 'then ({working_agents: $payload.working_agents} | del(.working_agents)) else {} end)' 'Stop count 1'
control unknown '[ "$fields" != unknown ] || return 2' '[ "$fields" != unknown ] || return 0' 'Stop count null'
printf '\npass: %s fail: %s\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
