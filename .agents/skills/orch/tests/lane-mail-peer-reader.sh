#!/usr/bin/env bash
# lane-mail peer send: whether the peer checkout's overseer mailbox has a
# reader, the notice the send writes on stderr after its receipt. The reader
# is the one session the peer's fleet record names by tmux server and pane;
# each row builds a sender and a peer checkout, writes the peer's record, and
# drives the real script with a tmux stub whose pane list the row sets. What
# the pane judgement itself answers is tmux-pane-live.sh's subject; these rows
# assert how the send reports each answer. The must-fail controls close the
# file, one per rule, each on a private copy of lane-mail.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd -P)"
LANE_MAIL="$REPO_ROOT/skills/orch/scripts/lane-mail"
WORKFLOW_STATE="$REPO_ROOT/skills/orch/scripts/workflow-state"
FIXTURE_HOST="$REPO_ROOT/skills/orch/tests/fixtures/lane-host"
TMP_ROOT="$(cd -- "$(mktemp -d)" && pwd -P)"
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

# shellcheck source=lib/assertions.sh
source "$TEST_DIR/lib/assertions.sh"
# shellcheck source=lib/growth-state.sh
source "$TEST_DIR/lib/growth-state.sh"

echo "=== lane-mail peer send: reader ==="

# `list-panes -a` answers the file PANES holds; with no file, tmux has no
# server to ask.
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

# A running server is this suite's own shell, and a gone one a child that has
# exited.
LIVE=$$
sleep 0 &
GONE=$!
wait "$GONE" || :

checkout() { # NAME
  mkdir -p "$TMP_ROOT/$1"
  git -C "$TMP_ROOT/$1" init -q
  git -C "$TMP_ROOT/$1" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m base
}
checkout sender
PEER="$TMP_ROOT/peer"

# The peer's fleet record: `none` for no state file, `bad` for a state file
# its reader cannot parse, and otherwise the `.overseer` object itself.
record() { # none|bad|JSON
  rm -rf -- "${PEER:?}"
  checkout peer
  case "$1" in
    none) ;;
    bad)
      (cd "$PEER" && "$WORKFLOW_STATE" init oversee >/dev/null)
      printf '{ not json\n' > "$(cd "$PEER" && "$WORKFLOW_STATE" path oversee)"
      ;;
    *)
      (cd "$PEER" && "$WORKFLOW_STATE" init oversee >/dev/null &&
        "$WORKFLOW_STATE" set oversee overseer "$1" >/dev/null)
      ;;
  esac
}

RC=0
OUT=""
LINES=0
send() { # TEXT [ARGS...]
  local text="$1"
  shift
  printf '%s\n' "$text" > "$TMP_ROOT/msg.txt"
  RC=0
  OUT="$(cd "$TMP_ROOT/sender" && env -u TMUX -u TMUX_PANE -u ORCH_STATE_DIR PATH="$STUB_BIN:$PATH" \
    "${LANE_MAIL_BIN:-$LANE_MAIL}" peer send --repo "$PEER" --file "$TMP_ROOT/msg.txt" "$@" 2>"$TMP_ROOT/err")" || RC=$?
  LINES="$(wc -l < "$PEER/tmp/lane-mail/overseer/to-lane.jsonl" | tr -d ' ')"
}
first_err() { awk 'NR == 1' "$TMP_ROOT/err"; }
fix_lines() { grep -c '^fix=.*oversee register' "$TMP_ROOT/err" || :; }

# RECORD|LISTING|FIRST STDERR LINE|FIX LINES|LABEL. LISTING `-` is no server
# to ask, and FIRST `-` is an empty stderr.
while IFS='|' read -r rec listing first fix label; do
  record "$rec"
  if [ "$listing" = - ]; then rm -f -- "$PANES"; else printf '%s\n' "$listing" > "$PANES"; fi
  send "$label"
  assert_eq "$RC ${OUT%% id=*} lines=$LINES" "0 lane-mail: sent item=overseer lines=1" \
    "the note lands and its receipt prints: $label" "$TMP_ROOT/err"
  assert_eq "$(first_err) fix=$(fix_lines)" "${first/#-/} fix=$fix" "$label" "$TMP_ROOT/err"
done <<EOF
none|-|lane-mail: no-reader=$PEER cause=unnamed|1|a peer with no fleet state names no reader
{"window":"@1"}|-|lane-mail: no-reader=$PEER cause=unnamed|1|a record naming no server and pane names no reader
{"server":"$LIVE","pane":"9"}|$LIVE %9|lane-mail: no-reader=$PEER cause=unnamed|1|a pane not spelled %N names no reader
{"server":"a$LIVE","pane":"%9"}|$LIVE %9|lane-mail: no-reader=$PEER cause=unnamed|1|a server not spelled as a pid names no reader
{"server":"$GONE","pane":"%9"}|$LIVE %9|lane-mail: no-reader=$PEER cause=pane-gone|1|a record naming a gone server names a pane that no longer runs
{"server":"$LIVE","pane":"%4"}|$LIVE %9|lane-mail: no-reader=$PEER cause=pane-gone|1|a record naming a pane its server no longer lists names no reader
{"server":"$LIVE","pane":"%9"}|$LIVE %9|-|0|a record naming a live pane says nothing
{"server":"$LIVE","pane":"%9"}|4242 %9|lane-mail: reader-unjudged=$PEER cause=server|0|a pane on a server this shell cannot ask is unjudged
bad|-|lane-mail: reader-unjudged=$PEER cause=state|0|a fleet state its reader cannot parse is unjudged
EOF

record bad
send 'State words.'
assert_eq "$(awk 'NR == 3 { print (length($0) > 0 ? "present" : "empty") }' "$TMP_ROOT/err")" "present" \
  "the state reader's own words stand under the notice"

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

mutant no-judgement '      lm_peer_reader' '      :'
record none
send 'Unjudged send.'
assert_eq "$(first_err)" "" "control: without the judgement a send to a checkout no session reads says nothing"

mutant no-state-file-test ' || [ ! -e "$path" ]' ''
record none
send 'No state file.'
assert_eq "$(first_err)" "lane-mail: reader-unjudged=$PEER cause=state" \
  "control: without the state file test a peer with no fleet state reads as a state it could not read"

mutant no-pair-test '  if [ -z "$server" ] || [ -z "$pane" ]; then' '  if false; then'
record '{"window":"@1"}'
send 'No pair.'
assert_eq "$(first_err)" "lane-mail: no-reader=$PEER cause=pane-gone" \
  "control: without the pair test a record naming no pane is judged as a pane"

mutant gone-silent '    1) lm_notice no-reader "$ROOT" cause=pane-gone ;;' '    1) ;;'
record "{\"server\":\"$GONE\",\"pane\":\"%9\"}"
send 'Gone.'
assert_eq "$(first_err)" "" "control: without the pane-gone notice a record naming a gone pane says nothing"

mutant server-silent '    *) lm_notice reader-unjudged "$ROOT" cause=server ;;' '    *) ;;'
record "{\"server\":\"$LIVE\",\"pane\":\"%9\"}"
printf '4242 %%9\n' > "$PANES"
send 'Other server.'
assert_eq "$(first_err)" "" "control: without the server notice a pane nothing here can ask says nothing"

mutant state-silent '    lm_notice reader-unjudged "$ROOT" cause=state "$(cat -- "$WORK_DIR/reader.err")"' '    :'
record bad
send 'Bad state.'
assert_eq "$(first_err)" "" "control: without the state notice a fleet state nothing could read says nothing"

mutant hosted-silent '    lm_notice reader-unjudged "$ROOT" cause=hosted' '    :'
hosted_send 'Hosted control.'
assert_eq "$(first_err)" "" "control: without the hosted notice a hosted peer's reader goes unsaid"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
