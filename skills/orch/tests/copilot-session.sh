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

echo "=== the stop cause, and the session a lane in a worktree runs ==="
# cause RECORD_JSON GRANTED — copilot_session_stop_cause over one record and a
# launch's grant: the cause, or none.
cause() {
  bash -c 'set -euo pipefail; . "$1/lib/lane-context.sh"; copilot_session_stop_cause "$2" "$3" || echo none' \
    _ "${LIB:-$SCRIPTS_DIR}" "$1" "$2"
}
while IFS='|' read -r label allow grant want; do
  assert_eq "$(cause "{\"status\":{\"allow_all_enabled\":$allow}}" "$grant")" "$want" "$label"
done <<'ROWS'
allow_all_enabled false under an allow-all launch is a stop with its own cause|false|true|allow-all-blocked-by-policy
allow_all_enabled false under a launch without allow-all is its prompts by design and names none|false||none
a grant spelled other than true is no grant and names none|false|1|none
allow_all_enabled true names none|true|true|none
a record that does not say names none|null|true|none
a string is not the CLI's boolean and names none|"false"|true|none
ROWS
# A lane's worktree and the session store beside the record: WT_SESSION ran
# in WT and holds events, EMPTY_SESSION started in WT and ended before its
# first event, OTHER_SESSION ran elsewhere.
WT="$TMP_ROOT/lane-wt"
mkdir -p "$WT" "$TMP_ROOT/elsewhere"
workspace() { # SESSION CWD EVENTS
  mkdir -p "$ACCOUNT/session-state/$1"
  printf 'id: %s\ncwd: %s\n' "$1" "$2" > "$ACCOUNT/session-state/$1/workspace.yaml"
  [ "$3" = none ] || printf '%s\n' "$3" > "$ACCOUNT/session-state/$1/events.jsonl"
}
workspace "$SESSION" "$WT" '{"type":"session.start"}'
workspace empty-1 "$WT" none
workspace other-2 "$TMP_ROOT/elsewhere" '{"type":"session.start"}'
touch -t 200001010000 "$ACCOUNT/session-state/$SESSION/workspace.yaml"
# lanes STATUS HARNESS ACCOUNT SESSION_ID MAIL_ROOT [ALLOW_ALL] [SESSION_SINCE]
# [LAUNCHED_AT] — the fleet state's lanes array holding one record for the
# window kendex:CC-1, `null` for a field it leaves unset; ALLOW_ALL is the
# launch's grant, true unless named, SESSION_SINCE the stamp of the launch
# that started the running session and LAUNCHED_AT the fleet's first launch,
# each null unless named.
lanes() {
  jq -nc --arg st "$1" --arg h "$2" --arg a "$3" --arg s "$4" --arg m "$5" --argjson g "${6:-true}" --arg ss "${7:-null}" --arg l "${8:-null}" \
    'def v: if . == "null" then null else . end;
     [{item: "CC-1", window: "kendex:CC-1", status: $st, harness: $h, account: ($a | v), session_id: ($s | v),
       mail_root: ($m | v), allow_all: $g, session_since: ($ss | v), launched_at: ($l | v)}]'
}
# lane_row LANES WINDOW NOW [COPILOT_HOME] — the note a reader outside the
# session takes for WINDOW, from a child shell: the Copilot lane's record
# (lib/lane-claims.sh lane_running_record) through
# lib/lane-context.sh lane_context_copilot_note; `none` for an empty note,
# `refused` for fleet state the lookup could not read.
lane_row() {
  COPILOT_HOME="${4:-}" LANES_HOME="$TMP_ROOT" bash -c 'set -euo pipefail; . "$1/lib/lane-claims.sh"; . "$1/lib/lane-context.sh"
    rec="$(lane_running_record "$2" "$3" copilot)" || { echo refused; exit 0; }
    lane_context_copilot_note "$rec" "$4" || { echo "rc=$?"; exit 0; }
    echo "${COPILOT_SESSION_NOTE:-none}"' \
    _ "${LIB:-$SCRIPTS_DIR}" "$1" "$2" "$3"
}
statusline blocked <<<"$(status | jq -c '.allow_all_enabled = false')"
WRITTEN="$(jq -r '.written_at' "$RECORD")"
while IFS='|' read -r label lanes_json window now want; do
  assert_eq "$(lane_row "$lanes_json" "$window" "$now")" "$want" "$label"
done <<ROWS
the lane's session reporting allow-all blocked names the cause|$(lanes running copilot "$ACCOUNT" null "$WT")|CC-1|$WRITTEN|stop-cause=allow-all-blocked-by-policy
a session-qualified window and the state object holding the array name the same lane|{"lanes":$(lanes running copilot "$ACCOUNT" null "$WT")}|other:CC-1|$WRITTEN|stop-cause=allow-all-blocked-by-policy
another worktree's session is read as that lane's, and wrote no record|$(lanes running copilot "$ACCOUNT" null "$TMP_ROOT/elsewhere")|CC-1|$WRITTEN|session-record=missing
a worktree no session ran in is unmatched|$(lanes running copilot "$ACCOUNT" null "$TMP_ROOT")|CC-1|$WRITTEN|session-record=worktree-unmatched
a record naming no session and no worktree is unmatched|$(lanes running copilot "$ACCOUNT" null null)|CC-1|$WRITTEN|session-record=worktree-unmatched
the lane's session record past the bound is stale|$(lanes running copilot "$ACCOUNT" null "$WT")|CC-1|$((WRITTEN + MAX + 1))|session-record=stale
an account with no session store is unmatched|$(lanes running copilot "$TMP_ROOT/.2copilot" null "$WT")|CC-1|$WRITTEN|session-record=worktree-unmatched
a worktree that does not resolve is unreadable|$(lanes running copilot "$ACCOUNT" null "$TMP_ROOT/gone")|CC-1|$WRITTEN|session-record=store-unreadable
a record that is not running is no lane to read|$(lanes stopped copilot "$ACCOUNT" null "$WT")|CC-1|$WRITTEN|none
a Pi lane's record is no Copilot lane|$(lanes running pi "$ACCOUNT" null "$WT")|CC-1|$WRITTEN|none
another window's record is not this lane's|$(lanes running copilot "$ACCOUNT" null "$WT")|CC-2|$WRITTEN|none
a watch with no fleet state reads nothing||CC-1|$WRITTEN|none
a fleet state that is not JSON is refused|{|CC-1|$WRITTEN|refused
a lane launched without allow-all reads allow_all_enabled false too, and names no cause|$(lanes running copilot "$ACCOUNT" null "$WT" false)|CC-1|$WRITTEN|none
a record naming no grant is no lane launched with allow-all, and no session is looked up for it|$(lanes running copilot "$ACCOUNT" null "$TMP_ROOT" null)|CC-1|$WRITTEN|none
ROWS
# A record naming no account is the account a launch with no --lane runs on,
# COPILOT_HOME, which the default of every launch and relaunch is too.
assert_eq "$(lane_row "$(lanes running copilot null null "$WT")" CC-1 "$WRITTEN" "$ACCOUNT")" \
  stop-cause=allow-all-blocked-by-policy "a record naming no account is read under the account a launch with no --lane runs on"
# A later session of another run in the same worktree, a second-opinion run
# from it, say, with allow-all on in its own record, and an earlier one a
# fresh relaunch retired, whose record went stale: the lane's session is the
# record's session_id, else the earliest written at or after the record's
# session_since, never its launched_at, which a relaunch keeps. $SESSION's
# workspace.yaml is stamped 2000-01-01 local time and the retired one's
# 1999-06-01, so a stamp on 1999-01-01 UTC precedes both, one on 1999-12-30
# UTC falls between them and one on 2001-01-01 UTC follows both in every zone.
workspace foreign-3 "$WT" '{"type":"session.start"}'
statusline foreign <<<"$(status | jq -c --arg t "$ACCOUNT/session-state/foreign-3/events.jsonl" \
  '.session_id = "foreign-3" | .transcript_path = $t')"
statusline blocked <<<"$(status | jq -c '.allow_all_enabled = false')"
WRITTEN="$(jq -r '.written_at' "$RECORD")"
workspace retired-4 "$WT" '{"type":"session.start"}'
touch -t 199906010000 "$ACCOUNT/session-state/retired-4/workspace.yaml"
jq -c --arg t "$ACCOUNT/session-state/retired-4/events.jsonl" --argjson w "$((WRITTEN - MAX - 1))" \
  '.session_id = "retired-4" | .transcript_path = $t | .written_at = $w' "$RECORD" > "$ACCOUNT/lane-status/retired-4.json"
while IFS='|' read -r label session since launched want; do
  assert_eq "$(lane_row "$(lanes running copilot "$ACCOUNT" "$session" "$WT" true "$since" "$launched")" CC-1 "$WRITTEN")" "$want" "$label"
done <<ROWS
the record's session_id is read over a later session in the worktree|$SESSION|null|null|stop-cause=allow-all-blocked-by-policy
a record naming no session reads the earliest session written since its session_since, the relaunched session, not the one the relaunch retired before it or the fleet's launched_at|null|1999-12-30T00:00:00Z|1999-01-01T00:00:00Z|stop-cause=allow-all-blocked-by-policy
a session written before session_since is not the lane's|null|2001-01-01T00:00:00Z|null|none
a record with no session_since reads the newest session in the worktree, though it names a launched_at|null|null|1999-01-01T00:00:00Z|none
ROWS
statusline allowed <<<"$(status)"
WRITTEN="$(jq -r '.written_at' "$RECORD")"
assert_eq "$(lane_row "$(lanes running copilot "$ACCOUNT" "$SESSION" "$WT")" CC-1 "$WRITTEN")" none \
  "the lane's session with allow-all on names no cause"
statusline blocked <<<"$(status | jq -c '.allow_all_enabled = false')"
WRITTEN="$(jq -r '.written_at' "$RECORD")"
rm -rf -- "${ACCOUNT:?}/session-state/empty-1" "${ACCOUNT:?}/session-state/other-2"

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
lib_control ctl-point lib/adapters/copilot.sh 'capacity=$((CS_WINDOW * LANE_CONTEXT_COPILOT_COMPACTION_PCT / 100))' 'capacity=$CS_WINDOW'
assert_eq "$(reading "$(cat "$RECORD")")" $'416000\t1000000\tclaude-opus-5' "control: without the compaction point the whole window is the capacity"
lib_control ctl-unread lib/adapters/copilot.sh '  if [ -z "$CS_TOKENS" ]; then' '  if false; then'
assert_eq "$(reading '{"status":{"context_window":{"context_window_size":1000000}}}')" $'\t800000\t' "control: without the unread arm a record with no count reads as an empty figure"
lib_control ctl-owned lib/lane-context.sh '    claude | codex | copilot) ;;' '    claude | codex) ;;'
assert_eq "$(owned "$ACCOUNT/session-state/other/events.jsonl" "$SESSION" "$ACCOUNT")" "3 harness-unlisted" "control: without copilot in the gate's list another session's transcript is never held to its own"
lib_control ctl-cause lib/copilot-session.sh '[ "$CS_ALLOW_ALL" = false ] || return 1' '[ "$CS_ALLOW_ALL" = never ] || return 1'
assert_eq "$(cause '{"status":{"allow_all_enabled":false}}' true)" none "control: without the allow-all test a policy-blocked record names no cause"
lib_control ctl-cause-grant lib/copilot-session.sh '  [ "$2" = true ] || return 1' '  : || return 1'
assert_eq "$(cause '{"status":{"allow_all_enabled":false}}' '')" allow-all-blocked-by-policy "control: without the grant test a launch without allow-all is named policy-blocked"
lib_control ctl-unmatched lib/copilot-session.sh '1) COPILOT_SESSION_NOTE=session-record=worktree-unmatched; return 0 ;;' '1) return 0 ;;'
assert_eq "$(lane_row "$(lanes running copilot "$ACCOUNT" null "$TMP_ROOT")" CC-1 "$WRITTEN")" none "control: without the unmatched arm a worktree no session ran in reads as a lane with no cause"
lib_control ctl-session-id lib/copilot-session.sh '  if [ -z "$session" ]; then' '  if true; then'
assert_eq "$(lane_row "$(lanes running copilot "$ACCOUNT" "$SESSION" "$WT")" CC-1 "$WRITTEN")" none "control: without the record's session_id a newer session in the worktree is read in the lane's place"
lib_control ctl-launch-pick lib/copilot-session.sh '[ ! "$file" -ot "$best" ]' '[ ! "$file" -nt "$best" ]'
assert_eq "$(lane_row "$(lanes running copilot "$ACCOUNT" null "$WT" true 1999-12-30T00:00:00Z)" CC-1 "$WRITTEN")" none "control: without the earliest pick since session_since a later session in the worktree is read in the lane's place"
lib_control ctl-launch-floor lib/copilot-session.sh '[ "$written" -ge "$since" ] || continue' 'true || continue'
assert_eq "$(lane_row "$(lanes running copilot "$ACCOUNT" null "$WT" true 2001-01-01T00:00:00Z)" CC-1 "$WRITTEN")" session-record=stale "control: without the floor the session a relaunch retired, written before session_since, is read as the lane's"
lib_control ctl-session-since lib/lane-context.sh '(.session_since | fromdateiso8601' '(.launched_at | fromdateiso8601'
assert_eq "$(lane_row "$(lanes running copilot "$ACCOUNT" null "$WT" true 1999-12-30T00:00:00Z 1999-01-01T00:00:00Z)" CC-1 "$WRITTEN")" session-record=stale "control: bound through launched_at, which a relaunch keeps, a relaunched lane reads the session the relaunch retired"
lib_control ctl-default-account lib/lane-context.sh 'home="$(lane_context_caller_cfg copilot)"' 'home="$(printf "")"'
assert_eq "$(lane_row "$(lanes running copilot null "$SESSION" "$WT")" CC-1 "$WRITTEN" "$ACCOUNT")" session-record=missing "control: without the default account a record naming none is read under no account"
lib_control ctl-running lib/lane-claims.sh 'select(running and .harness == $h' 'select(.harness == $h'
assert_eq "$(lane_row "$(lanes stopped copilot "$ACCOUNT" "$SESSION" "$WT")" CC-1 "$WRITTEN")" stop-cause=allow-all-blocked-by-policy "control: without the running test a stopped record is read as a lane"
lib_control ctl-harness lib/lane-claims.sh 'running and .harness == $h and' 'running and'
assert_eq "$(lane_row "$(lanes running pi "$ACCOUNT" "$SESSION" "$WT")" CC-1 "$WRITTEN")" stop-cause=allow-all-blocked-by-policy "control: without the harness test a Pi lane's record is read as a Copilot lane"
lib_control ctl-granted lib/copilot-session.sh '[ "$4" = true ] || return 0' ': || return 0'
assert_eq "$(lane_row "$(lanes running copilot "$ACCOUNT" null "$TMP_ROOT" false)" CC-1 "$WRITTEN")" session-record=worktree-unmatched "control: without the grant test a lane launched without allow-all is looked up and reports a record reason"
lib_control ctl-grant-field lib/lane-context.sh '(.allow_all == true | tostring)' '"true"'
assert_eq "$(lane_row "$(lanes running copilot "$ACCOUNT" "$SESSION" "$WT" false)" CC-1 "$WRITTEN")" stop-cause=allow-all-blocked-by-policy "control: without the record's grant every Copilot lane reads as launched with allow-all"
lib_control ctl-write lib/copilot-session.sh '       status: .}' '       status: {}}'
statusline ctl-write "$LIB" <<<"$(status)"
assert_eq "$(reading "$(cat "$RECORD")")" unread "control: a writer that drops the CLI's object leaves nothing to read"
LIB=""

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
