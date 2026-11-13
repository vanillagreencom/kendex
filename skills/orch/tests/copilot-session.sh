#!/usr/bin/env bash
# Tests for the Copilot session record's writer, copilot-statusline, the
# command that writes it from the JSON Copilot hands a statusLine command,
# and the account a Copilot session's record names.
# Inputs: skills/agent-runtime/, skills/agent-runtime/scripts/, skills/change-scope/references/,
# skills/change-scope/scripts/, skills/communication/references/reports.md, skills/mailbox/scripts/,
# skills/orch/runtime/, skills/orch/scripts/, skills/orch/tests/.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
# shellcheck source=lib/growth-state.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/growth-state.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TEST_DIR/.." && pwd)/scripts"
TMP_ROOT="$(mktemp -d)" || { echo "copilot-session: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "copilot-session: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "copilot-session: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

# shellcheck source=lib/assertions.sh
source "$TEST_DIR/lib/assertions.sh"

ACCOUNT="$TMP_ROOT/.1copilot"
SESSION=5f0c1d2e-aaaa-4bbb-8ccc-0123456789ab
TRANSCRIPT="$ACCOUNT/session-state/$SESSION/events.jsonl"
# status JSON — the object Copilot 1.0.88 hands its statusLine command.
status() {
  jq -nc --arg s "$SESSION" --arg t "$TRANSCRIPT" '{session_id: $s, transcript_path: $t,
    model: {id: "claude-opus-5"},
    context_window: {used_percentage: 41.6, current_context_tokens: 416000, context_window_size: 1000000},
    ai_used: {total_nano_aiu: 2581100000000}, cost: {total_premium_requests: 3}, allow_all_enabled: true}'
}

# statusline NAME [SCRIPTS] < JSON — run the command under ACCOUNT; OUT, ERR, RC.
statusline() {
  local rc=0
  OUT="$(env -i GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" PATH="$PATH" HOME="$TMP_ROOT" COPILOT_HOME="$ACCOUNT" \
    "${2:-$SCRIPTS_DIR}/copilot-statusline" 2>"$TMP_ROOT/$1.err")" || rc=$?
  RC="$rc"
  ERR="$(cat "$TMP_ROOT/$1.err")"
}
RECORD="$ACCOUNT/lane-status/$SESSION.json"

echo "=== copilot-statusline writes the record and prints the footer ==="
statusline write <<<"$(status)"
assert_eq "$RC|$OUT" "0|claude-opus-5 42% ctx 2581.10 AIC" "the footer names the model, the rounded share and the credits"
assert_eq "$(jq -c --arg s "$(status)" '[.session_id, .transcript_path, .copilot_home, (.written_at | type), .status == ($s | fromjson)]' "$RECORD")" \
  "[\"$SESSION\",\"$TRANSCRIPT\",\"$ACCOUNT\",\"number\",true]" \
  "the record binds the session, its transcript and the account, and keeps the CLI's object whole"
assert_eq "$(stat -c %a "$ACCOUNT/lane-status" 2>/dev/null || stat -f %Lp "$ACCOUNT/lane-status")" 700 \
  "the record directory is private"
WRITTEN="$(jq -r '.written_at' "$RECORD")"
while IFS='|' read -r label input want; do
  statusline refuse <<<"$input"
  assert_eq "$RC|$(head -n1 <<<"$ERR")" "$want" "$label"
done <<'ROWS'
stdin that is not an object is refused|[1,2]|1|copilot-statusline: payload=invalid-json
stdin that is not JSON is refused|not json|1|copilot-statusline: payload=invalid-json
an object naming no session is refused|{"model":{"id":"m"}}|1|copilot-statusline: payload=unbound
a session id outside the id alphabet is refused, never a path|{"session_id":"../escape"}|1|copilot-statusline: payload=unbound
a session id that is not a string is refused|{"session_id":7}|1|copilot-statusline: payload=unbound
ROWS
assert_eq "$(find "$ACCOUNT" -name '*.json' | wc -l | tr -d ' ')" 1 "no refused payload wrote a record"
statusline sparse <<<'{"session_id":"sparse-1"}'
assert_eq "$RC|$OUT" "0|- -% ctx - AIC" "a payload with no figures writes a record and shows dashes, defaulting nothing"

echo "=== a copilot session's account ==="
assert_eq "$(bash -c '. "$1/lib/lane-context.sh"; COPILOT_HOME= LANES_HOME=/h lane_context_caller_cfg copilot; COPILOT_HOME=/a lane_context_caller_cfg copilot' _ "$SCRIPTS_DIR")" \
  $'/h/.copilot\n/a' "a copilot session's account is COPILOT_HOME, else the CLI's default home"

echo "=== must-fail controls ==="
# The writer's control, in a private copy of the scripts.
lib_control() { # NAME FILE OLD NEW — a copy in LIB with one site cut
  LIB="$(mutant_scripts "$1" "$2")" || exit 1
  mutate_file "$LIB/$2" "$3" "$4"
}
lib_control ctl-write lib/copilot-session.sh '       status: .}' '       status: {}}'
statusline ctl-write "$LIB" <<<"$(status)"
assert_eq "$(jq -c --arg s "$(status)" '.status == ($s | fromjson)' "$RECORD")" false \
  "control: a writer that drops the CLI's object no longer keeps it whole"
LIB=""

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
