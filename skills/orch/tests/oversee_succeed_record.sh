#!/usr/bin/env bash
# Tests for the launch record oversee-succeed reads for its caller: the
# harness, account, model, effort and directory the fleet state's `overseer`
# object records for the session a pane is, read ahead of --harness, that
# pane's command, its context reading in the overseer mailbox and its account
# variables, with the record's `pending` successor never read as the caller's
# own. Run over a real tmux server on a private socket, as
# oversee_succeed.sh is; claude, codex and pi are stubs on PATH, and `lanes
# pick` answers from the lanes-fixture usage bodies. The judgement and print
# rows open nothing; the dead-pane relaunch rows and the pending-successor rows
# each open a successor pane on the private tmux server, which the EXIT trap's
# kill-server closes.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
# shellcheck source=lib/lanes-fixture.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/lanes-fixture.sh"
# mutant_scripts and mutate_file, the two halves of each control.
# shellcheck source=lib/growth-state.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/growth-state.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUCCEED="$TEST_DIR/../scripts/oversee-succeed"
SRC_DIR="$(cd "$TEST_DIR/../scripts" && pwd)"
# The permission word a claude line carries, read from the launch table the
# launcher writes it from, so the rows assert the word a caller hands on
# reaches the line without this file spelling it.
# shellcheck source=../scripts/lib/lane-launch.sh
source "$TEST_DIR/../scripts/lib/lane-launch.sh"
BYPASS="$(launch_choice_permission_write claude)" || { echo "fixture: no claude permission word in the launch table" >&2; exit 1; }
# The words every claude successor line leads with, read from the launch table
# the builder writes them from: its compaction setting for a model whose window
# the table names, then the question-tool words, ORCH_QUESTION_TOOL being off by
# default, quoted as the line spells them.
launch_choice_lead_settings --question-off --model fable claude
LEAD="$(printf '%q ' "${LAUNCH_CHOICE_KEPT[@]}")"
LEAD="${LEAD% }"
# The context reading a turn-end hook records in the overseer mailbox.
# shellcheck source=../scripts/lib/lane-context.sh
source "$TEST_DIR/../scripts/lib/lane-context.sh"

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
# A harness stub draws the hint a running turn shows, so a relaunched session
# reads as working.
for harness in claude codex pi; do
  printf '#!/bin/sh\necho "esc to interrupt"\nexec sleep 100000\n' > "$BIN/$harness"
done
chmod +x "$BIN/claude" "$BIN/codex" "$BIN/pi"
# A caller whose foreground process names claude: a copy of sleep, since a
# script or a shell named for the harness can reset the name tmux reads.
cp "$(command -v sleep)" "$BIN/hclaude"

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
# A pi install a pi successor may open on: its user settings turn compaction
# off, and its pi-hooks carrier sends the context window.
PI_AGENT="$H/.pi/agent"
mkdir -p "$PI_AGENT/packages/@vanillagreen/pi-hooks/extensions"
jq -n '{compaction: {enabled: false}}' > "$PI_AGENT/settings.json"
printf 'payload.context_window = usage.contextWindow;\n' > "$PI_AGENT/packages/@vanillagreen/pi-hooks/extensions/stop.ts"

env PATH="$BIN:$PATH" tmux -L "$SOCK" -f /dev/null new-session -d -s fleet -x 220 -y 50 'exec sleep 100000'
tm set-option -g default-shell /bin/sh
# A relaunch types its line into a fresh pane: a non-login shell under this
# fixture's PATH, so the stubs above are the harness it runs.
tm set-option -g default-command "PATH=$BIN:\$PATH; export PATH; exec /bin/sh"
TMUX_ADDR="$(tm display-message -p '#{socket_path},#{pid},0')"
SERVER_PID="$(tm display-message -p '#{pid}')"
SERVER_START="$(tm display-message -p '#{start_time}')"

BRIEF='Read .agents/skills/orch/SKILL.md and execute the orch oversee workflow after reading the overseer handoff at tmp/handoffs/OVERSEER-HANDOFF.md'

# new_caller [claude] — a caller pane at index 1, with no context reading yet;
# sets CALLER_PANE. With `claude` its foreground process names claude; without,
# it names no harness, as a Codex pane reading node or a stored-token session
# started through a wrapper does, and only --harness, a context reading or a
# record names it.
MAILBOX_DIR="$TMP_ROOT/work/tmp/lane-mail/overseer"
new_caller() {
  local cmd="exec sleep 100000"
  [[ "${1:-}" != claude ]] || cmd="exec '$BIN/hclaude' 100000"
  tm kill-window -a -t fleet:0
  rm -f -- "${MAILBOX_DIR:?}/$LANE_CONTEXT_RECORD"
  CALLER_PANE="$(tm new-window -d -t fleet:1 -P -F '#{pane_id}' "$cmd")"
}
# reading MODEL — the context reading the caller's own turn-end hook records in
# the overseer mailbox for this pane, naming MODEL, well under the context mark.
reading() {
  mkdir -p "$MAILBOX_DIR"
  lane_context_record "$MAILBOX_DIR" claude 100000 1000000 "$1" "" "$SERVER_PID $CALLER_PANE"
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
# this server, bound to its start, as a launcher writes it, with EXTRA_JSON
# merged over it.
record() {
  local extra="${4:-}"
  [[ -n "$extra" ]] || extra='{}'
  jq -cn --arg server "$SERVER_PID" --argjson start "$SERVER_START" --arg pane "$1" --arg account "$2" --arg model "$3" \
    --argjson extra "$extra" '{runtime: "tmux", generation: 2, server: $server, server_start: $start, pane: $pane,
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
    ORCH_OVERSEER_SUCCESSOR_ACCOUNTS=0 ORCH_OVERSEER_PREFERENCE="${PREFERENCE:-}" "$lane" \
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
    account-below-mark) fields="$(grep -o 'headroom=[^ ]*' <<<"$first")" ;;
    mark-reached) fields="$(grep -o 'kind=[^ ]*' <<<"$first") $(grep -o 'value=[^ ]*' <<<"$first")" ;;
    *) fields="${first#oversee-succeed: "$key" }" ;;
  esac
  printf '%s %s\n' "$key" "$fields"
}

echo "=== oversee-succeed: the caller's launch record ==="

# --- the judgement --------------------------------------------------------
# Each row names every source that disagrees: the context reading in the
# overseer mailbox, the account variable, a note in that mailbox, the current
# record and the pending successor.
MAILBOX="$TMP_ROOT/work/tmp/lane-mail/overseer/to-lane.jsonl"
for row in \
  "none|Fable 5.1|CLAUDE_CONFIG_DIR=$H/.claude|-|account-below-mark headroom=90|no record: the reading's model and the environment's account decide" \
  "this:$H/.eclaude:fable|Fable 5.1|CLAUDE_CONFIG_DIR=$H/.claude|-|mark-reached kind=headroom value=5|the record's account decides over the environment's" \
  "this:$H/.claude:claude-opus-5|Fable 5.1|CLAUDE_CONFIG_DIR=$H/.claude|-|mark-reached kind=headroom value=1|the record's model decides over the reading's" \
  "this:$H/.claude:fable:pending|Opus 5|CLAUDE_CONFIG_DIR=$H/.eclaude|mail|account-below-mark headroom=90|a pending successor, the reading, the environment and a mailbox note all disagree: the current record decides" \
  "other:$H/.eclaude:claude-opus-5|Fable 5.1|CLAUDE_CONFIG_DIR=$H/.claude|-|account-below-mark headroom=90|a record naming another session is not this one's: the bootstrap readings decide" \
  "otherserver:$H/.eclaude:claude-opus-5|Fable 5.1|CLAUDE_CONFIG_DIR=$H/.claude|-|account-below-mark headroom=90|a record naming this pane id on another tmux server is not this one's" \
  "pi:$H/.claude:pi-claude/claude-opus-5|Fable 5.1|CLAUDE_CONFIG_DIR=$H/.eclaude|-|mark-reached kind=headroom value=1|a pi record on the pi-claude provider: its claude account, judged on the claude model the provider runs" \
  "pi::openai/gpt-5|Fable 5.1|CLAUDE_CONFIG_DIR=$H/.claude|-|mark-unmeasured kind=headroom reason=headroom-none succession=on|a pi record on another provider spends no account lanes measures, and no environment account stands in" \
  ; do
  IFS='|' read -r row_record row_reading row_lane row_mail row_want row_what <<<"$row"
  new_caller claude
  reading "$row_reading"
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
    otherserver) state "$(record "$CALLER_PANE" "$rec_account" "$rec_model" '{"server": "1"}')" ;;
    pi) state "$(record "$CALLER_PANE" "$rec_account" "$rec_model" '{"harness": "pi"}')" ;;
  esac
  run_succeed "$row_lane" --check-marks
  assert_eq "$RC|$(judged)" "0|$row_want" "--check-marks: $row_what" "$TMP_ROOT/err"
done

# start_row HARNESS ACCOUNT MODEL — the caller's own SessionStart row
# (lib/session-rows.sh), as its hook writes one in the shape Claude Code
# 2.1.283 emits, in the rows file for its pane on this server.
start_row() {
  mkdir -p "$MAILBOX_DIR"
  jq -cn --arg h "$1" --arg a "$2" --arg m "$3" '{at: 1, event: "SessionStart", harness: $h,
    session_id: "5f0c", transcript_path: "/t/5f0c.jsonl", cwd: "/work", source: "startup",
    model: $m, account: $a}' > "$MAILBOX_DIR/session-$SERVER_PID-${CALLER_PANE#%}.jsonl"
}
# With no record, the row answers ahead of the environment, the reading and
# --harness; a record still answers ahead of the row.
for row in \
  "claude|$H/.eclaude|claude-fable-5-1|Fable 5.1|none||mark-reached kind=headroom value=5|the row's account decides over the environment's" \
  "claude|$H/.claude|claude-opus-5|Fable 5.1|none||mark-reached kind=headroom value=1|the row's model decides over the reading's" \
  "claude|$H/.claude|claude-fable-5-1|-|codex||account-below-mark headroom=90|the row's harness decides over --harness on a pane naming none" \
  "claude|$H/.claude|claude-opus-5|Fable 5.1|none|record|account-below-mark headroom=90|a record naming the session decides over its row" \
  ; do
  IFS='|' read -r r_harness r_account r_model r_reading r_flag r_record r_want r_what <<<"$row"
  flags=(--check-marks)
  [[ "$r_flag" == none ]] || flags+=(--harness "$r_flag")
  if [[ "$r_reading" == - ]]; then new_caller; else new_caller claude; reading "$r_reading"; fi
  if [[ "$r_record" == record ]]; then state "$(record "$CALLER_PANE" "$H/.claude" fable)"; else state none; fi
  start_row "$r_harness" "$r_account" "$r_model"
  run_succeed "CLAUDE_CONFIG_DIR=$H/.claude" "${flags[@]}"
  assert_eq "$RC|$(judged)" "0|$r_want" "--check-marks: $r_what" "$TMP_ROOT/err"
done
# The row rule's control: a caller that reads no row is judged on the
# environment's account, as the first row above says it is not.
ROWCTL="$(mutant_scripts rowctl lib/overseer-launch.sh)" || exit 1
mutate_file "$ROWCTL/lib/overseer-launch.sh" \
  '  session_rows_start "$(session_rows_overseer_file "$3" "$1" "$2")" || true' \
  '  :'
new_caller claude
reading "Fable 5.1"
state none
start_row claude "$H/.eclaude" claude-fable-5-1
SUCCEED_BIN="$ROWCTL/oversee-succeed" run_succeed "CLAUDE_CONFIG_DIR=$H/.claude" --check-marks
assert_eq "$RC|$(judged)" "0|account-below-mark headroom=90" \
  "control: a caller that reads no row is judged on the environment's account" "$TMP_ROOT/err"

# A state that cannot be read is said, and the bootstrap readings judge.
new_caller claude
reading "Fable 5.1"
printf '{"issue_id": "oversee", "overseer": \n' > "$FLEET_STATE"
run_succeed "CLAUDE_CONFIG_DIR=$H/.claude" --check-marks
assert_eq "$RC|$(judged)|$(grep -c "^oversee-succeed: record-unread pane=$CALLER_PANE\$" <<<"$ERR")" \
  "0|account-below-mark headroom=90|1" \
  "--check-marks on an unreadable state: record-unread, and the pane and environment judge"

# A print on an unreadable state gives the same notice on stderr and the line
# alone on stdout, which is all the watch start records.
run_succeed "CLAUDE_CONFIG_DIR=$H/.claude" --print-launch-line -- "$BYPASS"
assert_eq "$RC|$OUT|$(sed -n 1p <<<"$ERR")" \
  "0|env CLAUDE_CONFIG_DIR='$H/.claude' claude -n overseer $LEAD $BYPASS '$BRIEF'|oversee-succeed: record-unread pane=$CALLER_PANE" \
  "--print-launch-line on an unreadable state: the notice on stderr, the line alone on stdout"

# The control for the pending rule: a reader that takes the pending successor
# as the current session judges the running overseer as the successor's codex
# session on the successor's claude account, which no codex inventory lists.
PENDCTL="$(mutant_scripts pendctl lib/overseer-launch.sh)" || exit 1
mutate_file "$PENDCTL/lib/overseer-launch.sh" \
  'then ol_identity | map(' \
  'then (.pending // .) | ol_identity | map('
new_caller claude
reading "Fable 5.1"
state "$(record "$CALLER_PANE" "$H/.claude" fable "$PENDING")"
SUCCEED_BIN="$PENDCTL/oversee-succeed" run_succeed "CLAUDE_CONFIG_DIR=$H/.claude" --check-marks
assert_eq "$RC|$(judged)" "0|mark-unmeasured kind=headroom reason=headroom-none succession=on" \
  "control: a reader of the pending successor judges the caller as the successor" "$TMP_ROOT/err"

# The control for the server rule: a test that matches the pane id alone takes
# another tmux server's record, whose pane ids restart at %0, as this one's.
SERVERCTL="$(mutant_scripts serverctl lib/overseer-launch.sh)" || exit 1
mutate_file "$SERVERCTL/lib/overseer-launch.sh" 'def ol_names($server; $start; $session): type == "object" and (.server // "") == $server' \
  'def ol_names($server; $start; $session): type == "object"'
new_caller claude
reading "Fable 5.1"
state "$(record "$CALLER_PANE" "$H/.eclaude" claude-opus-5 '{"server": "1"}')"
SUCCEED_BIN="$SERVERCTL/oversee-succeed" run_succeed "CLAUDE_CONFIG_DIR=$H/.claude" --check-marks
assert_eq "$RC|$(judged)" "0|mark-reached kind=headroom value=5" \
  "control: a test on the pane id alone judges the caller on another server's record" "$TMP_ROOT/err"

# The record names the harness ahead of --harness, which is the watch's
# bootstrap input for a pane that cannot say.
harness_row() { # [SUCCEED_BIN]
  new_caller
  state "$(record "$CALLER_PANE" "$H/.eclaude" fable)"
  SUCCEED_BIN="${1:-}" run_succeed "CLAUDE_CONFIG_DIR=$H/.claude" --check-marks --harness codex
}
harness_row
assert_eq "$RC|$(judged)" "0|mark-reached kind=headroom value=5" \
  "--check-marks: the record's harness decides over --harness" "$TMP_ROOT/err"
HARNESSCTL="$(mutant_scripts harnessctl oversee-succeed)" || exit 1
mutate_file "$HARNESSCTL/oversee-succeed" '  if [[ -n "$OL_KNOWN_HARNESS" ]]; then' '  if false; then'
harness_row "$HARNESSCTL/oversee-succeed"
assert_eq "$RC|$(judged)" "0|mark-unmeasured kind=headroom reason=headroom-none succession=on" \
  "control: a caller that takes --harness over its record judges the record's account as a codex lane" "$TMP_ROOT/err"

# The control for the pi account rule: a pi model read as naming no account
# leaves a pi-claude overseer's own claude account unjudged.
PICTL="$(mutant_scripts pictl lib/overseer-launch.sh)" || exit 1
mutate_file "$PICTL/lib/overseer-launch.sh" '    claude) OL_ACCOUNT_MODEL="${model#pi-claude/}" ;;' '    claude) OL_ACCOUNT_HARNESS=none OL_ACCOUNT_MODEL="" ;;'
new_caller claude
reading "Fable 5.1"
state "$(record "$CALLER_PANE" "$H/.claude" pi-claude/claude-opus-5 '{"harness": "pi"}')"
SUCCEED_BIN="$PICTL/oversee-succeed" run_succeed "CLAUDE_CONFIG_DIR=$H/.eclaude" --check-marks
assert_eq "$RC|$(judged)" "0|mark-unmeasured kind=headroom reason=headroom-none succession=on" \
  "control: a pi-claude model read as naming no account leaves the overseer's account unjudged" "$TMP_ROOT/err"

# A pi record on a github-copilot model is judged on the Copilot pool the
# owner states for its Pi root, spent to 2 percent here.
pool_row() { # [SUCCEED_BIN]
  new_caller claude
  state "$(record "$CALLER_PANE" "" github-copilot/gpt-5 '{"harness": "pi"}')"
  SUCCEED_BIN="${1:-}" run_succeed "ORCH_LANE_COPILOT_POOL=$PI_AGENT=98/100" --check-marks
}
pool_row
assert_eq "$RC|$(judged)" "0|mark-reached kind=headroom value=2" \
  "--check-marks on a pi record on a github-copilot model judges the stated Copilot pool" "$TMP_ROOT/err"
POOLCTL="$(mutant_scripts poolctl lib/overseer-launch.sh)" || exit 1
mutate_file "$POOLCTL/lib/overseer-launch.sh" '    unmeasured)' '    pi | unmeasured)'
pool_row "$POOLCTL/oversee-succeed"
assert_eq "$RC|$(judged)" "0|mark-unmeasured kind=headroom reason=headroom-none succession=on" \
  "control: an account reader that ignores the Copilot pool leaves the pi overseer's account unjudged" "$TMP_ROOT/err"
# At that mark the pick moves the successor onto the pool's other account, a
# Pi root with no settings file, where pi compacts by default: the handoff
# gate reads the root the successor runs under, never the caller's, and
# refuses naming that root's settings file.
PI_ROOT2="$H/.pi2"
mkdir -p "$PI_ROOT2"
pool_succeed_row() { # [SUCCEED_BIN]
  new_caller claude
  state "$(record "$CALLER_PANE" "" github-copilot/gpt-5 '{"harness": "pi"}')"
  SUCCEED_BIN="${1:-}" run_succeed "ORCH_LANE_COPILOT_POOL=$PI_AGENT=98/100,$PI_ROOT2=10/100" \
    --wait-secs 5 -- --model github-copilot/gpt-5 --thinking high
}
pool_succeed_row
assert_eq "$RC|$(grep -m1 '^oversee-succeed: pi-handoff-unmarked' <<<"$ERR")" \
  "1|oversee-succeed: pi-handoff-unmarked reason=compaction-on file=$PI_ROOT2/settings.json" \
  "a pool successor on another Pi root is refused on that root's settings" "$TMP_ROOT/err"
PIROOTCTL="$(mutant_scripts pirootctl oversee-succeed)" || exit 1
mutate_file "$PIROOTCTL/oversee-succeed" '    [[ "$lane_var" != PI_CODING_AGENT_DIR || -z "$lane_dir" ]] || pi_root="$lane_dir"' ''
pool_succeed_row "$PIROOTCTL/oversee-succeed"
assert_eq "$(grep -c '^oversee-succeed: pi-handoff-unmarked' <<<"$ERR" || true)|$(grep -o "lane=$PI_ROOT2" <<<"$OUT" | head -1)" \
  "0|lane=$PI_ROOT2" \
  "control: a gate reading the caller's Pi root lets the pool successor open on an unmarked root"

# A pi overseer launched under pi's split spelling, `--provider pi-claude
# --model <id>`, at its context mark with Fable room on its own account: its
# successor's record names the model with its provider, so the next
# generation's turn-end judgement reaches the same claude account.
split_row() { # [SUCCEED_BIN]
  new_caller claude
  state "$(record "$CALLER_PANE" "$H/.claude" "" "$(jq -cn --arg cwd "$TMP_ROOT/work" '{harness: "pi", model: null, effort: null, cwd: $cwd}')")"
  SUCCEED_BIN="${1:-}" run_succeed "CLAUDE_CONFIG_DIR=$H/.claude" --context 950000:1000000 --wait-secs 20 \
    -- --provider pi-claude --model claude-fable-5-1 --thinking high
  SPLIT_RC="$RC"
  CALLER_PANE="$(jq -r '.overseer.pane' "$FLEET_STATE")"
  SUCCEED_BIN="${1:-}" run_succeed "CLAUDE_CONFIG_DIR=$H/.claude" --check-marks
}
split_row
assert_eq "$SPLIT_RC|$(jq -r '.overseer | [.harness, .model] | join(" ")' "$FLEET_STATE")|$RC|$(judged)" \
  "0|pi pi-claude/claude-fable-5-1|0|account-below-mark headroom=90" \
  "a split --provider launch records the model with its provider, and the next generation is judged on its claude account" "$TMP_ROOT/err"
SPLITCTL="$(mutant_scripts splitctl lib/overseer-launch.sh)" || exit 1
mutate_file "$SPLITCTL/lib/overseer-launch.sh" '  ol_identity "$harness" "$lane_dir" "$OL_LAUNCH_HOME" "$model" \' \
  '  ol_identity "$harness" "$lane_dir" "$OL_LAUNCH_HOME" "$(launch_choice_value "$(launch_choice_model_spellings "$harness")" "$*")" \'
split_row "$SPLITCTL/oversee-succeed"
assert_eq "$(jq -r '.overseer.model' "$FLEET_STATE")|$(judged)" \
  "claude-fable-5-1|mark-unmeasured kind=headroom reason=headroom-none succession=on" \
  "control: an identity that reads the bare model word leaves the next generation's account unjudged" "$TMP_ROOT/err"
# A pi overseer nothing recorded, started with a bare `--model <id>`, whose
# reading names `pi-claude/<id>`: it hands over at its context mark, and the
# successor runs and records the provider-bearing model its account was chosen
# from, so the next generation's judgement and succession read the claude
# account rather than a bare model that names none.
bare_row() { # [SUCCEED_BIN]
  new_caller
  mkdir -p "$MAILBOX_DIR"
  lane_context_record "$MAILBOX_DIR" pi 100000 1000000 pi-claude/claude-fable-5-1 "" "$SERVER_PID $CALLER_PANE"
  state null
  SUCCEED_BIN="${1:-}" run_succeed "CLAUDE_CONFIG_DIR=$H/.claude" --context 950000:1000000 --wait-secs 20 \
    -- --model claude-fable-5-1 --thinking high
  BARE_RC="$RC" BARE_MODEL="$(jq -r '.overseer.model' "$FLEET_STATE")"
  CALLER_PANE="$(jq -r '.overseer.pane' "$FLEET_STATE")"
  SUCCEED_BIN="${1:-}" run_succeed "CLAUDE_CONFIG_DIR=$H/.claude" --check-marks
  BARE_JUDGED="$(judged)"
  SUCCEED_BIN="${1:-}" run_succeed "CLAUDE_CONFIG_DIR=$H/.claude" --context 950000:1000000 --wait-secs 20 \
    -- --model claude-fable-5-1 --thinking high
}
bare_row
assert_eq "$BARE_RC|$BARE_MODEL|$BARE_JUDGED|$RC|$(jq -r '.overseer.model' "$FLEET_STATE")" \
  "0|pi-claude/claude-fable-5-1|account-below-mark headroom=90|0|pi-claude/claude-fable-5-1" \
  "a bare --model pi overseer hands over on its reading's provider, and the next generation judges and hands over on the claude account" "$TMP_ROOT/err"
# Its control: a successor that runs, and records, its caller's bare flag
# leaves the next generation's succession refusing an account it cannot name.
BARECTL="$(mutant_scripts barectl oversee-succeed)" || exit 1
mutate_file "$BARECTL/oversee-succeed" '  if [[ "$CALLER_HARNESS" == pi && "$CALLER_MODEL" == ?*/?* ]]; then' '  if false; then'
bare_row "$BARECTL/oversee-succeed"
assert_eq "$BARE_MODEL|$RC|$(grep -m1 -o '^oversee-succeed: pi-account-unknown [^ ]*' <<<"$ERR")" \
  "claude-fable-5-1|1|oversee-succeed: pi-account-unknown model=claude-fable-5-1" \
  "control: a successor recording the bare flag leaves the next generation refusing pi-account-unknown"

# The control for the model rule: a caller that ignores the record's model is
# judged on the reading's.
MODELCTL="$(mutant_scripts modelctl oversee-succeed)" || exit 1
mutate_file "$MODELCTL/oversee-succeed" \
  '"${OL_KNOWN_MODEL:-$reading_model}"' \
  '"$reading_model"'
new_caller claude
reading "Fable 5.1"
state "$(record "$CALLER_PANE" "$H/.claude" claude-opus-5)"
SUCCEED_BIN="$MODELCTL/oversee-succeed" run_succeed "CLAUDE_CONFIG_DIR=$H/.claude" --check-marks
assert_eq "$RC|$(judged)" "0|account-below-mark headroom=90" \
  "control: a caller that ignores the record's model is judged on the reading's" "$TMP_ROOT/err"

# --- the line a watch records at its start --------------------------------
# A pane that names no harness, with no reading yet: nothing recorded, it is
# refused as before.
new_caller
state none
run_succeed "CLAUDE_CONFIG_DIR=$H/.claude" --print-launch-line -- "$BYPASS"
assert_eq "$RC|$(sed -n 1p <<<"$ERR")" "1|oversee-succeed: harness-unnamed pane=$CALLER_PANE" \
  "--print-launch-line with no record and a pane naming no harness keeps its refusal"
# The same pane with a record: the harness, account, model and effort are the
# record's, the permission word the caller's own flags, and the pending
# successor changes none of it.
RECORD_LINE="env CLAUDE_CONFIG_DIR='$H/.eclaude' claude -n overseer --model fable --effort high $LEAD $BYPASS '$BRIEF'"
for pending in '{}' "$PENDING"; do
  state "$(record "$CALLER_PANE" "$H/.eclaude" fable "$pending")"
  run_succeed "CLAUDE_CONFIG_DIR=$H/.claude" --print-launch-line -- "$BYPASS" --model opus --effort low
  assert_eq "$RC|$OUT" "0|$RECORD_LINE" \
    "--print-launch-line on a pane naming no harness takes its record's identity ($( [[ "$pending" == '{}' ]] && echo 'no pending successor' || echo 'a pending successor standing'))" \
    "$TMP_ROOT/err"
done

# The control for the pair rule: a caller entry that keeps its own flags beside
# the record's pair hands the successor two models.
PAIRCTL="$(mutant_scripts pairctl lib/overseer-launch.sh)" || exit 1
mutate_file "$PAIRCTL/lib/overseer-launch.sh" '  if [[ -z "$model" ]]; then' '  if true; then'
state "$(record "$CALLER_PANE" "$H/.eclaude" fable)"
SUCCEED_BIN="$PAIRCTL/oversee-succeed" run_succeed "CLAUDE_CONFIG_DIR=$H/.claude" --print-launch-line -- "$BYPASS" --model opus --effort low
assert_eq "$RC|$OUT" "0|env CLAUDE_CONFIG_DIR='$H/.eclaude' claude -n overseer --model fable --effort high $LEAD $BYPASS --model opus --effort low '$BRIEF'" \
  "control: a caller entry that keeps its flags beside the record's pair names two models" "$TMP_ROOT/err"

# A pi overseer's line: its model and level words, its question-tool words and
# its skill command as the brief. With no record and no reading, --harness
# names the harness, and a model off the pi-claude provider names no account,
# so the line carries no lane variable. The pane opens in the work directory,
# where no pi project settings stand.
PI_BRIEF="'/skill:orch oversee after reading the overseer handoff at tmp/handoffs/OVERSEER-HANDOFF.md'"
pi_print_row() { # [SUCCEED_BIN] [MODEL]
  tm kill-window -a -t fleet:0
  CALLER_PANE="$(tm new-window -d -t fleet:1 -c "$TMP_ROOT/work" -P -F '#{pane_id}' 'exec sleep 100000')"
  state none
  SUCCEED_BIN="${1:-}" run_succeed "CLAUDE_CONFIG_DIR=$H/.claude" --print-launch-line --harness pi \
    -- --model "${2:-openai/gpt-5}" --thinking high
}
pi_print_row
assert_eq "$RC|$OUT" "0|pi --exclude-tools question --model openai/gpt-5 --thinking high $PI_BRIEF" \
  "--print-launch-line --harness pi prints the pi line, bare on a provider no lane measures" "$TMP_ROOT/err"
# A github-copilot model spends the Copilot pool, whose account is the Pi root
# the line opens under PI_CODING_AGENT_DIR (lib/lane-launch.sh §
# lane_env_prefix), here the home's own.
pi_print_row "" github-copilot/gpt-5
assert_eq "$RC|$OUT" "0|env PI_CODING_AGENT_DIR='$PI_AGENT' pi --exclude-tools question --model github-copilot/gpt-5 --thinking high $PI_BRIEF" \
  "--print-launch-line on a pi overseer on the Copilot pool opens on its Pi root" "$TMP_ROOT/err"
PIHARNESSCTL="$(mutant_scripts piharnessctl oversee-succeed)" || exit 1
mutate_file "$PIHARNESSCTL/oversee-succeed" '| copilot | pi) ;;' '| copilot) ;;'
pi_print_row "$PIHARNESSCTL/oversee-succeed"
assert_eq "$RC|$(sed -n 1p <<<"$ERR")" "1|oversee-succeed: invalid-harness value=pi" \
  "control: a --harness check naming no pi refuses the pi overseer's line"
# A pi-claude overseer nothing recorded: its --model word after -- names the
# provider, so its line opens on the claude account its environment names. A
# bare model names no provider and no account, and is refused rather than
# printed with no lane.
pi_claude_row() { # MODEL [SUCCEED_BIN]
  tm kill-window -a -t fleet:0
  CALLER_PANE="$(tm new-window -d -t fleet:1 -c "$TMP_ROOT/work" -P -F '#{pane_id}' 'exec sleep 100000')"
  state none
  SUCCEED_BIN="${2:-}" run_succeed "CLAUDE_CONFIG_DIR=$H/.eclaude" --print-launch-line --harness pi \
    -- --model "$1" --thinking high
}
pi_claude_row pi-claude/claude-opus-5
assert_eq "$RC|$OUT" \
  "0|env CLAUDE_CONFIG_DIR='$H/.eclaude' pi --exclude-tools question --model pi-claude/claude-opus-5 --thinking high $PI_BRIEF" \
  "--print-launch-line on a record-less pi-claude overseer opens on its claude account" "$TMP_ROOT/err"
pi_claude_row claude-opus-5
assert_eq "$RC|$(sed -n 1p <<<"$ERR")|$OUT" "1|oversee-succeed: pi-account-unknown model=claude-opus-5|" \
  "--print-launch-line refuses a pi overseer whose model names no provider"
PIFLAGCTL="$(mutant_scripts piflagctl oversee-succeed)" || exit 1
mutate_file "$PIFLAGCTL/oversee-succeed" '    caller_model="$(ol_pi_model "$OL_KNOWN_MODEL" "$flag_model" "$reading_model")"' '    caller_model="$(ol_pi_model "$OL_KNOWN_MODEL" "" "$reading_model")"'
pi_claude_row pi-claude/claude-opus-5 "$PIFLAGCTL/oversee-succeed"
assert_eq "$RC|$(sed -n 1p <<<"$ERR")" "1|oversee-succeed: pi-account-unknown model=none" \
  "control: a caller that reads no --model word leaves a record-less pi overseer's account unknown"
# The same overseer judged at its turn end, with no --harness: its pane
# reports pi, which the pane reader maps to no one harness, so its reading
# names the harness, and the provider its model names the account.
mkdir -p "$TMP_ROOT/pibin"
cp "$(command -v sleep)" "$TMP_ROOT/pibin/pi"
pi_reading_row() { # [SUCCEED_BIN]
  tm kill-window -a -t fleet:0
  CALLER_PANE="$(tm new-window -d -t fleet:1 -P -F '#{pane_id}' "exec '$TMP_ROOT/pibin/pi' 100000")"
  mkdir -p "$MAILBOX_DIR"
  lane_context_record "$MAILBOX_DIR" pi 100000 1000000 pi-claude/claude-opus-5 "" "$SERVER_PID $CALLER_PANE"
  state none
  SUCCEED_BIN="${1:-}" run_succeed "CLAUDE_CONFIG_DIR=$H/.claude" --check-marks
}
pi_reading_row
assert_eq "$RC|$(tm display-message -p -t "$CALLER_PANE" '#{pane_current_command}')|$(judged)" \
  "0|pi|mark-reached kind=headroom value=1" \
  "--check-marks on a record-less pi-claude overseer takes pi from its reading and judges its claude account" "$TMP_ROOT/err"
PIPANECTL="$(mutant_scripts pipanectl oversee-succeed)" || exit 1
mutate_file "$PIPANECTL/oversee-succeed" '      claude | codex | copilot | pi) CALLER_HARNESS="$reading_harness" ;;' '      claude | codex | copilot) CALLER_HARNESS="$reading_harness" ;;'
pi_reading_row "$PIPANECTL/oversee-succeed"
assert_eq "$RC|$(sed -n 1p <<<"$ERR")" "1|oversee-succeed: harness-unnamed pane=$CALLER_PANE" \
  "control: a reading harness naming no pi leaves a pi pane unnamed"
PIREADCTL="$(mutant_scripts pireadctl oversee-succeed)" || exit 1
mutate_file "$PIREADCTL/oversee-succeed" '    caller_model="$(ol_pi_model "$OL_KNOWN_MODEL" "$flag_model" "$reading_model")"' '    caller_model="$(ol_pi_model "$OL_KNOWN_MODEL" "$flag_model" "")"'
SUCCEED_BIN="$PIREADCTL/oversee-succeed" run_succeed "CLAUDE_CONFIG_DIR=$H/.claude" --check-marks
assert_eq "$RC|$(judged)" "0|mark-unmeasured kind=headroom reason=headroom-none succession=on" \
  "control: a caller that ignores the pi reading's model leaves the account unjudged" "$TMP_ROOT/err"

# A bare --model word beside a reading naming pi-claude/<id>: the reading
# names the account, so the turn-end judgement and the succession it asks for
# both reach the headroom mark on the claude account, whose Opus window is
# spent, and no successor has a seat.
pi_reading_row
assert_eq "$RC|$(judged)" "0|mark-reached kind=headroom value=1" \
  "--check-marks on a pi reading naming pi-claude reaches the headroom mark" "$TMP_ROOT/err"
pi_bare_flag_row() { # [SUCCEED_BIN]
  SUCCEED_BIN="${1:-}" run_succeed "CLAUDE_CONFIG_DIR=$H/.claude" --harness pi -- --model claude-opus-5 --thinking high
}
pi_bare_flag_row
assert_eq "$RC|$(sed -n 1p <<<"$ERR" | awk '{print $2}')|$(grep -o 'mark=[a-z]*' <<<"$(sed -n 1p <<<"$ERR")")" \
  "3|no-lane-qualifies|mark=headroom" \
  "the succession beside a bare --model word reads the reading's claude account"
PIBARECTL="$(mutant_scripts pibarectl lib/overseer-launch.sh)" || exit 1
mutate_file "$PIBARECTL/lib/overseer-launch.sh" \
  '  for m in "$@"; do [[ "$m" != ?*/?* ]] || { printf '"'"'%s\n'"'"' "$m"; return 0; }; done' ''
pi_bare_flag_row "$PIBARECTL/oversee-succeed"
assert_eq "$RC|$(sed -n 1p <<<"$OUT" | awk '{print $2}')" "0|context-unmeasured" \
  "control: a bare --model word taken over the reading leaves the succession's account unmeasured"

# The settings a pi successor would compact under refuse its line, as they
# refuse a pi lane's launch.
jq -n '{compaction: {enabled: true}}' > "$PI_AGENT/settings.json"
pi_print_row
assert_eq "$RC|$(sed -n 1p <<<"$ERR")" \
  "1|oversee-succeed: pi-handoff-unmarked reason=compaction-on file=$PI_AGENT/settings.json" \
  "--print-launch-line refuses a pi line whose settings leave compaction on"
jq -n '{compaction: {enabled: false}}' > "$PI_AGENT/settings.json"
# A settings file pi cannot read leaves compaction unjudged, and a carrier
# sending no window leaves the mark nothing to be read against: each refuses.
printf '{"compaction": {' > "$PI_AGENT/settings.json"
pi_print_row
assert_eq "$RC|$(sed -n 1p <<<"$ERR")" \
  "1|oversee-succeed: pi-handoff-unmarked reason=settings-unreadable file=$PI_AGENT/settings.json" \
  "--print-launch-line refuses a pi line whose settings cannot be read"
jq -n '{compaction: {enabled: false}}' > "$PI_AGENT/settings.json"
PI_CARRIER="$PI_AGENT/packages/@vanillagreen/pi-hooks/extensions/stop.ts"
printf 'payload.stop = true;\n' > "$PI_CARRIER"
pi_print_row
assert_eq "$RC|$(sed -n 1p <<<"$ERR")" \
  "1|oversee-succeed: pi-handoff-unmarked reason=no-window-read dir=$(tm display-message -p -t "$CALLER_PANE" '#{pane_current_path}')" \
  "--print-launch-line refuses a pi line whose pi-hooks carrier sends no window"
printf 'payload.context_window = usage.contextWindow;\n' > "$PI_CARRIER"

# --- a dead-pane relaunch -------------------------------------------------
# The relaunched session is identified by the record of the line it replays:
# the pending successor's where that is the line, the dead session's own
# otherwise. Its first watch start then prints a line on a pane whose command
# names no harness and which has no reading yet.
DEAD_LINE="claude -n overseer 'relaunched from the record'"
printf '%s\n' "$DEAD_LINE" > "$TMP_ROOT/line-file"
# dead_relaunch EXTRA_JSON [SUCCEED_BIN] — a dead pane the record names with
# EXTRA_JSON merged over its record, relaunched; sets SUCC_PANE to the pane the
# record then names, DEAD_PANE_CWD to the dead pane's own directory and
# SUCC_CWD to the successor pane's.
dead_relaunch() {
  local dead
  new_caller claude
reading "Fable 5.1"
  dead="$(tm new-window -d -t fleet:5 -P -F '#{pane_id}' 'exec sleep 100000')"
  DEAD_PANE_CWD="$(tm display-message -p -t "$dead" '#{pane_current_path}')"
  state "$(record "$dead" "$H/.eclaude" fable "$1")"
  SUCCEED_BIN="${2:-}" run_succeed "CLAUDE_CONFIG_DIR=$H/.claude" --dead-pane "$dead" --line-file "$TMP_ROOT/line-file" --wait-secs 20
  SUCC_PANE="$(jq -r '.overseer.pane' "$FLEET_STATE")"
  SUCC_CWD="$(tm display-message -p -t "$SUCC_PANE" '#{pane_current_path}')"
}
# print_on_successor — the successor pane's own --print-launch-line.
print_on_successor() {
  CALLER_PANE="$SUCC_PANE" run_succeed "CLAUDE_CONFIG_DIR=$H/.claude" --print-launch-line -- "$BYPASS"
}
OWN="$(jq -cn --arg line "$DEAD_LINE" '{launch_line: $line}')"
PENDING_OWN="$(jq -cn --arg line "$DEAD_LINE" --arg a "$H/.claude" '{launch_line: "the dead session line",
  pending: {launch_line: $line, harness: "claude", account: $a, home: $a, model: "claude-opus-5", effort: "low", cwd: null}}')"
for row in \
  "$OWN|$H/.eclaude|fable|high|the dead session's own line" \
  "$PENDING_OWN|$H/.claude|claude-opus-5|low|a pending successor's line" \
  ; do
  IFS='|' read -r row_extra row_account row_model row_effort row_what <<<"$row"
  dead_relaunch "$row_extra"
  assert_eq "$RC|$(jq -r '.overseer | [.harness, .account, .model, .effort, (.pending // "none")] | join(" ")' "$FLEET_STATE")" \
    "0|claude $row_account $row_model $row_effort none" \
    "--dead-pane over $row_what records the identity that line was built with" "$TMP_ROOT/err"
  print_on_successor
  assert_eq "$RC|$OUT" "0|env CLAUDE_CONFIG_DIR='$row_account' claude -n overseer --model $row_model --effort $row_effort $LEAD $BYPASS '$BRIEF'" \
    "and the relaunched session's own print over $row_what reads its record" "$TMP_ROOT/err"
done
# The control: a relaunch that records no identity leaves its session's print
# to a screen that names nothing.
DEADCTL="$(mutant_scripts deadctl oversee-succeed)" || exit 1
mutate_file "$DEADCTL/oversee-succeed" '! ol_record_line_identity "$cmd"; then' '! ol_identity "" "" "" "" "" ""; then'
dead_relaunch "$OWN" "$DEADCTL/oversee-succeed"
print_on_successor
assert_eq "$RC|$(sed -n 1p <<<"$ERR")" "1|oversee-succeed: harness-unnamed pane=$SUCC_PANE" \
  "control: a relaunch that records no identity leaves the next print refused"
# A relaunch of a pending successor opens in the directory that successor was
# built for, the one its record then names, not the dead pane's own.
DEAD_CWD="$TMP_ROOT/dead-cwd"
mkdir -p "$DEAD_CWD"
DEAD_CWD="$(cd "$DEAD_CWD" && pwd -P)"
PENDING_CWD="$(jq -c --arg cwd "$DEAD_CWD" '.pending.cwd = $cwd' <<<"$PENDING_OWN")"
dead_relaunch "$PENDING_CWD"
assert_eq "$RC|$SUCC_CWD|$(jq -r '.overseer.cwd' "$FLEET_STATE")" "0|$DEAD_CWD|$DEAD_CWD" \
  "--dead-pane over a pending successor opens in the directory it records"
DEADCWDCTL="$(mutant_scripts deadcwdctl oversee-succeed)" || exit 1
mutate_file "$DEADCWDCTL/oversee-succeed" '[[ -z "$replay_cwd" ]] || CALLER_PATH="$replay_cwd"' ':'
dead_relaunch "$PENDING_CWD" "$DEADCWDCTL/oversee-succeed"
assert_eq "$RC|$SUCC_CWD" "0|$DEAD_PANE_CWD" \
  "control: a relaunch that ignores the replayed directory opens in the dead pane's"

# --- the pending successor, as a succession writes it ---------------------
# A workflow-state stand-in snapshots the record at the moment the succession
# writes its pending successor, before that window opens. The caller's record
# names .eclaude, at its trigger, and a directory of its own; the preference's
# entry picks .claude on its own model and effort.
RECORDED_CWD="$TMP_ROOT/recorded-cwd"
mkdir -p "$RECORDED_CWD"
RECORDED_CWD="$(cd "$RECORDED_CWD" && pwd -P)"
# pending_run SCRIPTS_DIR — that succession over SCRIPTS_DIR with the stand-in;
# sets SNAP to the record the pending write left, CALLER_CWD to the caller
# pane's own directory and SUCC_CWD to the successor pane's.
pending_run() {
  local dir="$1"
  rm -f -- "${dir:?}/workflow-state" "${TMP_ROOT:?}/pending.snap"
  cat > "$dir/workflow-state" <<STUB
#!/usr/bin/env bash
"$SRC_DIR/workflow-state" "\$@" || exit
[[ "\$1 \$2 \$3" != "set oversee overseer.pending" ]] || jq -c .overseer "$FLEET_STATE" > "$TMP_ROOT/pending.snap"
STUB
  chmod +x "$dir/workflow-state"
  new_caller claude
reading "Fable 5.1"
  CALLER_CWD="$(tm display-message -p -t "$CALLER_PANE" '#{pane_current_path}')"
  state "$(record "$CALLER_PANE" "$H/.eclaude" fable "$(jq -cn --arg cwd "$RECORDED_CWD" '{cwd: $cwd}')")"
  SUCCEED_BIN="$dir/oversee-succeed" PREFERENCE=claude:fable-next:low run_succeed "CLAUDE_CONFIG_DIR=$H/.claude" --wait-secs 20 -- "$BYPASS"
  SNAP="$(cat -- "$TMP_ROOT/pending.snap" 2>/dev/null || echo none)"
  SUCC_CWD="$(tm display-message -p -t "$(jq -r '.overseer.pane' "$FLEET_STATE")" '#{pane_current_path}')"
}
SUCC_LINE="env CLAUDE_CONFIG_DIR='$H/.claude' claude -n overseer --model fable-next --effort low $LEAD $BYPASS '$BRIEF'"
pending_run "$(mutant_scripts pendingrun)"
assert_eq "$RC|$(jq -r '.pending | [.launch_line, .harness, .account, .model, .effort, .cwd] | join("|")' <<<"$SNAP")" \
  "0|$SUCC_LINE|claude|$H/.claude|fable-next|low|$RECORDED_CWD" \
  "a succession writes its successor's line and identity as pending before the window opens" "$TMP_ROOT/err"
assert_eq "$(jq -r '[.account, .model, .launch_line] | join("|")' <<<"$SNAP")" "$H/.eclaude|fable|recorded" \
  "and leaves the caller's own account, model and line as they were"
assert_eq "$SUCC_CWD" "$RECORDED_CWD" "the successor opens in the directory the caller's record names"
# The pending rule's producer control: a pending write under another key leaves
# a death mid-succession nothing to replay.
PENDWCTL="$(mutant_scripts pendwctl lib/overseer-launch.sh)" || exit 1
mutate_file "$PENDWCTL/lib/overseer-launch.sh" '$identity + {launch_line: $line}' '$identity + {line: $line}'
pending_run "$PENDWCTL"
assert_eq "$RC|$(jq -r '.pending.launch_line // "none"' <<<"$SNAP")" "0|none" \
  "control: a pending write under another key records no line to replay"
# The directory rule's control: a caller that ignores its recorded directory
# opens the successor in the pane's own.
CWDCTL="$(mutant_scripts cwdctl oversee-succeed)" || exit 1
mutate_file "$CWDCTL/oversee-succeed" '  [[ -z "$OL_KNOWN_CWD" ]] || CALLER_PATH="$OL_KNOWN_CWD"' '  :'
pending_run "$CWDCTL"
assert_eq "$RC|$SUCC_CWD" "0|$CALLER_CWD" \
  "control: a caller that ignores its recorded directory opens the successor in the pane's"
# A session record write the state refuses is a notice here: the succession
# commits, the caller's window closed and the successor in its slot.
recordfail_run() { # SCRIPTS_DIR
  local dir="$1"
  rm -f -- "${dir:?}/workflow-state" "${TMP_ROOT:?}/record-refused"
  cat > "$dir/workflow-state" <<STUB
#!/usr/bin/env bash
if [[ "\$1 \$2 \$3" == "set oversee overseer" && ! -e "$TMP_ROOT/record-refused" ]]; then
  touch "$TMP_ROOT/record-refused"; echo 'fixture: record write refused' >&2; exit 1
fi
exec "$SRC_DIR/workflow-state" "\$@"
STUB
  chmod +x "$dir/workflow-state"
  new_caller claude
  reading "Fable 5.1"
  state "$(record "$CALLER_PANE" "$H/.eclaude" fable)"
  SUCCEED_BIN="$dir/oversee-succeed" PREFERENCE=claude:fable-next:low run_succeed "CLAUDE_CONFIG_DIR=$H/.claude" --wait-secs 20 -- "$BYPASS"
  CALLER_LISTED="$(tm list-panes -a -F '#{pane_id}' | grep -cxF -- "$CALLER_PANE" || true)"
}
recordfail_run "$(mutant_scripts recordfail)"
assert_eq "$RC|$(grep -c '^oversee-succeed: record-unwritten field=overseer step=write$' <<<"$ERR")|$CALLER_LISTED" \
  "0|1|0" \
  "a record write the state refuses is a notice, and the succession commits" "$TMP_ROOT/err"
RECNOTICECTL="$(mutant_scripts recnoticectl oversee-succeed)" || exit 1
mutate_file "$RECNOTICECTL/oversee-succeed" '      message record-unwritten field=overseer step=write >&2' '      return 1'
recordfail_run "$RECNOTICECTL"
assert_eq "$RC|$CALLER_LISTED" "1|1" \
  "control: a hook that refuses on the failed record write keeps the caller running"

# --- the succession -------------------------------------------------------
# A live succession judges the account and model its record names: .eclaude at
# the trigger fires the headroom mark, and on the record's Opus the caller
# entry finds no claude account with room, where the pane and the environment
# alone would have kept this session running on .claude.
new_caller claude
reading "Fable 5.1"
state "$(record "$CALLER_PANE" "$H/.eclaude" claude-opus-5)"
run_succeed "CLAUDE_CONFIG_DIR=$H/.claude"
assert_eq "$RC|$(sed -n 1p <<<"$ERR" | grep -o '^oversee-succeed: no-lane-qualifies .* mark=headroom')|$(tm list-windows -t fleet -F '#{window_name}' | grep -c '^overseer$' || true)" \
  "3|oversee-succeed: no-lane-qualifies entries=0 fallback=claude walled=2 unmeasured=0 mark=headroom|0" \
  "a succession is judged on its record's account and model, and opens nothing where none has room"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
