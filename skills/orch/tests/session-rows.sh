#!/usr/bin/env bash
# Surface: session_rows_lane_write.
# Inputs: skills/agent-runtime/, skills/agent-runtime/scripts/, skills/change-scope/references/,
# skills/change-scope/scripts/, skills/communication/references/reports.md, skills/mailbox/scripts/,
# skills/orch/runtime/, skills/orch/scripts/, skills/orch/tests/.
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

rows() {
  local payload count got shape transcript reason file="$TMP_ROOT/box/session-rows.jsonl"
  mkdir -p "$TMP_ROOT/box"
  # A Pi usage-limit message, in Pi's transcript form.
  printf '%s\n' '{"type":"message","message":{"role":"assistant","stopReason":"error","errorMessage":"429 Usage limit reached for this model"}}' > "$TMP_ROOT/limit.jsonl"
  while IFS='|' read -r payload count shape; do
    transcript="" reason=absent
    if [ "$shape" = limit ]; then
      transcript="$TMP_ROOT/limit.jsonl" reason=error
    fi
    rm -f -- "$file"
    session_rows_lane_write "$TMP_ROOT/box" pi Stop "$transcript" "$payload"
    got="$(jq -r 'if has("working_agents") then (.working_agents | tojson) else "absent" end' "$file")"
    assert_eq "count=$got reason=$(jq -r '.stop_reason // "absent"' "$file")" \
      "count=$count reason=$reason" "Stop $shape count $count"
  done <<'ROWS'
{"working_agents":1}|1|normal
{"working_agents":0}|0|normal
{}|absent|normal
{"working_agents":null}|null|normal
{"working_agents":1}|1|limit
{"working_agents":null}|null|limit
{"working_agents":0}|0|limit
ROWS
  session_rows_lane_write "$TMP_ROOT/box" pi Stop "" '{"working_agents":1}'
  session_rows_lane_write "$TMP_ROOT/box" pi PreToolUse
  assert_eq "$(jq -rs 'last | .event' "$file")" PreToolUse 'a tool row follows a working Stop'
  session_rows_lane_write "$TMP_ROOT/box" pi Stop "" '{"working_agents":0}'
  assert_eq "$(jq -cs 'last | [.event, .working_agents]' "$file")" '["Stop",0]' 'the lead settle ends the turn'
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
control no-count 'then {working_agents: $payload.working_agents} else {} end)' 'then ({working_agents: $payload.working_agents} | del(.working_agents)) else {} end)' 'Stop normal count 1'
printf '\npass: %s fail: %s\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
