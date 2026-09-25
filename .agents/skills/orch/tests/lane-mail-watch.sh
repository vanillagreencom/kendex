#!/usr/bin/env bash
# lane-mail watch: the lane's standing mailbox monitor. A harness background
# wake (Claude Code Monitor, Pi bg_task) runs it and starts a turn for each
# line it prints, and that turn runs `lane-mail inbox`. Each case starts the
# real script in the background over a lane worktree under TMP_ROOT, appends
# with the real `send`, and reads what the watch printed. The harness stand-in
# is the loop the woken turn runs: read a `mail=` line, then run `inbox`. A
# tmux on PATH records every call, so a directive that reaches an idle lane
# with no pane write is observed, not assumed. The must-fail control closes
# the file.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
LANE_MAIL="$REPO_ROOT/skills/orch/scripts/lane-mail"
TMP_ROOT="$(mktemp -d)"
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)"
WATCH_PID=""
stop_watch() {
  [ -n "$WATCH_PID" ] || return 0
  kill -TERM "$WATCH_PID" 2>/dev/null || :
  wait "$WATCH_PID" 2>/dev/null || :
  WATCH_PID=""
}
trap 'stop_watch; rm -rf -- "$TMP_ROOT"' EXIT

PASS=0
FAIL=0
assert_eq() { # GOT WANT LABEL
  if [[ "$1" == "$2" ]]; then
    PASS=$((PASS + 1)); printf '  ok    %s\n' "$3"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        want: %s\n        got:  %s\n' "$3" "$2" "$1"
  fi
}

# Any tmux call a case makes lands in this log, so an empty log is a case that
# wrote to no pane.
STUB_BIN="$TMP_ROOT/stub-bin"
TMUX_LOG="$TMP_ROOT/tmux.log"
mkdir -p "$STUB_BIN"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s"\n' "$TMUX_LOG" >"$STUB_BIN/tmux"
chmod +x "$STUB_BIN/tmux"
: >"$TMUX_LOG"

LANE=""
new_lane() { # NAME
  LANE="$TMP_ROOT/$1"
  mkdir -p "$LANE"
  git -C "$LANE" init -q
  git -C "$LANE" config gc.auto 0
  git -C "$LANE" config maintenance.auto false
}

text() { # NAME CONTENT
  printf '%s\n' "$2" >"$TMP_ROOT/$1.txt"
  printf '%s' "$TMP_ROOT/$1.txt"
}

# The overseer's side, and the lane's own reads, each run from the lane.
lm() { # ARGS...
  (cd "$LANE" && PATH="$STUB_BIN:$PATH" "$LANE_MAIL" "$@")
}
send_directive() { # TEXT
  lm send --item KEN-1 --root "$LANE" --directive --file "$(text d "$1")" >/dev/null
}

WATCH_OUT="$TMP_ROOT/watch.out"
start_watch() { # [BIN]
  stop_watch
  : >"$WATCH_OUT"
  (cd "$LANE" && PATH="$STUB_BIN:$PATH" exec "${1:-$LANE_MAIL}" watch --item KEN-1 --interval 1) \
    >"$WATCH_OUT" 2>"$TMP_ROOT/watch.err" &
  WATCH_PID=$!
}

# The number of `mail=` lines the watch has printed.
announced() {
  grep -c '^lane-mail: mail=KEN-1 new=' "$WATCH_OUT" || :
}

# Waits for the watch to print its Nth `mail=` line, or for the deadline.
await_announced() { # N
  local waited=0
  while [ "$(announced)" -lt "$1" ] && [ "$waited" -lt 10 ]; do
    sleep 1
    waited=$((waited + 1))
  done
}

# Several polls of the watch, so a line it would print again has had the
# chance to.
quiet_polls() { sleep 3; }

echo "=== lane-mail watch ==="

new_lane standing
send_directive 'Rebase onto main.'
start_watch
await_announced 1
assert_eq "$(head -n 1 "$WATCH_OUT")" "lane-mail: mail=KEN-1 new=1" \
  "a watch announces a directive already unread when it starts"
assert_eq "$(sed -n 2p "$WATCH_OUT")" \
  "Overseer mail landed in this lane mailbox. Run .agents/skills/orch/scripts/lane-mail inbox --item with the item above, and act on every directive it prints." \
  "the announcement tells the woken lane to run inbox"
quiet_polls
assert_eq "$(announced)" "1" "an arrival is announced once, however many polls pass"
assert_eq "$([ -e "$LANE/tmp/lane-mail/KEN-1/to-lane.cursor" ] && cat "$LANE/tmp/lane-mail/KEN-1/to-lane.cursor" || echo none)" \
  "none" "the watch moves no cursor"
stop_watch

# The row the issue's delivery claim stands on: the lane is idle, with nothing
# running but its watch; a directive lands; the wake the watch's line causes
# runs inbox, which hands the directive over; and nothing wrote to a pane.
new_lane idle
start_watch
quiet_polls
assert_eq "$(announced)" "0" "an empty mailbox wakes nobody"
send_directive 'Hold the PR.'
await_announced 1
READ=""
if [ "$(announced)" -ge 1 ]; then READ="$(lm inbox --item KEN-1)"; fi
assert_eq "$(jq -r '.kind + " " + .text' <<<"${READ:-null}" 2>/dev/null)" "directive Hold the PR." \
  "a directive sent to an idle lane is read by the inbox run its watch's line wakes"
assert_eq "$(cat "$LANE/tmp/lane-mail/KEN-1/to-lane.cursor")" "1" "that inbox read advances the cursor"
assert_eq "$(wc -l <"$TMUX_LOG" | tr -d ' ')" "0" "the directive reached the idle lane with no pane write"
quiet_polls
assert_eq "$(announced)" "1" "mail the lane has read is not announced again"
send_directive 'Then merge.'
await_announced 2
assert_eq "$(sed -n 3p "$WATCH_OUT")" "lane-mail: mail=KEN-1 new=1" \
  "the next directive after a read wakes the lane again, counting only itself"
stop_watch

# An answer belongs to the `wait` that asked for it: the watch prints nothing
# for one, so no wake runs an inbox read that has nothing to hand over, and the
# wait still receives the answer.
new_lane answer
start_watch
ASK="$(lm ask --item KEN-1 --file "$(text q 'Merge now?')")"
ASK="${ASK#id=}"
lm send --item KEN-1 --root "$LANE" --re "$ASK" --file "$(text a 'Merge it.')" >/dev/null
quiet_polls
assert_eq "$(announced)" "0" "an answer wakes nothing"
assert_eq "$(lm wait --item KEN-1 --id "$ASK" --timeout 5 --interval 1)" "Merge it." \
  "the ask's wait still receives its answer"
stop_watch

# Refusals, keyed on their first line.
new_lane refusals
RC=0
lm watch --item KEN-1 --interval soon >/dev/null 2>"$TMP_ROOT/err" || RC=$?
assert_eq "$RC=$(head -n 1 "$TMP_ROOT/err")" "2=lane-mail: seconds-invalid=--interval" \
  "an interval that is not a number of seconds is refused"
mkdir -p "$LANE/tmp/lane-mail/KEN-1"
printf 'two\n' >"$LANE/tmp/lane-mail/KEN-1/to-lane.cursor"
RC=0
lm watch --item KEN-1 --interval 1 >/dev/null 2>"$TMP_ROOT/err" || RC=$?
assert_eq "$RC=$(head -n 1 "$TMP_ROOT/err")" "2=lane-mail: cursor-invalid=$LANE/tmp/lane-mail/KEN-1/to-lane.cursor" \
  "a cursor that holds no count stops the watch rather than announcing from zero"

# Control: without the line that records what was announced, the watch
# announces the same directive at every poll and wakes the lane each time.
# The mutant sits beside the libraries and siblings it sources, as the script
# it copies does.
MUTANT_DIR="$TMP_ROOT/mutant-scripts"
mkdir -p "$MUTANT_DIR"
sed 's@^      ANNOUNCED="\$(lm_count "\$WORK_DIR/lane.jsonl")"$@      :@' "$LANE_MAIL" >"$MUTANT_DIR/lane-mail"
chmod +x "$MUTANT_DIR/lane-mail"
assert_eq "$(cmp -s "$MUTANT_DIR/lane-mail" "$LANE_MAIL" && echo same || echo differs)" "differs" \
  "control: the announces-again mutant really differs from lane-mail"
ln -s "$REPO_ROOT/skills/orch/scripts/lib" "$MUTANT_DIR/lib"
ln -s "$REPO_ROOT/skills/orch/scripts/git-context" "$MUTANT_DIR/git-context"
new_lane control
send_directive 'Once.'
start_watch "$MUTANT_DIR/lane-mail"
await_announced 1
quiet_polls
assert_eq "$([ "$(announced)" -gt 1 ] && echo repeated || echo once)" "repeated" \
  "control: without the announced count the same directive is announced at every poll"
stop_watch

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
