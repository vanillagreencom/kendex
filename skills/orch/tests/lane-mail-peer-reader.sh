#!/usr/bin/env bash
# lane-mail requires the checkout-local overseer record before a delivery.
# For a recorded peer, it reports whether the mailbox has a reader. The
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
TMP_ROOT="$(mktemp -d)" || { echo "lane-mail-peer-reader: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "lane-mail-peer-reader: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "lane-mail-peer-reader: scratch=resolve-failed" >&2; exit 1; }
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
(cd "$TMP_ROOT/sender" && "$WORKFLOW_STATE" init oversee >/dev/null &&
  "$WORKFLOW_STATE" set oversee overseer '{"window":"@1"}' >/dev/null)
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
  LINES=0
  if [ -f "$PEER/tmp/lane-mail/overseer/to-lane.jsonl" ]; then
    LINES="$(wc -l < "$PEER/tmp/lane-mail/overseer/to-lane.jsonl" | tr -d ' ')"
  fi
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
{"window":"@1"}|-|lane-mail: no-reader=$PEER cause=unnamed|1|a record naming no server and pane names no reader
{"server":"$LIVE","server_start":$START,"pane":"9"}|$LIVE $START %9|lane-mail: no-reader=$PEER cause=unnamed|1|a pane not spelled %N names no reader
{"server":"a$LIVE","server_start":$START,"pane":"%9"}|$LIVE $START %9|lane-mail: no-reader=$PEER cause=unnamed|1|a server not spelled as a pid names no reader
{"server":"$GONE","server_start":$START,"pane":"%9"}|$LIVE $START %9|lane-mail: no-reader=$PEER cause=pane-gone|1|a record naming a gone server names a pane that no longer runs
{"server":"$LIVE","server_start":$START,"pane":"%4"}|$LIVE $START %9|lane-mail: no-reader=$PEER cause=pane-gone|1|a record naming a pane its server no longer lists names no reader
{"server":"$LIVE","server_start":$EARLIER,"pane":"%9"}|$LIVE $START %9|lane-mail: no-reader=$PEER cause=pane-gone|1|a record naming an earlier server handed the same pid and pane names no reader
{"server":"$LIVE","server_start":$START,"pane":"%9"}|$LIVE $START %9|-|0|a record naming a live pane says nothing
{"server":"$LIVE","pane":"%9"}|$LIVE $START %9|-|0|a record carrying no start names the session in its pane on that server pid, as the hooks read it
{"server":"$LIVE","pane":"%4"}|$LIVE $START %9|lane-mail: no-reader=$PEER cause=pane-gone|1|a record carrying no start names a pane its server no longer lists
{"server":"$LIVE","server_start":"soon","pane":"%9"}|$LIVE $START %9|lane-mail: no-reader=$PEER cause=unnamed|1|a start that is not epoch seconds names no reader
{"server":"$LIVE","server_start":$START,"pane":"%9"}|4242 $START %9|lane-mail: reader-unjudged=$PEER cause=server|0|a pane on a server this shell cannot ask is unjudged
EOF

# No local record means no delivery, including an owner-form send.
# The record's writers are oversee register and oversee launch; neither
# records a machine hostname, so the missing-record diagnostic names here.
while IFS='|' read -r verb args; do
  record none
  if [ "$verb" = owner ]; then
    printf '%s\n' 'Owner note.' > "$TMP_ROOT/msg.txt"
    RC=0
    OUT="$(cd "$PEER" && env -u TMUX -u TMUX_PANE -u ORCH_STATE_DIR \
      "$LANE_MAIL" send --item overseer --directive --file "$TMP_ROOT/msg.txt" 2>"$TMP_ROOT/err")" || RC=$?
    env_result=sourced
  else
    peer_call "$verb" 'No local reader.' $args
    env_result=unsourced
  fi
  error="$(first_err)"
  route=missing
  case "$error" in *owner-note*) route=owner-note ;; esac
  appended=absent
  [ ! -e "$PEER/tmp/lane-mail/overseer/to-lane.jsonl" ] || appended=present
  assert_eq "$RC $OUT ${error%% no overseer*} lines=$(err_lines) $(sourced) route=$route mailbox=$appended" \
    "2  lane-mail: overseer-absent=$PEER lines=1 $env_result route=owner-note mailbox=absent" \
    "a missing record refuses without appending: $verb $args" "$TMP_ROOT/err"
done <<EOF
send|
send|--re 1790000000-1-1
ask|
owner|
EOF

# A caller without a record cannot receive the reply peer send would refuse.
caller_ask() { # default|process|private
  local mode="$1" state="$TMP_ROOT/caller-$1-state"
  live_record
  rm -rf -- "$state" "$TMP_ROOT/sender/tmp/lane-mail/overseer"
  (cd "$TMP_ROOT/sender" && "$WORKFLOW_STATE" --no-private-env init oversee >/dev/null)
  SEND_ENV=()
  case "$mode" in
    default) ;;
    process) SEND_ENV=("ORCH_STATE_DIR=$state") ;;
    private) printf 'export ORCH_STATE_DIR=%q\n' "$state" > "$TMP_ROOT/sender/.env.local" ;;
  esac
  if [ "$mode" != default ]; then
    # register and launch use the full loader, unlike the replying peer.
    (cd "$TMP_ROOT/sender" && env -u ORCH_STATE_DIR ${SEND_ENV[@]+"${SEND_ENV[@]}"} \
      "$WORKFLOW_STATE" init oversee >/dev/null &&
      env -u ORCH_STATE_DIR ${SEND_ENV[@]+"${SEND_ENV[@]}"} \
      "$WORKFLOW_STATE" set oversee overseer '{"window":"@1"}' >/dev/null)
  fi
  peer_call ask 'No return reader.'
  OWN_LINES=0
  if [ -f "$TMP_ROOT/sender/tmp/lane-mail/overseer/to-overseer.jsonl" ]; then
    OWN_LINES="$(wc -l < "$TMP_ROOT/sender/tmp/lane-mail/overseer/to-overseer.jsonl" | tr -d ' ')"
  fi
  rm -f -- "$TMP_ROOT/sender/.env.local"
  SEND_ENV=()
}
for mode in default process private; do
  caller_ask "$mode"
  error="$(first_err)"
  assert_eq "$RC $OUT ${error%% no overseer*} lines=$(err_lines) peer=$LINES own=$OWN_LINES" \
    "2  lane-mail: overseer-absent=$TMP_ROOT/sender lines=1 peer=0 own=0" \
    "a caller without a reply-visible record refuses before either append: $mode" "$TMP_ROOT/err"
done
(cd "$TMP_ROOT/sender" && "$WORKFLOW_STATE" set oversee overseer '{"window":"@1"}' >/dev/null)

# Own record reads use the same environment as register and launch writers.
# Each state directory is non-default and the default has no record.
own_state_send() { # process|private
  local mode="$1" state="$TMP_ROOT/own-$1-state"
  rm -rf -- "$state" "$TMP_ROOT/sender/tmp/lane-mail/overseer"
  (cd "$TMP_ROOT/sender" && "$WORKFLOW_STATE" init oversee >/dev/null)
  SEND_ENV=()
  if [ "$mode" = process ]; then
    SEND_ENV=("ORCH_STATE_DIR=$state")
  else
    printf 'export ORCH_STATE_DIR=%q\n' "$state" > "$TMP_ROOT/sender/.env.local"
  fi
  (cd "$TMP_ROOT/sender" && env -u ORCH_STATE_DIR ${SEND_ENV[@]+"${SEND_ENV[@]}"} \
    "$WORKFLOW_STATE" init oversee >/dev/null &&
    env -u ORCH_STATE_DIR ${SEND_ENV[@]+"${SEND_ENV[@]}"} \
    "$WORKFLOW_STATE" set oversee overseer '{"window":"@1"}' >/dev/null)
  printf 'Own %s note.\n' "$mode" > "$TMP_ROOT/msg.txt"
  RC=0
  OUT="$(cd "$TMP_ROOT/sender" && env -u ORCH_STATE_DIR ${SEND_ENV[@]+"${SEND_ENV[@]}"} \
    "${LANE_MAIL_BIN:-$LANE_MAIL}" send --item overseer --directive \
    --file "$TMP_ROOT/msg.txt" 2>"$TMP_ROOT/err")" || RC=$?
  OWN_LINES=0
  if [ -f "$TMP_ROOT/sender/tmp/lane-mail/overseer/to-lane.jsonl" ]; then
    OWN_LINES="$(wc -l < "$TMP_ROOT/sender/tmp/lane-mail/overseer/to-lane.jsonl" | tr -d ' ')"
  fi
  rm -f -- "$TMP_ROOT/sender/.env.local"
  SEND_ENV=()
}
for mode in process private; do
  own_state_send "$mode"
  assert_eq "$RC ${OUT%% id=*} lines=$OWN_LINES $(first_err)" \
    "0 lane-mail: sent item=overseer lines=1 " \
    "an owner send finds the writer's record through $mode environment" "$TMP_ROOT/err"
done
rm -rf -- "$TMP_ROOT/sender/tmp/lane-mail/overseer"
(cd "$TMP_ROOT/sender" && "$WORKFLOW_STATE" set oversee overseer '{"window":"@1"}' >/dev/null)

# A dependency failure refuses before the append.
for rec in bad bad-settings; do
  record "$rec"
  send 'Unreadable record.'
  assert_eq "$RC $(first_err) lines=$LINES" "2 lane-mail: overseer-unreadable=$PEER lines=0" \
    "an unreadable record refuses: $rec" "$TMP_ROOT/err"
done

# The sender's own state directory names nothing of the peer's.
live_record
SEND_ENV=("ORCH_STATE_DIR=$TMP_ROOT/sender-state")
send 'Own state dir.'
SEND_ENV=()
assert_eq "$(first_err)" "" "a sender's ORCH_STATE_DIR does not move the peer's record" "$TMP_ROOT/err"

# An answer is read by the asker's wait, which names no session.
live_record
send 'Answer.' --re 1790000000-1-1
assert_eq "$RC lines=$LINES $(first_err)" "0 lines=1 " "an answer to a peer's ask says nothing of a reader" "$TMP_ROOT/err"

# An ask lands one line in the peer's mailbox and one in the asker's own
# record, prints its id, and is judged as a send is.
ASKS=0
ANSWERS=1
ask() { # TEXT
  peer_call ask "$1"
  ASKS=$((ASKS + 1))
  local own
  own="$(jq -rs '[(map(select(.kind == "ask")) | length), (map(select(.kind == "answer")) | length)] | join("/")' \
    "$TMP_ROOT/sender/tmp/lane-mail/overseer/to-overseer.jsonl")"
  assert_eq "$RC ${OUT%%=*} lines=$LINES own=$own" "0 id lines=1 own=$ASKS/$ANSWERS" \
    "the ask lands, its id prints and the asker records it: $1" "$TMP_ROOT/err"
}
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
record '{"window":"@1"}'
send 'Unjudged send.'
assert_eq "$(first_err)" "" "control: without the judgement a send to a checkout no session reads says nothing"

mutant answer-judged '      [ -n "$MSGID" ] || lm_peer_reader' '      lm_peer_reader'
record '{"window":"@1"}'
send 'Judged answer.' --re 1790000000-1-1
ANSWERS=$((ANSWERS + 1))
assert_eq "$(first_err)" "lane-mail: no-reader=$PEER cause=unnamed" \
  "control: judging an answer tells its sender nobody reads what the asker's wait reads"

mutant ask-unjudged '      lm_peer_reader' '      :'
record '{"window":"@1"}'
ask 'control: an unjudged ask lands'
assert_eq "$(first_err)" "" "control: without the judgement an ask to a checkout no session reads says nothing"

mutant startless-unasked ')) then "unstarted"' ')) and false then "unstarted"'
record "{\"server\":\"$LIVE\",\"pane\":\"%9\"}"
printf '%s %s %%9\n' "$LIVE" "$START" > "$PANES"
send 'Startless.'
assert_eq "$(first_err)" "lane-mail: no-reader=$PEER cause=unnamed" \
  "control: a reader that asks no ol_unstarted reads a record carrying no start as naming nobody"

mutant sources-peer '"$SCRIPT_DIR/workflow-state" --no-private-env "$@"' '"$SCRIPT_DIR/workflow-state" "$@"'
live_record
send 'Sourced.'
assert_eq "$(sourced)" "sourced" "control: a reader loading the peer's full ladder runs its private env file"

mutant sender-state-dir '(cd -- "$root" && env -u ORCH_STATE_DIR ' '(cd -- "$root" && env '
live_record
SEND_ENV=("ORCH_STATE_DIR=$TMP_ROOT/sender-state")
send 'Sender state dir.'
SEND_ENV=()
assert_eq "$RC lines=$LINES" "2 lines=0" \
  "control: a sender's ORCH_STATE_DIR reaching the reader misplaces the peer's record"

mutant caller-allowed '    [ "$PEER_VERB" != ask ] || lm_require_overseer data "$OWN_ROOT"' '    [ "$PEER_VERB" != ask ] || :'
caller_ask default
assert_eq "$RC ${OUT%%=*} peer=$LINES own=$OWN_LINES" "0 id peer=1 own=1" \
  "control: disabling the caller check delivers an ask whose reply would refuse" "$TMP_ROOT/err"
mutant caller-full '    [ "$PEER_VERB" != ask ] || lm_require_overseer data "$OWN_ROOT"' '    [ "$PEER_VERB" != ask ] || lm_require_overseer full "$OWN_ROOT"'
for mode in process private; do
  caller_ask "$mode"
  assert_eq "$RC ${OUT%%=*} peer=$LINES own=$OWN_LINES" "0 id peer=1 own=1" \
    "control: full caller resolution accepts a record the reply cannot find: $mode" "$TMP_ROOT/err"
done
(cd "$TMP_ROOT/sender" && "$WORKFLOW_STATE" set oversee overseer '{"window":"@1"}' >/dev/null)

mutant own-state-cleared '(cd -- "$root" && "$SCRIPT_DIR/workflow-state" "$@")' '(cd -- "$root" && env -u ORCH_STATE_DIR "$SCRIPT_DIR/workflow-state" "$@")'
own_state_send process
error="$(first_err)"
assert_eq "$RC ${error%% no overseer*} lines=$OWN_LINES" \
  "2 lane-mail: overseer-absent=$TMP_ROOT/sender lines=0" \
  "control: clearing own ORCH_STATE_DIR loses the writer's record" "$TMP_ROOT/err"

mutant own-private-skipped '(cd -- "$root" && "$SCRIPT_DIR/workflow-state" "$@")' '(cd -- "$root" && "$SCRIPT_DIR/workflow-state" --no-private-env "$@")'
own_state_send private
error="$(first_err)"
assert_eq "$RC ${error%% no overseer*} lines=$OWN_LINES" \
  "2 lane-mail: overseer-absent=$TMP_ROOT/sender lines=0" \
  "control: skipping own private environment loses the writer's record" "$TMP_ROOT/err"

mutant absent-allowed '  if [ "$LM_OVERSEER_RECORD" = null ]; then' '  if [ "$LM_OVERSEER_RECORD" = null ] && false; then'
record none
send 'No state file.'
assert_eq "$RC lines=$LINES" "0 lines=1" \
  "control: disabling the missing-record refusal appends to an unread mailbox"
live_record
send 'Present record control.'
assert_eq "$RC lines=$LINES" "0 lines=1" \
  "control: the present-record path still appends"

mutant no-pair-test '  if [ -z "$server" ] || [ "$start" = invalid ] || [ -z "$pane" ]; then' '  if [ "$start" = invalid ]; then'
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

mutant no-start-test '  if [ -z "$server" ] || [ "$start" = invalid ] || [ -z "$pane" ]; then' '  if [ -z "$server" ] || [ -z "$pane" ]; then'
record "{\"server\":\"$LIVE\",\"server_start\":\"soon\",\"pane\":\"%9\"}"
printf '%s %s %%9\n' "$LIVE" "$START" > "$PANES"
send 'Bad start.'
assert_eq "$(first_err)" "lane-mail: no-reader=$PEER cause=pane-gone" \
  "control: without the start test a start that is not epoch seconds is judged as a server's"

mutant hosted-silent '    lm_notice reader-unjudged "$ROOT" cause=hosted' '    :'
hosted_send 'Hosted control.'
assert_eq "$(first_err)" "" "control: without the hosted notice a hosted peer's reader goes unsaid"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
