#!/usr/bin/env bash
# Tests for the Copilot session record: copilot-statusline, the command that
# writes it from the JSON Copilot hands a statusLine command; the reader in
# lib/copilot-session.sh that answers only where the session, account,
# transcript and freshness bindings all agree; and the copilot adapter that
# turns a record into the reading the shared context judge takes.
#
# No reader here reads the wall clock: every read is handed the time, derived
# from the stamp of the record written last, so the age rows sit exactly on the
# bound and one second past it.
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
  OUT="$(env -i PATH="$PATH" HOME="$TMP_ROOT" COPILOT_HOME="$ACCOUNT" \
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

echo "=== the reader answers only where every binding agrees ==="
# read_row HOME SESSION TRANSCRIPT NOW — `ok` or the reason, from a child shell.
read_row() {
  bash -c 'set -euo pipefail; . "$1/lib/lane-context.sh"
    if copilot_session_read "$2" "$3" "$4" "$5"; then echo ok; else echo "$COPILOT_SESSION_REASON"; fi' \
    _ "${LIB:-$SCRIPTS_DIR}" "$@"
}
MAX=120
printf 'not a record\n' > "$ACCOUNT/lane-status/broken.json"
jq -c '.session_id = "other-1"' "$RECORD" > "$ACCOUNT/lane-status/moved-1.json"
while IFS='|' read -r label home session transcript now want; do
  assert_eq "$(read_row "$home" "$session" "$transcript" "$now")" "$want" "$label"
done <<ROWS
the bound record answers|$ACCOUNT|$SESSION|$TRANSCRIPT|$WRITTEN|ok
no transcript to hold it to still answers|$ACCOUNT|$SESSION||$WRITTEN|ok
an age equal to the bound is fresh|$ACCOUNT|$SESSION|$TRANSCRIPT|$((WRITTEN + MAX))|ok
one second past the bound is stale|$ACCOUNT|$SESSION|$TRANSCRIPT|$((WRITTEN + MAX + 1))|stale
a record stamped after the reader's clock is stale|$ACCOUNT|$SESSION|$TRANSCRIPT|$((WRITTEN - 1))|stale
another transcript is refused|$ACCOUNT|$SESSION|$ACCOUNT/session-state/other/events.jsonl|$WRITTEN|wrong-transcript
a record under another account's directory is refused|$TMP_ROOT/.2copilot|$SESSION|$TRANSCRIPT|$WRITTEN|missing
a file naming another session is refused|$ACCOUNT|moved-1|$TRANSCRIPT|$WRITTEN|wrong-session
a file that is no record is unreadable|$ACCOUNT|broken|$TRANSCRIPT|$WRITTEN|unreadable
no session id is unbound|$ACCOUNT||$TRANSCRIPT|$WRITTEN|unbound
a session id outside the alphabet is unbound|$ACCOUNT|../x|$TRANSCRIPT|$WRITTEN|unbound
ROWS
mkdir -p "$TMP_ROOT/copy/lane-status"
cp "$RECORD" "$TMP_ROOT/copy/lane-status/"
assert_eq "$(read_row "$TMP_ROOT/copy" "$SESSION" "$TRANSCRIPT" "$WRITTEN")" wrong-account \
  "a record copied from another account is refused on the account it names"

echo "=== the adapter hands the shared judge tokens, the compaction point and the model ==="
# reading RECORD_JSON — lane_context_reading copilot over one record.
reading() {
  bash -c 'set -euo pipefail; . "$1/lib/lane-context.sh"; lane_context_reading copilot <<<"$2"' \
    _ "${LIB:-$SCRIPTS_DIR}" "$1"
}
while IFS='|' read -r label record want; do
  assert_eq "$(reading "$record")" "$want" "$label"
done <<ROWS
the window's 80 percent is the capacity|$(cat "$RECORD")|416000	800000	claude-opus-5
a 200K window is judged on its own point|{"status":{"model":{"id":"m"},"context_window":{"current_context_tokens":150000,"context_window_size":200000}}}|150000	160000	m
no token count is unread, never zero|{"status":{"context_window":{"context_window_size":1000000}}}|unread
a token count of another type is unread|{"status":{"context_window":{"current_context_tokens":"416000"}}}|unread
ROWS
assert_eq "$(reading '{"status":{"context_window":{"current_context_tokens":5}}}')" $'5\t\t' \
  "no window leaves the capacity empty"
# owned PATH SESSION HOME — the shared ownership gate's answer for copilot.
owned() {
  bash -c 'set -euo pipefail; . "$1/lib/lane-context.sh"; rc=0
    lane_context_transcript_owned copilot "$2" "$3" "$4" || rc=$?; echo "$rc${LANE_CONTEXT_OWNED_REASON:+ $LANE_CONTEXT_OWNED_REASON}"' \
    _ "${LIB:-$SCRIPTS_DIR}" "$@"
}
while IFS='|' read -r label path session home want; do
  assert_eq "$(owned "$path" "$session" "$home")" "$want" "$label"
done <<ROWS
the session's own transcript under the account is owned|$TRANSCRIPT|$SESSION|$ACCOUNT|0
another session's transcript is not|$ACCOUNT/session-state/other/events.jsonl|$SESSION|$ACCOUNT|1 session-mismatch
the session's transcript under another account is not|$TMP_ROOT/.2copilot/session-state/$SESSION/events.jsonl|$SESSION|$ACCOUNT|1 home-mismatch
ROWS
assert_eq "$(bash -c '. "$1/lib/lane-context.sh"; COPILOT_HOME= LANES_HOME=/h lane_context_caller_cfg copilot; COPILOT_HOME=/a lane_context_caller_cfg copilot' _ "$SCRIPTS_DIR")" \
  $'/h/.copilot\n/a' "a copilot session's account is COPILOT_HOME, else the CLI's default home"

echo "=== must-fail controls ==="
# One per reader rule and one per writer, each in a private copy of the scripts.
lib_control() { # NAME FILE OLD NEW — a copy in LIB with one site cut
  LIB="$(mutant_scripts "$1" "$2")" || exit 1
  mutate_file "$LIB/$2" "$3" "$4"
}
lib_control ctl-session lib/copilot-session.sh '[ "$rec_session" = "$session" ] ||' 'true ||'
assert_eq "$(read_row "$ACCOUNT" moved-1 "$TRANSCRIPT" "$WRITTEN")" ok "control: without the session match another session's record answers"
lib_control ctl-account lib/copilot-session.sh '[ "$rec_home" = "$home" ] ||' 'true ||'
assert_eq "$(read_row "$TMP_ROOT/copy" "$SESSION" "$TRANSCRIPT" "$WRITTEN")" ok "control: without the account match a copied record answers"
lib_control ctl-transcript lib/copilot-session.sh 'if [ -n "$transcript" ] && [ "$rec_transcript" != "$transcript" ]; then' 'if false; then'
assert_eq "$(read_row "$ACCOUNT" "$SESSION" "$ACCOUNT/session-state/other/events.jsonl" "$WRITTEN")" ok "control: without the transcript match another transcript answers"
lib_control ctl-age lib/copilot-session.sh '[ "$age" -le "$COPILOT_SESSION_MAX_AGE_S" ]' 'true'
assert_eq "$(read_row "$ACCOUNT" "$SESSION" "$TRANSCRIPT" "$((WRITTEN + MAX + 1))")" ok "control: without the age bound a stale record answers"
lib_control ctl-future lib/copilot-session.sh '[ "$age" -ge 0 ] &&' 'true &&'
assert_eq "$(read_row "$ACCOUNT" "$SESSION" "$TRANSCRIPT" "$((WRITTEN - 1))")" ok "control: without the future bound a record stamped ahead answers"
lib_control ctl-alphabet lib/copilot-session.sh "'' | . | .. | *[!A-Za-z0-9._-]*) return 1 ;;" "'') return 1 ;;"
assert_eq "$(read_row "$ACCOUNT" ../x "$TRANSCRIPT" "$WRITTEN")" missing "control: without the alphabet a path-shaped id is looked up as a file"
lib_control ctl-point lib/adapters/copilot.sh 'capacity=$((CS_WINDOW * LANE_ADAPTER_COPILOT_COMPACT_PCT / 100))' 'capacity=$CS_WINDOW'
assert_eq "$(reading "$(cat "$RECORD")")" $'416000\t1000000\tclaude-opus-5' "control: without the compaction point the whole window is the capacity"
lib_control ctl-unread lib/adapters/copilot.sh '  if [ -z "$CS_TOKENS" ]; then' '  if false; then'
assert_eq "$(reading '{"status":{"context_window":{"context_window_size":1000000}}}')" $'\t800000\t' "control: without the unread arm a record with no count reads as an empty figure"
lib_control ctl-owned lib/lane-context.sh '    claude | codex | copilot) ;;' '    claude | codex) ;;'
assert_eq "$(owned "$ACCOUNT/session-state/other/events.jsonl" "$SESSION" "$ACCOUNT")" "3 harness-unlisted" "control: without copilot in the gate's list another session's transcript is never held to its own"
lib_control ctl-write lib/copilot-session.sh '       status: .}' '       status: {}}'
statusline ctl-write "$LIB" <<<"$(status)"
assert_eq "$(reading "$(cat "$RECORD")")" unread "control: a writer that drops the CLI's object leaves nothing to read"
LIB=""

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
