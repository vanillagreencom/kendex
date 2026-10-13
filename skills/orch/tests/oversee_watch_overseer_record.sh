#!/usr/bin/env bash
# Tests for oversee-watch's overseer record contract.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

# shellcheck source=lib/oversee-watch-harness.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/oversee-watch-harness.sh"
# mutant_scripts and mutate_file, the two halves of the one control below.
# shellcheck source=lib/growth-state.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/growth-state.sh"
# The fleet log's `at` is written by `workflow-state append-file`, not by the
# publisher here, so a row that checks it reads the stamp back through the
# same ladder every other reader of that field uses.
# shellcheck source=../scripts/lib/date-ladder.sh
source "$REPO_ROOT/skills/orch/scripts/lib/date-ladder.sh"
# OL_DEFAULT_PREFERENCE, the ladder an unset preference walks, for the mark
# row that reads it back.
# shellcheck source=../scripts/lib/overseer-launch.sh
source "$REPO_ROOT/skills/orch/scripts/lib/overseer-launch.sh"

# The pane, the oversee-succeed stub, overseer_case and run.
# shellcheck source=lib/overseer-watch-case.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/overseer-watch-case.sh"


# --- recording the line while the overseer is alive ------------------------
# The first watch of a fleet: no record, so the pane, its window and the line
# `oversee-succeed --print-launch-line` builds are written before anything
# needs them.
overseer_case record_first_start idle
printf '{"triaged":[]}\n' > "$STUB_DIR/oversee-state.json"
printf '%s\n' "$LINE" > "$STUB_DIR/succeed.line"
run TMUX_PANE="$PANE" -- --max-loops 1 --handoff tmp/handoffs/FLEET.md --harness codex -- --verbose --model fable
assert_eq "server=$(recorded server) pane=$(recorded pane) window=$(recorded window)" "server=7000 pane=$PANE window=$WINDOW" \
  "the first start records the tmux server, pane and window" "$ERR"
assert_eq "$(recorded launch_line)" "$LINE" "and the line a successor of it would run" "$ERR"
ROWS_PATH="$CASE_REPO_ROOT/tmp/lane-mail/overseer/session-7000-${PANE#%}.jsonl"
assert_eq "$(recorded session_rows)" "$ROWS_PATH" "and the file its session rows land in" "$ERR"
assert_eq "$(recorded server_start)" "1790000000" "and the start of the server holding the pane" "$ERR"
assert_eq "$(recorded server_socket)" "fake" "and the socket its tmux calls reach" "$ERR"
SOCKETREC_CTL="$(mutant_scripts socketrec-ctl/orch lib/watch-overseer-record.sh)" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/socketrec-ctl/github"
mutate_file "$SOCKETREC_CTL/lib/watch-overseer-record.sh" '+ {server_socket: $socket}' '+ {}'
overseer_case record_first_start_socket_control idle
printf '{"triaged":[]}\n' > "$STUB_DIR/oversee-state.json"
printf '%s\n' "$LINE" > "$STUB_DIR/succeed.line"
WATCH_BIN="$SOCKETREC_CTL/oversee-watch" run TMUX_PANE="$PANE" -- --max-loops 1 -- --model fable
assert_eq "$(recorded server_socket)" "none" "control: a watch start without the socket cannot identify a foreign server" "$ERR"
# The controls: a start that records no rows file leaves a hand-started
# overseer judged from its pane alone, and one that drops the server start
# records none.
ROWSREC_CTL="$(mutant_scripts rowsrec-ctl/orch lib/watch-overseer-record.sh)" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/rowsrec-ctl/github"
mutate_file "$ROWSREC_CTL/lib/watch-overseer-record.sh" 'launch_line: $line, session_rows: $rows,' 'launch_line: $line,'
overseer_case record_first_start_mutant idle
printf '{"triaged":[]}\n' > "$STUB_DIR/oversee-state.json"
printf '%s\n' "$LINE" > "$STUB_DIR/succeed.line"
WATCH_BIN="$ROWSREC_CTL/oversee-watch" run TMUX_PANE="$PANE" -- --max-loops 1 -- --model fable
assert_eq "$(recorded session_rows)" "none" "control: a start that drops the field records no rows file" "$ERR"
STARTREC_CTL="$(mutant_scripts startrec-ctl/orch lib/watch-overseer-record.sh)" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/startrec-ctl/github"
mutate_file "$STARTREC_CTL/lib/watch-overseer-record.sh" 'server_start: ($start | tonumber)})' 'server_start: null})'
overseer_case record_first_start_mutant idle
printf '{"triaged":[]}\n' > "$STUB_DIR/oversee-state.json"
printf '%s\n' "$LINE" > "$STUB_DIR/succeed.line"
WATCH_BIN="$STARTREC_CTL/oversee-watch" run TMUX_PANE="$PANE" -- --max-loops 1 -- --model fable
assert_eq "$(recorded server_start)" "none" "control: a start that drops the server start records none" "$ERR"
overseer_case record_first_start idle
printf '{"triaged":[]}\n' > "$STUB_DIR/oversee-state.json"
printf '%s\n' "$LINE" > "$STUB_DIR/succeed.line"
run TMUX_PANE="$PANE" -- --max-loops 1 --handoff tmp/handoffs/FLEET.md --harness codex -- --verbose --model fable
assert_eq "$(grep -- '^--print-launch-line' "$STUB_DIR/succeed.args")" \
  "--print-launch-line --handoff tmp/handoffs/FLEET.md --harness codex -- --verbose --model fable" \
  "the handoff path, the harness a node pane cannot name, and the overseer's own flags reach the builder" "$ERR"
assert_eq "$(succeed_calls --print-launch-line)" "1" \
  "and the line is built once, not once per pass" "$ERR"

# A notice a successful print writes on stderr reaches the watch's stderr and
# never the recorded line, which a dead-pane relaunch types into a shell.
print_notice_run() { # [WATCH_BIN]
  overseer_case "record_print_notice${1:+_mutant}" idle
  printf '{"triaged":[]}\n' > "$STUB_DIR/oversee-state.json"
  printf '%s\n' "$LINE" > "$STUB_DIR/succeed.line"
  touch "$STUB_DIR/succeed.print-notice"
  WATCH_BIN="${1:-}" run TMUX_PANE="$PANE" -- --max-loops 1 -- --model fable
}
print_notice_run
assert_eq "line=$(recorded launch_line) notice=$(grep -c "^oversee-succeed: record-unread pane=$PANE\$" "$ERR")" \
  "line=$LINE notice=1" "a print's notice goes to the watch's stderr, and the line stays the command" "$ERR"
# The control: a capture that keeps both streams records the notice as part of the line.
NOTICE_MUTANT="$TMP_ROOT/notice-mutant"
mkdir -p "$NOTICE_MUTANT/orch"
cp -R "$REPO_ROOT/skills/orch/scripts" "$NOTICE_MUTANT/orch/scripts"
cp -R "$REPO_ROOT/skills/mailbox" "$NOTICE_MUTANT/mailbox"
ln -s "$REPO_ROOT/skills/github" "$NOTICE_MUTANT/github"
FROM='  line="$("$SUCCEED" --print-launch-line "${OVERSEER_LAUNCH_ARGS[@]}" 2>"$errf")" || rc=$?'
assert_eq "$(grep -cxF -- "$FROM" "$REPO_ROOT/skills/orch/scripts/lib/watch-overseer-record.sh")" "1" \
  "control: the print capture is one line of the record library"
FROM="$FROM" TO='  line="$("$SUCCEED" --print-launch-line "${OVERSEER_LAUNCH_ARGS[@]}" 2>&1)" || rc=$?' \
  awk '$0 == ENVIRON["FROM"] { print ENVIRON["TO"]; next } { print }' \
  "$REPO_ROOT/skills/orch/scripts/lib/watch-overseer-record.sh" > "$NOTICE_MUTANT/orch/scripts/lib/watch-overseer-record.sh"
print_notice_run "$NOTICE_MUTANT/orch/scripts/oversee-watch"
assert_eq "$(recorded launch_line)" "$LINE"$'\n'"oversee-succeed: record-unread pane=$PANE" \
  "control: a capture of both streams records the notice in the line" "$ERR"

# A manual replacement can reuse the same durable tmux server, pane and window.
# Its new watch owns the command and replaces the former session's bypass flag.
overseer_case record_same_pane_restart idle
state_with "$BYPASS_LINE"
printf '%s\n' "$LINE" > "$STUB_DIR/succeed.line"
run TMUX_PANE="$PANE" -- --max-loops 1 -- --model fable
assert_eq "server=$(recorded server) pane=$(recorded pane) window=$(recorded window) line=$(recorded launch_line)" \
  "server=7000 pane=$PANE window=$WINDOW line=$LINE" \
  "a same-pane replacement records its current restricted command" "$ERR"
assert_eq "$(succeed_calls --print-launch-line)" "1" \
  "the live replacement derives its command once at watch startup" "$ERR"

# The session record `oversee launch`, `oversee register` or a succession
# wrote before this session's first turn: its runtime, generation and account
# are kept where the record names this pane on this server, since the watch
# observes the pane and the launch line and nothing about the generation.
# The record is bound to the stub server's start, as every writer binds it.
keeps_generation_run() { # NAME [WATCH_BIN]
  overseer_case "$1" idle
  jq -n --arg pane "$PANE" --arg window "$WINDOW" \
    '{triaged: [], overseer: {runtime: "tmux", generation: 3, account: "/home/me/.claude", server: "7000", pane: $pane, window: $window, launch_line: "old",
      harness: "claude", home: "/home/me/.claude", model: "fable", effort: "high", cwd: "/home/me/kendex",
      server_start: 1790000000, pending: {launch_line: "pending", account: "/home/me/.eclaude"}}}' \
    > "$STUB_DIR/oversee-state.json"
  printf '%s\n' "$LINE" > "$STUB_DIR/succeed.line"
  [[ -z "${START_FAIL:-}" ]] || touch "$STUB_DIR/start-fail-$PANE"
  WATCH_BIN="${2:-}" run TMUX_PANE="$PANE" -- --max-loops 1 -- --model fable
}
keeps_generation_run record_keeps_generation
assert_eq "runtime=$(recorded runtime) generation=$(recorded generation) account=$(recorded account) line=$(recorded launch_line)" \
  "runtime=tmux generation=3 account=/home/me/.claude line=$LINE" \
  "a start on the recorded pane keeps the session record's runtime, generation and account and replaces the line" "$ERR"
assert_eq "harness=$(recorded harness) home=$(recorded home) model=$(recorded model) effort=$(recorded effort) cwd=$(recorded cwd) pending=$(recorded pending)" \
  "harness=claude home=/home/me/.claude model=fable effort=high cwd=/home/me/kendex pending=none" \
  "and keeps its launch identity, dropping a pending successor as it replaces the line" "$ERR"
# A start whose server start cannot be read writes nothing: judged as no
# start, this pane's own bound record would read as another session's and
# lose its generation and launch identity.
START_FAIL=1 keeps_generation_run record_start_unread
assert_eq "generation=$(recorded generation) harness=$(recorded harness) line=$(recorded launch_line) pending=$(recorded pending | jq -r .launch_line) notice=$(grep -c "^oversee-watch: overseer-unrecorded pane=$PANE step=server-start held=unread\$" "$ERR")" \
  "generation=3 harness=claude line=old pending=pending notice=1" \
  "a start whose server start cannot be read leaves the record as it stood and says so" "$ERR"
# Its control: a start that takes an unread start as none drops this pane's
# generation and launch identity.
UNREADSTART_CTL="$(mutant_scripts unreadstart-ctl/orch lib/watch-overseer-record.sh)" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/unreadstart-ctl/github"
mutate_file "$UNREADSTART_CTL/lib/watch-overseer-record.sh" \
  '  if ! start="$(ol_session_start "$server" "$pane")"; then' '  if ! start="$(ol_session_start "$server" "$pane")" && false; then'
mutate_file "$UNREADSTART_CTL/lib/watch-overseer-record.sh" \
  'server_start: ($start | tonumber)})' 'server_start: (if $start == "" then null else $start | tonumber end)})'
START_FAIL=1 keeps_generation_run record_start_unread_mutant "$UNREADSTART_CTL/oversee-watch"
assert_eq "generation=$(recorded generation) harness=$(recorded harness)" "generation=none harness=none" \
  "control: a start that takes an unread start as none drops this pane's generation and launch identity" "$ERR"
# The record `oversee register` wrote before it recorded a launch identity
# (2568a672^:skills/orch/scripts/oversee): runtime, server, window, generation,
# account and pane, with no harness and no home. It takes the account as its
# home, as a claude record does: the turn-end hook binds the overseer's
# transcript to that home and reads no context without one. A codex home is
# its own directory and is never read off the account.
home_backfill() { # NAME HARNESS [WATCH_BIN]
  overseer_case "$1" idle
  jq -n --arg pane "$PANE" --arg window "$WINDOW" --arg harness "$2" \
    '{triaged: [], overseer: ({runtime: "tmux", server: "7000", server_start: 1790000000, window: $window, generation: 10, account: "/home/me/.claude", pane: $pane}
      + (if $harness == "" then {} else {harness: $harness} end))}' > "$STUB_DIR/oversee-state.json"
  printf '%s\n' "$LINE" > "$STUB_DIR/succeed.line"
  WATCH_BIN="${3:-}" run TMUX_PANE="$PANE" -- --max-loops 1 -- --model fable
}
home_backfill record_home_backfill ""
assert_eq "home=$(recorded home) account=$(recorded account)" "home=/home/me/.claude account=/home/me/.claude" \
  "a start over the record an older register wrote binds it to its account" "$ERR"
home_backfill record_home_claude claude
assert_eq "home=$(recorded home)" "home=/home/me/.claude" "a home-less claude record binds to its account too" "$ERR"
home_backfill record_home_codex codex
assert_eq "home=$(recorded home)" "home=none" "a home-less codex record keeps no home, its account not being one" "$ERR"
HOME_MUTANT="$TMP_ROOT/home-mutant"
mkdir -p "$HOME_MUTANT/orch"
cp -R "$REPO_ROOT/skills/orch/scripts" "$HOME_MUTANT/orch/scripts"
cp -R "$REPO_ROOT/skills/mailbox" "$HOME_MUTANT/mailbox"
ln -s "$REPO_ROOT/skills/github" "$HOME_MUTANT/github"
FROM='then .home = .account else . end'
assert_eq "$(grep -cF -- "$FROM" "$REPO_ROOT/skills/orch/scripts/lib/watch-overseer-record.sh")" "1" \
  "control: the home binding is one site of the record library"
FROM="$FROM" perl -pe 's/\Q$ENV{FROM}\E/then . else . end/' \
  "$REPO_ROOT/skills/orch/scripts/lib/watch-overseer-record.sh" > "$HOME_MUTANT/orch/scripts/lib/watch-overseer-record.sh"
home_backfill record_home_backfill_mutant "" "$HOME_MUTANT/orch/scripts/oversee-watch"
assert_eq "home=$(recorded home)" "home=none" "control: a start that binds no home leaves the hook reading no context" "$ERR"

# A record naming another pane is another session's: its generation is not
# this one's, so the start records only what it observes.
# Each part of that test, one row each: a record naming another pane on this
# server; one naming this pane id on another server, which is what a fleet
# state left by a previous tmux server holds, pane ids restarting at %0; and
# one naming this pane id on this pid, bound to an earlier server's start,
# which is what that state holds where the next server was handed the same
# pid. The stub's server started at 1790000000.
record_drops_run() { # SERVER PANE START [WATCH_BIN]
  overseer_case "record_drops_other_session_$1_$3${4:+_mutant}" idle
  jq -n --arg window "$WINDOW" --arg server "$1" --arg pane "$2" --arg start "$3" \
    '{triaged: [], overseer: {runtime: "tmux", generation: 3, account: "/home/me/.claude", server: $server, pane: $pane, window: $window, launch_line: "old",
      harness: "codex", model: "gpt-6-astra", server_start: ($start | tonumber)}}' \
    > "$STUB_DIR/oversee-state.json"
  printf '%s\n' "$LINE" > "$STUB_DIR/succeed.line"
  WATCH_BIN="${4:-}" run TMUX_PANE="$PANE" -- --max-loops 1 -- --model fable
}
for row in "7000|%4|1790000000|another pane" "7001|$PANE|1790000000|this pane id on another server" \
  "7000|$PANE|1789996400|this pane id on an earlier server handed the same pid"; do
  IFS='|' read -r row_server row_pane row_start row_what <<<"$row"
  record_drops_run "$row_server" "$row_pane" "$row_start"
  assert_eq "server=$(recorded server) pane=$(recorded pane) generation=$(recorded generation) account=$(recorded account) harness=$(recorded harness) model=$(recorded model) start=$(recorded server_start)" \
    "server=7000 pane=$PANE generation=none account=none harness=none model=none start=1790000000" \
    "a start over a record naming $row_what drops that session's generation, account and launch identity" "$ERR"
done
# A record naming this pane on this server with no start at all is the one a
# writer from before starts were recorded left for the session in this pane,
# which a start that read it as another session's stripped of its launch
# identity: the start keeps its generation and identity and binds it to this
# server's start.
startless_keeps_run() { # NAME [WATCH_BIN]
  overseer_case "$1" idle
  jq -n --arg pane "$PANE" --arg window "$WINDOW" \
    '{triaged: [], overseer: {runtime: "tmux", generation: 3, account: "/home/me/.codex", server: "7000", pane: $pane, window: $window, launch_line: "old",
      harness: "codex", home: "/home/me/.codex", model: "gpt-6-astra"}}' \
    > "$STUB_DIR/oversee-state.json"
  printf '%s\n' "$LINE" > "$STUB_DIR/succeed.line"
  WATCH_BIN="${2:-}" run TMUX_PANE="$PANE" -- --max-loops 1 -- --model fable
}
startless_keeps_run record_keeps_startless
assert_eq "generation=$(recorded generation) harness=$(recorded harness) home=$(recorded home) model=$(recorded model) start=$(recorded server_start)" \
  "generation=3 harness=codex home=/home/me/.codex model=gpt-6-astra start=1790000000" \
  "a start over a record naming this pane on this server with no start keeps its launch identity and binds it" "$ERR"
STARTLESSKEEP_CTL="$(mutant_scripts startlesskeep-ctl/orch lib/watch-overseer-record.sh)" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/startlesskeep-ctl/github"
mutate_file "$STARTLESSKEEP_CTL/lib/watch-overseer-record.sh" \
  'if ol_owns($server; $start; $pane) then . else {} end)' \
  'if ol_names($server; $start; $pane) then . else {} end)'
startless_keeps_run record_keeps_startless_mutant "$STARTLESSKEEP_CTL/oversee-watch"
assert_eq "generation=$(recorded generation) harness=$(recorded harness)" "generation=none harness=none" \
  "control: a start that reads a record with no start as another session's drops this pane's launch identity" "$ERR"
# The start test's control: ol_names without it keeps the earlier server's
# generation and launch identity for the session now in its pane id.
KEEPSTART_CTL="$(mutant_scripts keepstart-ctl/orch lib/overseer-launch.sh)" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/keepstart-ctl/github"
mutate_file "$KEEPSTART_CTL/lib/overseer-launch.sh" \
  '    and (.server_start | tostring) == $start;' '    and true;'
record_drops_run 7000 "$PANE" 1789996400 "$KEEPSTART_CTL/oversee-watch"
assert_eq "generation=$(recorded generation) harness=$(recorded harness)" "generation=3 harness=codex" \
  "control: without the start test a start keeps an earlier server's generation and launch identity" "$ERR"
# The merge's own start emptied: this pane's bound record reads as another
# session's, and its generation is dropped.
KEEPEMPTY_CTL="$(mutant_scripts keepempty-ctl/orch lib/watch-overseer-record.sh)" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/keepempty-ctl/github"
mutate_file "$KEEPEMPTY_CTL/lib/watch-overseer-record.sh" \
  '        | if ol_owns($server; $start; $pane) then . else {} end)' \
  '        | if ol_owns($server; ""; $pane) then . else {} end)'
keeps_generation_run record_keeps_generation_start_mutant "$KEEPEMPTY_CTL/oversee-watch"
assert_eq "generation=$(recorded generation)" "generation=none" \
  "control: a start judged on no start drops this pane's bound generation" "$ERR"
# The must-fail control: a start that replaces the object whole loses the
# generation the launcher wrote for this very pane.
RECORD_MUTANT="$TMP_ROOT/record-mutant"
mkdir -p "$RECORD_MUTANT/orch"
cp -R "$REPO_ROOT/skills/orch/scripts" "$RECORD_MUTANT/orch/scripts"
cp -R "$REPO_ROOT/skills/mailbox" "$RECORD_MUTANT/mailbox"
ln -s "$REPO_ROOT/skills/github" "$RECORD_MUTANT/github"
FROM='        | if ol_owns($server; $start; $pane) then . else {} end)'
assert_eq "$(grep -cxF -- "$FROM" "$REPO_ROOT/skills/orch/scripts/lib/watch-overseer-record.sh")" "1" \
  "control: the merge rule is one line of the record library"
FROM="$FROM" awk '$0 == ENVIRON["FROM"] { print "        | {})"; next } { print }' \
  "$REPO_ROOT/skills/orch/scripts/lib/watch-overseer-record.sh" > "$RECORD_MUTANT/orch/scripts/lib/watch-overseer-record.sh"
overseer_case record_keeps_generation_mutant idle
jq -n --arg pane "$PANE" --arg window "$WINDOW" \
  '{triaged: [], overseer: {runtime: "tmux", generation: 3, account: "/home/me/.claude", server: "7000", pane: $pane, window: $window, launch_line: "old",
    server_start: 1790000000}}' \
  > "$STUB_DIR/oversee-state.json"
printf '%s\n' "$LINE" > "$STUB_DIR/succeed.line"
WATCH_BIN="$RECORD_MUTANT/orch/scripts/oversee-watch" run TMUX_PANE="$PANE" -- --max-loops 1 -- --model fable
assert_eq "generation=$(recorded generation)" "generation=none" \
  "control: a start that replaces the object whole loses the generation" "$ERR"


printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
