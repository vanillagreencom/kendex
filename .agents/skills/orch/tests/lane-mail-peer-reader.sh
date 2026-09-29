#!/usr/bin/env bash
# lane-mail peer send and peer ask: whether the peer checkout's overseer
# mailbox has a reader, the notice written on stderr once the line lands. The
# reader is the one session the peer's fleet record names by tmux server and
# pane, bound to the server by its start time; each row builds a sender and a peer checkout, writes the peer's
# record, and drives the real script with a tmux stub whose pane list the row
# sets. What the pane judgement itself answers is tmux-pane-live.sh's subject,
# and what workflow-state --no-private-env reads is
# workflow-state-no-private-env.sh's; these rows assert how the send and the
# ask report each answer. The must-fail controls close the file, one per rule,
# each on a private copy of lane-mail.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd -P)"
LANE_MAIL="$REPO_ROOT/skills/orch/scripts/lane-mail"
WORKFLOW_STATE="$REPO_ROOT/skills/orch/scripts/workflow-state"
FIXTURE_HOST="$REPO_ROOT/skills/orch/tests/fixtures/lane-host"
# mktemp alone, so set -e stops the suite on its failure: nested in the cd,
# a failed mktemp would resolve to this directory and the trap would remove it.
TMP_ROOT="$(mktemp -d)"
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)"
LIVE=""
trap '[ -z "$LIVE" ] || kill "$LIVE" 2>/dev/null; rm -rf -- "${TMP_ROOT:?}"' EXIT

# shellcheck source=lib/assertions.sh
source "$TEST_DIR/lib/assertions.sh"
# shellcheck source=lib/growth-state.sh
source "$TEST_DIR/lib/growth-state.sh"

echo "=== lane-mail peer send and peer ask: reader ==="

# `list-panes -a` answers the file PANES holds, `<pid> <start> <pane>` rows;
# with no file, tmux has no server to ask. START is the running server's
# start time, and EARLIER an earlier server's that was handed the same pid.
STUB_BIN="$TMP_ROOT/bin"
PANES="$TMP_ROOT/panes"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/tmux" <<STUB
#!/bin/sh
[ "\$1" = list-panes ] || exit 1
[ -f "$PANES" ] || { echo "no server running" >&2; exit 1; }
cat "$PANES"
STUB
chmod +x "$STUB_BIN/tmux"

# A running server is a copy of sleep named tmux, which outlives every row
# and the trap stops, and a gone one a child that has exited.
mkdir -p "$TMP_ROOT/server"
cp -- "$(command -v sleep)" "$TMP_ROOT/server/tmux"
"$TMP_ROOT/server/tmux" 600 &
LIVE=$!
sleep 0 &
GONE=$!
wait "$GONE" || :
START=1790000000
EARLIER=1780000000

checkout() { # NAME
  mkdir -p "$TMP_ROOT/$1"
  git -C "$TMP_ROOT/$1" init -q
  git -C "$TMP_ROOT/$1" config gc.auto 0
  git -C "$TMP_ROOT/$1" config maintenance.auto false
  git -C "$TMP_ROOT/$1" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m base
}
checkout sender
PEER="$TMP_ROOT/peer"

# The peer's fleet record: `none` for no state file, `bad` for a state file
# its reader cannot parse, `bad-settings` for settings their loader refuses,
# and otherwise the `.overseer` object itself. Every peer carries a private
# env file that writes SENTINEL when it is sourced.
SENTINEL="$TMP_ROOT/sourced"
record() { # none|bad|bad-settings|JSON
  rm -rf -- "${PEER:?}" "$SENTINEL"
  checkout peer
  printf 'touch %q\n' "$SENTINEL" > "$PEER/.env.local"
  case "$1" in
    none) ;;
    bad-settings) printf '[env]\nX = unquoted\n' > "$PEER/kendex.settings.toml" ;;
    bad)
      (cd "$PEER" && "$WORKFLOW_STATE" --no-private-env init oversee >/dev/null)
      printf '{ not json\n' > "$(cd "$PEER" && "$WORKFLOW_STATE" --no-private-env path oversee)"
      ;;
    *)
      (cd "$PEER" && "$WORKFLOW_STATE" --no-private-env init oversee >/dev/null &&
        "$WORKFLOW_STATE" --no-private-env set oversee overseer "$1" >/dev/null)
      ;;
  esac
}

RC=0
OUT=""
LINES=0
# SEND_ENV holds the assignments a row adds to the sender's environment.
SEND_ENV=()
peer_call() { # VERB TEXT [ARGS...]
  local verb="$1" text="$2"
  shift 2
  printf '%s\n' "$text" > "$TMP_ROOT/msg.txt"
  RC=0
  OUT="$(cd "$TMP_ROOT/sender" && env -u TMUX -u TMUX_PANE -u ORCH_STATE_DIR PATH="$STUB_BIN:$PATH" \
    ${SEND_ENV[@]+"${SEND_ENV[@]}"} \
    "${LANE_MAIL_BIN:-$LANE_MAIL}" peer "$verb" --repo "$PEER" --file "$TMP_ROOT/msg.txt" "$@" 2>"$TMP_ROOT/err")" || RC=$?
  LINES="$(wc -l < "$PEER/tmp/lane-mail/overseer/to-lane.jsonl" | tr -d ' ')"
}
send() { peer_call send "$@"; }
first_err() { awk 'NR == 1' "$TMP_ROOT/err"; }
err_lines() { wc -l < "$TMP_ROOT/err" | tr -d ' '; }
fix_lines() { grep -c '^fix=.*oversee register' "$TMP_ROOT/err" || :; }
sourced() { if [ -e "$SENTINEL" ]; then echo sourced; else echo unsourced; fi; }
live_record() {
  record "{\"server\":\"$LIVE\",\"server_start\":$START,\"pane\":\"%9\"}"
  printf '%s %s %%9\n' "$LIVE" "$START" > "$PANES"
}

# RECORD|LISTING|FIRST STDERR LINE|FIX LINES|LABEL. LISTING `-` is no server
# to ask, and FIRST `-` is an empty stderr. No row sources the peer's private
# env file.
while IFS='|' read -r rec listing first fix label; do
  record "$rec"
  if [ "$listing" = - ]; then rm -f -- "$PANES"; else printf '%s\n' "$listing" > "$PANES"; fi
  send "$label"
  assert_eq "$RC ${OUT%% id=*} lines=$LINES" "0 lane-mail: sent item=overseer lines=1" \
    "the note lands and its receipt prints: $label" "$TMP_ROOT/err"
  assert_eq "$(first_err) fix=$(fix_lines) $(sourced)" "${first/#-/} fix=$fix unsourced" "$label" "$TMP_ROOT/err"
done <<EOF
none|-|lane-mail: no-reader=$PEER cause=unnamed|1|a peer with no fleet state names no reader
{"window":"@1"}|-|lane-mail: no-reader=$PEER cause=unnamed|1|a record naming no server and pane names no reader
{"server":"$LIVE","server_start":$START,"pane":"9"}|$LIVE $START %9|lane-mail: no-reader=$PEER cause=unnamed|1|a pane not spelled %N names no reader
{"server":"a$LIVE","server_start":$START,"pane":"%9"}|$LIVE $START %9|lane-mail: no-reader=$PEER cause=unnamed|1|a server not spelled as a pid names no reader
{"server":"$GONE","server_start":$START,"pane":"%9"}|$LIVE $START %9|lane-mail: no-reader=$PEER cause=pane-gone|1|a record naming a gone server names a pane that no longer runs
{"server":"$LIVE","server_start":$START,"pane":"%4"}|$LIVE $START %9|lane-mail: no-reader=$PEER cause=pane-gone|1|a record naming a pane its server no longer lists names no reader
{"server":"$LIVE","server_start":$EARLIER,"pane":"%9"}|$LIVE $START %9|lane-mail: no-reader=$PEER cause=pane-gone|1|a record naming an earlier server handed the same pid and pane names no reader
{"server":"$LIVE","server_start":$START,"pane":"%9"}|$LIVE $START %9|-|0|a record naming a live pane says nothing
{"server":"$LIVE","pane":"%9"}|$LIVE $START %9|lane-mail: no-reader=$PEER cause=unnamed|1|a record binding its server to no start names no reader
{"server":"$LIVE","server_start":$START,"pane":"%9"}|4242 $START %9|lane-mail: reader-unjudged=$PEER cause=server|0|a pane on a server this shell cannot ask is unjudged
bad|-|lane-mail: reader-unjudged=$PEER cause=state|0|a fleet state its reader cannot parse is unjudged
bad-settings|-|lane-mail: reader-unjudged=$PEER cause=state|0|peer settings their loader refuses are unjudged
EOF

# Under a state notice stands the keyed first line of the reader's own
# refusal, and nothing else the reader printed.
record bad
send 'Unkeyed words.'
assert_eq "$(err_lines)" "2" "words the state reader did not key stay off the notice" "$TMP_ROOT/err"
record bad-settings
send 'Keyed words.'
assert_eq "$(awk 'NR == 3 { print $1 " " $2 }' "$TMP_ROOT/err") lines=$(err_lines)" \
  "kendex-env: value-syntax lines=3" "the loader's keyed refusal stands under the notice, alone" "$TMP_ROOT/err"

# The sender's own state directory names nothing of the peer's.
live_record
SEND_ENV=("ORCH_STATE_DIR=$TMP_ROOT/sender-state")
send 'Own state dir.'
SEND_ENV=()
assert_eq "$(first_err)" "" "a sender's ORCH_STATE_DIR does not move the peer's record" "$TMP_ROOT/err"

# An answer is read by the asker's wait, which names no session.
record none
send 'Answer.' --re 1790000000-1-1
assert_eq "$RC lines=$LINES $(first_err)" "0 lines=1 " "an answer to a peer's ask says nothing of a reader" "$TMP_ROOT/err"

# An ask lands one line in the peer's mailbox and one in the asker's own
# record, prints its id, and is judged as a send is.
ASKS=0
ask() { # TEXT
  peer_call ask "$1"
  ASKS=$((ASKS + 1))
  local own
  own="$(wc -l < "$TMP_ROOT/sender/tmp/lane-mail/overseer/to-overseer.jsonl" | tr -d ' ')"
  assert_eq "$RC ${OUT%%=*} lines=$LINES own=$own" "0 id lines=1 own=$ASKS" \
    "the ask lands, its id prints and the asker records it: $1" "$TMP_ROOT/err"
}
record none
ask 'an ask to a peer with no fleet state names no reader'
assert_eq "$(first_err) fix=$(fix_lines) $(sourced)" "lane-mail: no-reader=$PEER cause=unnamed fix=1 unsourced" \
  "an ask to a peer with no fleet state names no reader" "$TMP_ROOT/err"
live_record
ask 'an ask to a peer naming a live pane says nothing'
assert_eq "$(first_err)" "" "an ask to a peer naming a live pane says nothing" "$TMP_ROOT/err"

# A hosted peer keeps its record and tmux server on its own host.
REMOTE_ROOT=/srv/peer
REMOTE_DISK="$TMP_ROOT/remote"
mkdir -p "$REMOTE_DISK$REMOTE_ROOT/tmp/lane-mail/overseer"
hosted_send() { # TEXT
  printf '%s\n' "$1" > "$TMP_ROOT/msg.txt"
  RC=0
  OUT="$(cd "$TMP_ROOT/sender" && env -u TMUX -u TMUX_PANE ORCH_LANE_HOST="$FIXTURE_HOST" \
    LANE_HOST_STUB_LOG="$TMP_ROOT/host.log" LANE_HOST_STUB_DIR="$REMOTE_DISK" \
    LANE_HOST_STUB_LIB="$REPO_ROOT/skills/orch/scripts/lib" \
    "${LANE_MAIL_BIN:-$LANE_MAIL}" peer send --repo "$REMOTE_ROOT" --host --file "$TMP_ROOT/msg.txt" 2>"$TMP_ROOT/err")" || RC=$?
}
hosted_send 'Hosted.'
assert_eq "$RC ${OUT%% id=*} $(first_err)" \
  "0 lane-mail: sent item=overseer lane-mail: reader-unjudged=$REMOTE_ROOT cause=hosted" \
  "a hosted peer's reader is unjudged" "$TMP_ROOT/err"

# --- must-fail controls ------------------------------------------------------
# mutant NAME OLD NEW: a private lane-mail with OLD, which occurs once,
# replaced by NEW, beside links to the shipped rest; LANE_MAIL_BIN runs it.
mutant() {
  local dir
  dir="$(mutant_scripts "mutants/$1" lane-mail)" || exit 1
  mutate_file "$dir/lane-mail" "$2" "$3"
  LANE_MAIL_BIN="$dir/lane-mail"
}

mutant no-judgement '      [ -n "$MSGID" ] || lm_peer_reader' '      [ -n "$MSGID" ] || :'
record none
send 'Unjudged send.'
assert_eq "$(first_err)" "" "control: without the judgement a send to a checkout no session reads says nothing"

mutant answer-judged '      [ -n "$MSGID" ] || lm_peer_reader' '      lm_peer_reader'
record none
send 'Judged answer.' --re 1790000000-1-1
assert_eq "$(first_err)" "lane-mail: no-reader=$PEER cause=unnamed" \
  "control: judging an answer tells its sender nobody reads what the asker's wait reads"

mutant ask-unjudged '      lm_peer_reader' '      :'
record none
ask 'control: an unjudged ask lands'
assert_eq "$(first_err)" "" "control: without the judgement an ask to a checkout no session reads says nothing"

mutant sources-peer '"$SCRIPT_DIR/workflow-state" --no-private-env "$@"' '"$SCRIPT_DIR/workflow-state" "$@"'
live_record
send 'Sourced.'
assert_eq "$(sourced)" "sourced" "control: a reader loading the peer's full ladder runs its private env file"

mutant sender-state-dir '(cd -- "$ROOT" && env -u ORCH_STATE_DIR ' '(cd -- "$ROOT" && env '
live_record
SEND_ENV=("ORCH_STATE_DIR=$TMP_ROOT/sender-state")
send 'Sender state dir.'
SEND_ENV=()
assert_eq "$(first_err)" "lane-mail: no-reader=$PEER cause=unnamed" \
  "control: a sender's ORCH_STATE_DIR reaching the reader misplaces the peer's record"

mutant raw-words 'cause="$(awk '\''NR == 1 && /^(workflow-state|kendex-env): / { print }'\'' "$WORK_DIR/reader.err")"' \
  'cause="$(cat -- "$WORK_DIR/reader.err")"'
record bad
send 'Raw words.'
assert_eq "$(err_lines)" "3" "control: relaying the reader's stderr whole puts unkeyed words under the notice"

mutant no-state-file-test ' || [ ! -e "$path" ]' ''
record none
send 'No state file.'
assert_eq "$(first_err)" "lane-mail: reader-unjudged=$PEER cause=state" \
  "control: without the state file test a peer with no fleet state reads as a state it could not read"

mutant no-pair-test '  if [ -z "$server" ] || [ -z "$start" ] || [ -z "$pane" ]; then' '  if [ -z "$start" ]; then'
record "{\"window\":\"@1\",\"server_start\":$START}"
send 'No pair.'
assert_eq "$(first_err)" "lane-mail: no-reader=$PEER cause=pane-gone" \
  "control: without the pair test a record naming no pane is judged as a pane"

mutant gone-silent '    1) lm_notice no-reader "$ROOT" cause=pane-gone ;;' '    1) ;;'
record "{\"server\":\"$GONE\",\"server_start\":$START,\"pane\":\"%9\"}"
send 'Gone.'
assert_eq "$(first_err)" "" "control: without the pane-gone notice a record naming a gone pane says nothing"

mutant server-silent '    *) lm_notice reader-unjudged "$ROOT" cause=server ;;' '    *) ;;'
record "{\"server\":\"$LIVE\",\"server_start\":$START,\"pane\":\"%9\"}"
printf '4242 %s %%9\n' "$START" > "$PANES"
send 'Other server.'
assert_eq "$(first_err)" "" "control: without the server notice a pane nothing here can ask says nothing"

mutant no-start-test '  if [ -z "$server" ] || [ -z "$start" ] || [ -z "$pane" ]; then' '  if [ -z "$server" ] || [ -z "$pane" ]; then'
record "{\"server\":\"$LIVE\",\"pane\":\"%9\"}"
printf '%s %s %%9\n' "$LIVE" "$START" > "$PANES"
send 'No start.'
assert_eq "$(first_err)" "lane-mail: no-reader=$PEER cause=pane-gone" \
  "control: without the start test a record binding no start is judged on a server it cannot name"

mutant state-silent '    lm_notice reader-unjudged "$ROOT" cause=state "$cause"' '    :'
record bad
send 'Bad state.'
assert_eq "$(first_err)" "" "control: without the state notice a fleet state nothing could read says nothing"

mutant hosted-silent '    lm_notice reader-unjudged "$ROOT" cause=hosted' '    :'
hosted_send 'Hosted control.'
assert_eq "$(first_err)" "" "control: without the hosted notice a hosted peer's reader goes unsaid"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
