#!/usr/bin/env bash
# Tests for the launch record oversee-succeed reads for its caller: the
# harness, account, model, effort and directory the fleet state's `overseer`
# object records for the session a pane is, read ahead of that pane's status
# line and account variables, with the record's `pending` successor never read
# as the caller's own. Run over a real tmux server on a private socket, as
# oversee_succeed.sh is; claude, codex and kendex are stubs on PATH, and `lanes
# pick` answers from the lanes-fixture usage bodies. Every row reads a
# judgement or a printed line, so nothing here opens a successor.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
# shellcheck source=lib/lanes-fixture.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/lanes-fixture.sh"
# mutant_scripts and mutate_file, the two halves of each control.
# shellcheck source=lib/growth-state.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/growth-state.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUCCEED="$TEST_DIR/../scripts/oversee-succeed"
# The permission word a claude line carries, read from the launch table the
# launcher writes it from, so the rows assert the word a caller hands on
# reaches the line without this file spelling it.
# shellcheck source=../scripts/lib/lane-launch.sh
source "$TEST_DIR/../scripts/lib/lane-launch.sh"
BYPASS="$(launch_choice_permission_write claude)" || { echo "fixture: no claude permission word in the launch table" >&2; exit 1; }

TMP_ROOT="$(mktemp -d)"
SOCK="oversee-succeed-record-$$"
cleanup() {
  tmux -L "$SOCK" kill-server 2>/dev/null || true
  rm -rf -- "${TMP_ROOT:?}"
}
trap cleanup EXIT
tm() { tmux -L "$SOCK" "$@"; }

# shellcheck source=lib/assertions.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/assertions.sh"

BIN="$TMP_ROOT/bin"
mkdir -p "$BIN" "$TMP_ROOT/work/tmp"
for harness in claude codex; do
  printf '#!/bin/sh\nexec sleep 100000\n' > "$BIN/$harness"
done
cat > "$BIN/kendex" <<'STUB'
#!/bin/sh
exit 1
STUB
chmod +x "$BIN/claude" "$BIN/codex" "$BIN/kendex"

new_home fleet
make_lane "$H" claude
make_lane "$H" eclaude
make_codex_lane "$H/.codex"
FETCHER="$TMP_ROOT/fetch"
make_fetcher "$FETCHER"
# The account the environment names, .claude, has room for a Fable session and
# none for an Opus one: its Opus-scoped weekly window is at 99 percent, which
# lib/lane-model.sh counts only against a session on that model. The account
# a record names in its place, .eclaude, sits at the trigger for every model.
# So the headroom a judgement reports says which account and which model it
# judged: 90 is .claude on Fable, 1 is .claude on Opus, 5 is .eclaude.
claude_usage 10 10 99 Opus > "$FIXTURE_DIR/.claude.json"
claude_usage 95 20 5 Opus > "$FIXTURE_DIR/.eclaude.json"
jq -n '{rate_limit: {primary_window: {used_percent: 20, reset_at: 1785000000, limit_window_seconds: 18000}, secondary_window: null}}' \
  > "$FIXTURE_DIR/.codex.json"

env PATH="$BIN:$PATH" tmux -L "$SOCK" -f /dev/null new-session -d -s fleet -x 220 -y 50 'exec sleep 100000'
tm set-option -g default-shell /bin/sh
TMUX_ADDR="$(tm display-message -p '#{socket_path},#{pid},0')"
SERVER_PID="$(tm display-message -p '#{pid}')"

# A Fable status line well under the context mark, and the line a
# stored-token session draws: no account parenthetical, which the status-line
# reader does not parse, so such a session has only its record to answer.
FABLE='  kendex (ken-1921) Fable 5.1 (1M context) 10% (fixture@example.com)     /rc'
OPUS='  kendex (ken-1921) Opus 5 (1M context) 10% (fixture@example.com)     /rc'
TOKEN_LINE='  kendex (ken-1921) Fable 5.1 20%'
BRIEF='Read .agents/skills/orch/SKILL.md and execute the orch oversee workflow after reading the overseer handoff at tmp/handoffs/OVERSEER-HANDOFF.md'

# new_caller SCREEN — a caller pane at index 1 showing SCREEN; sets
# CALLER_PANE. Its foreground process names no harness, so a pane whose screen
# does not parse is refused unless something else names its harness.
new_caller() {
  local f="$TMP_ROOT/caller.screen" last
  printf '%s\n' "$1" > "$f"
  tm kill-window -a -t fleet:0
  CALLER_PANE="$(tm new-window -d -t fleet:1 -P -F '#{pane_id}' "cat '$f'; exec sleep 100000")"
  last="$(sed -n '$p' "$f")"
  last="${last#"${last%%[![:space:]]*}"}"
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [[ "$(tm capture-pane -p -t "$CALLER_PANE")" != *"$last"* ]] || return 0
    sleep 0.2
  done
  echo "fixture: caller pane never drew its screen" >&2
  exit 1
}

FLEET_STATE="$TMP_ROOT/work/tmp/workflow-state-oversee.json"
# state OVERSEER_JSON — the fleet state with that `overseer` object; `none`
# writes no state file at all.
state() {
  rm -f -- "$FLEET_STATE"
  [[ "$1" != none ]] || return 0
  jq -n --argjson o "$1" '{issue_id: "oversee", overseer: $o}' > "$FLEET_STATE"
}
# record PANE ACCOUNT MODEL [EXTRA_JSON] — a current launch record for PANE on
# this server, as a launcher writes it, with EXTRA_JSON merged over it.
record() {
  local extra="${4:-}"
  [[ -n "$extra" ]] || extra='{}'
  jq -cn --arg server "$SERVER_PID" --arg pane "$1" --arg account "$2" --arg model "$3" \
    --argjson extra "$extra" '{runtime: "tmux", generation: 2, server: $server, pane: $pane,
      window: "@1", harness: "claude", account: $account, home: $account, model: $model,
      effort: "high", cwd: null, launch_line: "recorded"} + $extra'
}
# A successor a succession wrote before its launch, disagreeing with the
# current session on every field.
PENDING="$(jq -cn --arg h "$H" '{pending: {launch_line: "pending", harness: "codex",
  account: ($h + "/.eclaude"), home: ($h + "/.eclaude"), model: "claude-opus-5", effort: "low", cwd: "/elsewhere"}}')"

# run_succeed ENV_LANE ARGS... — the script under an explicit, whole
# environment from the caller pane, ENV_LANE being the account variable that
# environment carries. Sets OUT (stdout), ERR (stderr) and RC.
run_succeed() {
  local lane="$1"
  shift
  RC=0
  OUT="$(cd "$TMP_ROOT/work" && env -i HOME="$H" PATH="$BIN:$PATH" TMUX="$TMUX_ADDR" TMUX_PANE="$CALLER_PANE" \
    LANES_HOME="$H" FIXTURE_DIR="$FIXTURE_DIR" OVERSEE_WATCH_STATE_DIR="$TMP_ROOT/lanes-state" \
    ORCH_LANES_FETCH_CMD="$FETCHER" ORCH_LANE_DIRS="$H/.claude:$H/.eclaude:$H/.codex" \
    ORCH_LANES_USAGE_TTL=0 ORCH_OVERSEER_HEADROOM_PCT=5 ORCH_OVERSEER_WALL_MINUTES=0 \
    ORCH_OVERSEER_SUCCESSOR_ACCOUNTS=0 ORCH_OVERSEER_PREFERENCE= "$lane" \
    "${SUCCEED_BIN:-$SUCCEED}" "$@" 2>"$TMP_ROOT/err")" || RC=$?
  ERR="$(cat -- "$TMP_ROOT/err")"
}
# judged — the judgement's key and the one figure that says which account and
# model it read: `headroom` on a below-mark line, `value` on a reached one.
judged() {
  local first key fields=""
  first="$(sed -n 1p <<<"$OUT")"
  key="${first#oversee-succeed: }"
  key="${key%% *}"
  case "$key" in
    context-below-mark) fields="$(grep -o 'headroom=[^ ]*' <<<"$first")" ;;
    mark-reached) fields="$(grep -o 'kind=[^ ]*' <<<"$first") $(grep -o 'value=[^ ]*' <<<"$first")" ;;
    *) fields="${first#oversee-succeed: "$key" }" ;;
  esac
  printf '%s %s\n' "$key" "$fields"
}

echo "=== oversee-succeed: the caller's launch record ==="

# --- the judgement --------------------------------------------------------
# Each row names every source that disagrees: the pane's status line, the
# account variable, the overseer mailbox, the current record and the pending
# successor. The overseer mailbox is read for identity by nothing, and the
# row that fills it pins that no reader starts to.
MAILBOX="$TMP_ROOT/work/tmp/lane-mail/overseer/to-lane.jsonl"
for row in \
  "none|$FABLE|CLAUDE_CONFIG_DIR=$H/.claude|-|context-below-mark headroom=90|no record: the pane's model and the environment's account decide" \
  "this:$H/.eclaude:fable|$FABLE|CLAUDE_CONFIG_DIR=$H/.claude|-|mark-reached kind=headroom value=5|the record's account decides over the environment's" \
  "this:$H/.claude:claude-opus-5|$FABLE|CLAUDE_CONFIG_DIR=$H/.claude|-|mark-reached kind=headroom value=1|the record's model decides over the status line's" \
  "this:$H/.claude:fable:pending|$OPUS|CLAUDE_CONFIG_DIR=$H/.eclaude|mail|context-below-mark headroom=90|a pending successor, the pane, the environment and the mailbox all disagree: the current record decides" \
  "other:$H/.eclaude:claude-opus-5|$FABLE|CLAUDE_CONFIG_DIR=$H/.claude|-|context-below-mark headroom=90|a record naming another session is not this one's: the bootstrap readings decide" \
  ; do
  IFS='|' read -r row_record row_screen row_lane row_mail row_want row_what <<<"$row"
  new_caller "$row_screen"
  rm -f -- "$MAILBOX"
  if [[ "$row_mail" == mail ]]; then
    mkdir -p "$(dirname "$MAILBOX")"
    jq -cn --arg a "$H/.eclaude" '{id: "1", kind: "owner-note", text: ("overseer account " + $a + " model claude-opus-5")}' > "$MAILBOX"
  fi
  IFS=: read -r rec_pane rec_account rec_model rec_pending <<<"$row_record"
  case "$rec_pane" in
    none) state none ;;
    this) state "$(record "$CALLER_PANE" "$rec_account" "$rec_model" "$([[ -z "$rec_pending" ]] && echo '{}' || echo "$PENDING")")" ;;
    other) state "$(record %999 "$rec_account" "$rec_model")" ;;
  esac
  run_succeed "$row_lane" --check-marks
  assert_eq "$RC|$(judged)" "0|$row_want" "--check-marks: $row_what" "$TMP_ROOT/err"
done

# A state that cannot be read is said, and the bootstrap readings judge.
new_caller "$FABLE"
printf '{"issue_id": "oversee", "overseer": \n' > "$FLEET_STATE"
run_succeed "CLAUDE_CONFIG_DIR=$H/.claude" --check-marks
assert_eq "$RC|$(judged)|$(grep -c "^oversee-succeed: record-unread pane=$CALLER_PANE\$" <<<"$ERR")" \
  "0|context-below-mark headroom=90|1" \
  "--check-marks on an unreadable state: record-unread, and the pane and environment judge"

# The control for the pending rule: a reader that takes the pending successor
# as the current session judges the running overseer as the successor's codex
# session on the successor's claude account, which no codex inventory lists.
PENDCTL="$(mutant_scripts pendctl lib/overseer-launch.sh)" || exit 1
mutate_file "$PENDCTL/lib/overseer-launch.sh" \
  'then [.harness, .account, .home, .model, .effort, .cwd]' \
  'then (.pending // .) | [.harness, .account, .home, .model, .effort, .cwd]'
new_caller "$FABLE"
state "$(record "$CALLER_PANE" "$H/.claude" fable "$PENDING")"
SUCCEED_BIN="$PENDCTL/oversee-succeed" run_succeed "CLAUDE_CONFIG_DIR=$H/.claude" --check-marks
assert_eq "$RC|$(judged)" "0|mark-unmeasured kind=headroom reason=headroom-none succession=on" \
  "control: a reader of the pending successor judges the caller as the successor" "$TMP_ROOT/err"

# The control for the model rule: a caller that ignores the record's model is
# judged on the status line's.
MODELCTL="$(mutant_scripts modelctl oversee-succeed)" || exit 1
mutate_file "$MODELCTL/oversee-succeed" \
  '[[ -z "$OL_CUR_MODEL" ]] || CALLER_MODEL=' \
  '[[ -n "$OL_CUR_MODEL" ]] || CALLER_MODEL='
new_caller "$FABLE"
state "$(record "$CALLER_PANE" "$H/.claude" claude-opus-5)"
SUCCEED_BIN="$MODELCTL/oversee-succeed" run_succeed "CLAUDE_CONFIG_DIR=$H/.claude" --check-marks
assert_eq "$RC|$(judged)" "0|context-below-mark headroom=90" \
  "control: a caller that ignores the record's model is judged on the status line's" "$TMP_ROOT/err"

# --- the line a watch records at its start --------------------------------
# A stored-token session: its status line names no account, the reader parses
# none of it, and a pane nothing recorded is refused as before.
new_caller "$TOKEN_LINE"
state none
run_succeed "CLAUDE_CONFIG_DIR=$H/.claude" --print-launch-line -- "$BYPASS"
assert_eq "$RC|$(sed -n 1p <<<"$ERR")" "1|oversee-succeed: no-status-line pane=$CALLER_PANE" \
  "--print-launch-line with no record and no readable status line keeps its refusal"
# The same pane with a record: the harness, account, model and effort are the
# record's, the permission word the caller's own flags, and the pending
# successor changes none of it.
RECORD_LINE="env CLAUDE_CONFIG_DIR='$H/.eclaude' claude -n overseer --model fable --effort high $BYPASS '$BRIEF'"
for pending in '{}' "$PENDING"; do
  state "$(record "$CALLER_PANE" "$H/.eclaude" fable "$pending")"
  run_succeed "CLAUDE_CONFIG_DIR=$H/.claude" --print-launch-line -- "$BYPASS" --model opus --effort low
  assert_eq "$RC|$OUT" "0|$RECORD_LINE" \
    "--print-launch-line on a stored-token pane takes its record's identity ($( [[ "$pending" == '{}' ]] && echo 'no pending successor' || echo 'a pending successor standing'))" \
    "$TMP_ROOT/err"
done

# --- the succession -------------------------------------------------------
# A live succession judges the account and model its record names: .eclaude at
# the trigger fires the headroom mark, and on the record's Opus the caller
# entry finds no claude account with room, where the pane and the environment
# alone would have kept this session running on .claude.
new_caller "$FABLE"
state "$(record "$CALLER_PANE" "$H/.eclaude" claude-opus-5)"
run_succeed "CLAUDE_CONFIG_DIR=$H/.claude"
assert_eq "$RC|$(sed -n 1p <<<"$ERR" | grep -o '^oversee-succeed: no-lane-qualifies .* mark=headroom')|$(tm list-windows -t fleet -F '#{window_name}' | grep -c '^overseer$' || true)" \
  "3|oversee-succeed: no-lane-qualifies entries=0 fallback=claude walled=2 unmeasured=0 mark=headroom|0" \
  "a succession is judged on its record's account and model, and opens nothing where none has room"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
