#!/usr/bin/env bash
# lane-mail requires the checkout-local overseer record before a delivery.
# For a recorded peer, it reports whether the mailbox has a reader: the one
# session the peer's fleet record names, as agent-runtime's controller status
# reads it. Each row builds a sender and a peer checkout, writes the peer's
# record against a real tmux server on its own socket, and drives the real
# script with the built agent-runtime and the real tmux. What the status
# judges of a pane is agent-runtime's subject; these rows assert where the
# send and the ask find each checkout's record, by the full and the data
# scope of the mailbox's one record resolver, and how they report each answer
# of the status. The must-fail controls close the file, one per rule, each on
# a private copy of lane-mail.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd -P)"
# shellcheck source=../../orch/tests/lib/git-env.sh
source "$REPO_ROOT/skills/orch/tests/lib/git-env.sh"
# shellcheck source=../../orch/tests/lib/named-process.sh
source "$REPO_ROOT/skills/orch/tests/lib/named-process.sh"

LANE_MAIL="$REPO_ROOT/skills/mailbox/scripts/lane-mail"
ORCH_RUNTIME="$REPO_ROOT/skills/orch/scripts/orch-runtime"
FIXTURE_HOST="$REPO_ROOT/skills/orch/tests/fixtures/lane-host"
# mktemp alone, so set -e stops the suite on its failure: nested in the cd,
# a failed mktemp would resolve to this directory and the trap would remove it.
TMP_ROOT="$(mktemp -d)" || { echo "lane-mail-peer-reader: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "lane-mail-peer-reader: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "lane-mail-peer-reader: scratch=resolve-failed" >&2; exit 1; }
LIVE=""
# The private tmux server every reader row names, on its own socket.
REAL_SOCK="$TMP_ROOT/real.sock"
trap '[ -z "$LIVE" ] || kill "$LIVE" 2>/dev/null; [ ! -S "$REAL_SOCK" ] || tmux -S "$REAL_SOCK" kill-server 2>/dev/null; rm -rf -- "${TMP_ROOT:?}"' EXIT

# shellcheck source=../../orch/tests/lib/assertions.sh
source "$REPO_ROOT/skills/orch/tests/lib/assertions.sh"
# shellcheck source=../../orch/tests/lib/growth-state.sh
source "$REPO_ROOT/skills/orch/tests/lib/growth-state.sh"
# The status lane-mail asks is the built agent-runtime, found in the cache
# scripts/setup fills for this checkout's sources.
AGENT_RUNTIME_CACHE="$(bash -c '. "$1"; agent_runtime_cache' _ "$REPO_ROOT/skills/agent-runtime/scripts/lib/key.sh")" \
  || { echo "lane-mail-peer-reader: runtime-cache=unresolved" >&2; exit 1; }
export AGENT_RUNTIME_CACHE

echo "=== lane-mail peer send and peer ask: reader ==="

# A real tmux server on its own socket, reading no configuration: its first
# window runs a process, its second holds a pane the server keeps after its
# process exited (`remain-on-exit`), and a third window's pane was closed.
# A peer's record names one by that server's pid, start and socket.
real_tmux() { tmux -S "$REAL_SOCK" -f /dev/null "$@"; }
real_tmux new-session -d -s fleet -x 80 -y 24 'exec sleep 600'
REAL_RUNNING="$(real_tmux display-message -p -t =fleet: '#{pane_id}')"
REAL_DEAD="$(real_tmux new-window -d -P -F '#{pane_id}' -t =fleet: 'read line; exit 3')"
real_tmux set-option -p -t "$REAL_DEAD" remain-on-exit on
real_tmux send-keys -t "$REAL_DEAD" Enter
for _ in $(seq 1 100); do
  [ "$(real_tmux display-message -p -t "$REAL_DEAD" '#{pane_dead}')" != 1 ] || break
  sleep 0.05
done
[ "$(real_tmux display-message -p -t "$REAL_DEAD" '#{pane_dead}')" = 1 ] ||
  { echo "lane-mail-peer-reader: the kept pane never ended" >&2; exit 1; }
REAL_CLOSED="$(real_tmux new-window -d -P -F '#{pane_id}' -t =fleet: 'exec sleep 600')"
real_tmux kill-pane -t "$REAL_CLOSED"
read -r REAL_PID REAL_START <<<"$(real_tmux display-message -p '#{pid} #{start_time}')"

# A live process that is no tmux server, which outlives every row and the
# trap stops, and a gone one, a child that has exited.
mkdir -p "$TMP_ROOT/server"
fixture_named_process "$TMP_ROOT/server/tmux"
"$TMP_ROOT/server/tmux" 600 &
LIVE=$!
sleep 0 &
GONE=$!
wait "$GONE" || :

checkout() { # NAME
  mkdir -p "$TMP_ROOT/$1"
  git -C "$TMP_ROOT/$1" init -q
  git -C "$TMP_ROOT/$1" config gc.auto 0
  git -C "$TMP_ROOT/$1" config maintenance.auto false
  git -C "$TMP_ROOT/$1" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m base
}
# The fleet record as main's store wrote it, `init oversee` and then `set
# oversee overseer OVERSEER`, into the state directory DIR; `-` is the init
# object alone. The readers under test read it as data.
plant_record() { # DIR OVERSEER|-
  mkdir -p "$1"
  jq -n --arg overseer "$2" '{issue_id: "oversee", sub_issues: [], agent: "", worktree: "", branch: "",
    qa_labels: [], near_ceiling: [], finding_occurrences: {prior: "none", records: []}, child_sessions: {},
    review_agents: [], review_agent_ids: {}, review_agent_runtime_types: {}, pre_delegate_sha: null,
    skip_qa: false, cycles: 0, rereview_cycles: 0, json_paths: [], fixed_items: [], escalated_items: [],
    audit_issues_created: [], pr_review_baseline: null,
    pr_comment_review: {iterations: 0, fixes: [], issues_created: [], skipped: []},
    post_pr_budgets: {review_wait: null, ci_fix: null}, post_pr_stop: null}
    + (if $overseer == "-" then {} else {controller: ($overseer | fromjson)} end)' > "$1/workflow-state-oversee.json"
}
checkout sender
plant_record "$TMP_ROOT/sender/tmp" '{"window":"@1"}'
PEER="$TMP_ROOT/peer"

# The peer's fleet record: `none` for no state file, `bad` for a state file
# its reader cannot parse, `bad-settings` for settings their loader refuses,
# and otherwise the `.overseer` object itself. Every peer carries a private
# env file that moves its state directory away from the record, so a reader
# that loads it finds no record.
record() { # none|bad|bad-settings|JSON
  rm -rf -- "${PEER:?}"
  checkout peer
  printf 'ORCH_STATE_DIR=private-state\n' > "$PEER/.env.local"
  case "$1" in
    none) ;;
    bad-settings) printf '[env]\nX = unquoted\n' > "$PEER/kendex.settings.toml" ;;
    bad)
      mkdir -p "$PEER/tmp"
      printf '{ not json\n' > "$PEER/tmp/workflow-state-oversee.json"
      ;;
    *) plant_record "$PEER/tmp" "$1" ;;
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
  OUT="$(cd "$TMP_ROOT/sender" && env -u TMUX -u TMUX_PANE -u ORCH_STATE_DIR \
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
fix_lines() { grep -c '^fix=.*orch-runtime register --fleet' "$TMP_ROOT/err" || :; }
# The record of the session the private server runs in its first window.
pane_record() { # PANE
  printf '{"server":"%s","server_start":%s,"pane":"%s","server_socket":"%s"}' \
    "$REAL_PID" "$REAL_START" "$1" "$REAL_SOCK"
}
live_record() { record "$(pane_record "$REAL_RUNNING")"; }

# RECORD|FIRST STDERR LINE|FIX LINES|LABEL. FIRST `-` is an empty stderr. No
# row sources the peer's private env file.
while IFS='|' read -r rec first fix label; do
  record "$rec"
  send "$label"
  assert_eq "$RC ${OUT%% id=*} lines=$LINES" "0 lane-mail: sent item=overseer lines=1" \
    "the note lands and its receipt prints: $label" "$TMP_ROOT/err"
  assert_eq "$(first_err) fix=$(fix_lines)" "${first/#-/} fix=$fix" "$label" "$TMP_ROOT/err"
done <<EOF
$(pane_record "$REAL_RUNNING")|-|0|a record naming a live pane says nothing
{"window":"@1"}|lane-mail: no-reader=$PEER live=false|1|a record naming no server and pane names no reader
$(pane_record "$REAL_DEAD")|lane-mail: no-reader=$PEER live=false|1|a pane its server keeps after its process exited names no reader
$(pane_record "$REAL_CLOSED")|lane-mail: no-reader=$PEER live=false|1|a pane its server no longer lists names no reader
{"server":"$REAL_PID","server_start":$((REAL_START - 1)),"pane":"$REAL_RUNNING","server_socket":"$REAL_SOCK"}|lane-mail: no-reader=$PEER live=false|1|an earlier server handed the same pid and pane names no reader
{"server":"$GONE","server_start":$REAL_START,"pane":"%9","server_socket":"$TMP_ROOT/gone.sock"}|lane-mail: no-reader=$PEER live=false|1|a server that is gone with its process names no reader
EOF

# A server whose process lives and whose socket answers nothing is a read
# that failed: unjudged, with agent-runtime's own cause and its refusal under
# the English.
record "{\"server\":\"$LIVE\",\"server_start\":$REAL_START,\"pane\":\"%9\",\"server_socket\":\"$TMP_ROOT/silent.sock\"}"
send 'Silent server.'
assert_eq "$RC ${OUT%% id=*} lines=$LINES $(first_err) fix=$(fix_lines)" \
  "0 lane-mail: sent item=overseer lines=1 lane-mail: reader-unjudged=$PEER cause=server-unreachable fix=0" \
  "a server process that answers on no socket leaves the reader unjudged" "$TMP_ROOT/err"
assert_eq "$(grep -c '^agent-runtime: controller-unreadable cause=server-unreachable$' "$TMP_ROOT/err")" 1 \
  "the unjudged notice carries agent-runtime's refusal" "$TMP_ROOT/err"

# No local record means no delivery, including an owner-form send.
# The record's writers record no machine hostname, so the missing-record
# diagnostic names here.
while IFS='|' read -r verb args; do
  record none
  if [ "$verb" = owner ]; then
    printf '%s\n' 'Owner note.' > "$TMP_ROOT/msg.txt"
    RC=0
    OUT="$(cd "$PEER" && env -u TMUX -u TMUX_PANE -u ORCH_STATE_DIR \
      "$LANE_MAIL" send --item overseer --directive --file "$TMP_ROOT/msg.txt" 2>"$TMP_ROOT/err")" || RC=$?
  else
    peer_call "$verb" 'No local reader.' $args
  fi
  error="$(first_err)"
  route=missing
  case "$error" in *'orch-runtime register --fleet'*) route=register ;; esac
  case "$error" in *owner-note*) route=consumer-tool ;; esac
  appended=absent
  [ ! -e "$PEER/tmp/lane-mail/overseer/to-lane.jsonl" ] || appended=present
  assert_eq "$RC $OUT ${error%% no overseer*} lines=$(err_lines) route=$route mailbox=$appended" \
    "2  lane-mail: overseer-absent=$PEER lines=1 route=register mailbox=absent" \
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
  plant_record "$TMP_ROOT/sender/tmp" -
  SEND_ENV=()
  case "$mode" in
    default) ;;
    process) SEND_ENV=("ORCH_STATE_DIR=$state") ;;
    private) printf 'export ORCH_STATE_DIR=%q\n' "$state" > "$TMP_ROOT/sender/.env.local" ;;
  esac
  if [ "$mode" != default ]; then
    # register and launch use the full loader, unlike the replying peer.
    plant_record "$state" '{"window":"@1"}'
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
plant_record "$TMP_ROOT/sender/tmp" '{"window":"@1"}'

# Own record reads use the same environment as register and launch writers.
# Each state directory is non-default and the default has no record.
own_state_send() { # process|private
  local mode="$1" state="$TMP_ROOT/own-$1-state"
  rm -rf -- "$state" "$TMP_ROOT/sender/tmp/lane-mail/overseer"
  plant_record "$TMP_ROOT/sender/tmp" -
  SEND_ENV=()
  if [ "$mode" = process ]; then
    SEND_ENV=("ORCH_STATE_DIR=$state")
  else
    printf 'export ORCH_STATE_DIR=%q\n' "$state" > "$TMP_ROOT/sender/.env.local"
  fi
  plant_record "$state" '{"window":"@1"}'
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
plant_record "$TMP_ROOT/sender/tmp" '{"window":"@1"}'

# The record the runtime writes, under the state directory the peer's
# settings file names: the reader places it where the writer did.
record none
printf '[env]\nORCH_STATE_DIR = "fleet-state"\n' > "$PEER/kendex.settings.toml"
(cd "$PEER" && "$ORCH_RUNTIME" --no-private-env state init --fleet >/dev/null &&
  "$ORCH_RUNTIME" --no-private-env state set --fleet /controller "$(pane_record "$REAL_RUNNING")" >/dev/null) ||
  { echo "lane-mail-peer-reader: the runtime wrote no record" >&2; exit 1; }
send 'Runtime record.'
assert_eq "$RC ${OUT%% id=*} lines=$LINES $(first_err)" \
  "0 lane-mail: sent item=overseer lines=1 " \
  "a record the runtime wrote under the settings file's state directory names its live reader" "$TMP_ROOT/err"

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
live_record
SEND_ENV=("TMUX=$TMP_ROOT/caller.sock,$LIVE,0")
ask 'an ask judges the peer on its recorded socket, not the caller server'
SEND_ENV=()
assert_eq "$(first_err)" "" "an ask judges the peer on its recorded socket, not the caller server" "$TMP_ROOT/err"
record '{"window":"@1"}'
ask 'an ask to a peer naming no pane'
assert_eq "$(first_err)" "lane-mail: no-reader=$PEER live=false" "an ask to a peer naming no pane names no reader" "$TMP_ROOT/err"

# A hosted peer keeps its record and tmux server on its own host.
REMOTE_ROOT=/srv/peer
REMOTE_DISK="$TMP_ROOT/remote"
mkdir -p "$REMOTE_DISK$REMOTE_ROOT/tmp/lane-mail/overseer"
hosted_send() { # TEXT
  printf '%s\n' "$1" > "$TMP_ROOT/msg.txt"
  RC=0
  OUT="$(cd "$TMP_ROOT/sender" && env -u TMUX -u TMUX_PANE ORCH_LANE_HOST="$FIXTURE_HOST" \
    LANE_HOST_STUB_LOG="$TMP_ROOT/host.log" LANE_HOST_STUB_DIR="$REMOTE_DISK" \
    LANE_HOST_STUB_LIB="$REPO_ROOT/skills/mailbox/scripts/lib" \
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

mutant consumer-route 'run orch-runtime register --fleet in the session that should read this checkout\x27s mail; for an overseer on another host, send from that host\x27s checkout' 'use the owner-note tool for a remote overseer'
record none
send 'Route control.'
route=missing
case "$(first_err)" in *'orch-runtime register --fleet'*) route=register ;; esac
case "$(first_err)" in *owner-note*) route=consumer-tool ;; esac
assert_eq "$route" consumer-tool 'control: the former refusal does not name the portable registration route'

mutant no-judgement '      [ -n "$MSGID" ] || lm_peer_reader' '      [ -n "$MSGID" ] || :'
record '{"window":"@1"}'
send 'Unjudged send.'
assert_eq "$(first_err)" "" "control: without the judgement a send to a checkout no session reads says nothing"

mutant answer-judged '      [ -n "$MSGID" ] || lm_peer_reader' '      lm_peer_reader'
record '{"window":"@1"}'
send 'Judged answer.' --re 1790000000-1-1
ANSWERS=$((ANSWERS + 1))
assert_eq "$(first_err)" "lane-mail: no-reader=$PEER live=false" \
  "control: judging an answer tells its sender nobody reads what the asker's wait reads"

mutant ask-unjudged '      lm_peer_reader' '      :'
record '{"window":"@1"}'
ask 'control: an unjudged ask lands'
assert_eq "$(first_err)" "" "control: without the judgement an ask to a checkout no session reads says nothing"

mutant live-unread '    '\''true true'\'' | '\''true false'\'') LM_READER_LIVE="${answer#true }" ;;' '    '\''true true'\'' | '\''true false'\'') LM_READER_LIVE=true ;;'
record "$(pane_record "$REAL_DEAD")"
send 'Status live unread.'
assert_eq "$(first_err)" "" "control: a reader that takes no live member from the status reads a dead pane as its reader"

mutant live-ignored '  elif [ "$LM_READER_LIVE" != true ]; then' '  elif false; then'
record '{"window":"@1"}'
send 'Live ignored.'
assert_eq "$(first_err)" "" "control: without the live test a record naming no pane says nothing"

mutant unjudged-silent '  elif [ -n "$LM_READER_CAUSE" ]; then' '  elif false; then'
record "{\"server\":\"$LIVE\",\"server_start\":$REAL_START,\"pane\":\"%9\",\"server_socket\":\"$TMP_ROOT/silent.sock\"}"
send 'Unjudged silent.'
assert_eq "$(first_err)" "lane-mail: no-reader=$PEER live=false" \
  "control: without the cause test a failed status read is reported as nobody reading"

mutant cause-dropped '    '\''refused controller-unreadable '\''?*) LM_READER_CAUSE="${answer#refused controller-unreadable }" ;;' ''
record "{\"server\":\"$LIVE\",\"server_start\":$REAL_START,\"pane\":\"%9\",\"server_socket\":\"$TMP_ROOT/silent.sock\"}"
send 'Cause dropped.'
assert_eq "$RC lines=$LINES $(first_err)" "2 lines=0 lane-mail: overseer-unreadable=$PEER" \
  "control: without the unreadable arm a failed status read refuses the send as an unreadable record"

mutant sources-peer '(unset ORCH_STATE_DIR; mailbox_fleet_record data "$2")' '(unset ORCH_STATE_DIR; mailbox_fleet_record full "$2")'
live_record
send 'Sourced.'
error="$(first_err)"
assert_eq "${error%% no overseer*}" "lane-mail: overseer-absent=$PEER" \
  "control: a reader loading the peer's full ladder takes its private state directory"

mutant sender-state-dir '(unset ORCH_STATE_DIR; mailbox_fleet_record data "$2")' '(mailbox_fleet_record data "$2")'
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
plant_record "$TMP_ROOT/sender/tmp" '{"window":"@1"}'

mutant own-state-cleared '    mailbox_fleet_record full "$2" 2>' '    (unset ORCH_STATE_DIR; mailbox_fleet_record full "$2") 2>'
own_state_send process
error="$(first_err)"
assert_eq "$RC ${error%% no overseer*} lines=$OWN_LINES" \
  "2 lane-mail: overseer-absent=$TMP_ROOT/sender lines=0" \
  "control: clearing own ORCH_STATE_DIR loses the writer's record" "$TMP_ROOT/err"

mutant own-private-skipped '    mailbox_fleet_record full "$2" 2>' '    mailbox_fleet_record data "$2" 2>'
own_state_send private
error="$(first_err)"
assert_eq "$RC ${error%% no overseer*} lines=$OWN_LINES" \
  "2 lane-mail: overseer-absent=$TMP_ROOT/sender lines=0" \
  "control: skipping own private environment loses the writer's record" "$TMP_ROOT/err"

mutant absent-allowed '    '\''false false'\'' | '\''refused record-missing '\''*) lm_overseer_absent "$root"; exit 2 ;;' '    '\''false false'\'' | '\''refused record-missing '\''*) ;;'
record none
send 'No state file.'
assert_eq "$RC lines=$LINES" "0 lines=1" \
  "control: disabling the missing-record refusal appends to an unread mailbox"
live_record
send 'Present record control.'
assert_eq "$RC lines=$LINES" "0 lines=1" \
  "control: the present-record path still appends"

mutant hosted-silent '    lm_reader_report reader-unjudged "$ROOT" cause=hosted' '    :'
hosted_send 'Hosted control.'
assert_eq "$(first_err)" "" "control: without the hosted notice a hosted peer's reader goes unsaid"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
