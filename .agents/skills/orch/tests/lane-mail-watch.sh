#!/usr/bin/env bash
# lane-mail watch: the lane's standing mailbox monitor. A harness background
# wake (Claude Code Monitor, Pi bg_task) runs it and starts a turn for each
# announcement it prints, and that turn runs the `inbox` command the
# announcement names. Each case starts the real script in the background over a
# lane worktree under TMP_ROOT, appends with the real `send`, and reads what the
# watch printed. Polls are counted from the liveness record the watch rewrites,
# so a row asserting silence waits for polls that ran rather than for a fixed
# time. A tmux on PATH records every call, so a directive that reaches an idle
# lane with no pane write is observed, not assumed. The must-fail controls close
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

# A lane worktree with the mailbox its launch creates.
LANE=""
BOX=""
new_lane() { # NAME
  LANE="$TMP_ROOT/$1"
  BOX="$LANE/tmp/lane-mail/KEN-1"
  mkdir -p "$BOX"
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
SENT=""
send_directive() { # TEXT — SENT holds the receipt
  SENT="$(lm send --item KEN-1 --root "$LANE" --directive --file "$(text d "$1")")"
}

WATCH_OUT="$TMP_ROOT/watch.out"
WATCH_ERR="$TMP_ROOT/watch.err"
start_watch() { # [BIN] [ARGS...] — from the lane, or with the ARGS given
  local bin="${1:-$LANE_MAIL}"
  [ "$#" -eq 0 ] || shift
  stop_watch
  : >"$WATCH_OUT"
  rm -f -- "$BOX/to-lane.watch"
  if [ "$#" -eq 0 ]; then set -- --item KEN-1; fi
  (cd "$LANE" && PATH="$STUB_BIN:$PATH" exec "$bin" watch --interval 1 "$@") \
    >"$WATCH_OUT" 2>"$WATCH_ERR" &
  WATCH_PID=$!
}

# The announcements the watch has printed: their keyed lines, one per line.
mail_lines() {
  grep '^lane-mail: mail=' "$WATCH_OUT" || :
}
announced() {
  mail_lines | awk 'END { print NR + 0 }'
}

# Waits, up to a deadline, for the Nth announcement.
await_announced() { # N
  local tries=0
  while [ "$(announced)" -lt "$1" ] && [ "$tries" -lt 50 ]; do
    sleep 0.2
    tries=$((tries + 1))
  done
}

# Waits, up to a deadline, for N more polls: each rewrites the liveness record
# with the second it ran, and polls sit a whole interval apart.
watch_at() {
  sed -n 's/^at=\([0-9]*\) .*/\1/p' "$BOX/to-lane.watch" 2>/dev/null || :
}
await_polls() { # N
  local tries=0 seen=0 last now
  last="$(watch_at)"
  while [ "$seen" -lt "$1" ] && [ "$tries" -lt 75 ]; do
    sleep 0.2
    tries=$((tries + 1))
    now="$(watch_at)"
    if [ -n "$now" ] && [ "$now" != "$last" ]; then
      seen=$((seen + 1))
      last="$now"
    fi
  done
}

echo "=== lane-mail watch ==="

new_lane standing
send_directive 'Rebase onto main.'
send_directive 'Then rerun the checks.'
start_watch
await_announced 1
assert_eq "$(sed -n 1p "$WATCH_OUT")" "lane-mail: mail=KEN-1 new=2" \
  "a watch announces every directive already unread when it starts, counting them"
assert_eq "$(sed -n 2p "$WATCH_OUT")" \
  "Overseer mail landed in this lane mailbox. Run the command below and act on every directive it prints." \
  "the announcement tells the woken lane to run the command under it"
assert_eq "$(sed -n 3p "$WATCH_OUT")" "$(printf '%q inbox --item KEN-1 --root %q' "$LANE_MAIL" "$LANE")" \
  "the command is the literal inbox read of this lane's mailbox, naming the root the watch resolved"
send_directive 'Then merge.'
assert_eq "${SENT##* }" "monitor=live" "a send to a mailbox under a running watch reads its monitor as live"
await_announced 2
await_polls 2
assert_eq "$(mail_lines | tr '\n' '|')" "lane-mail: mail=KEN-1 new=2|lane-mail: mail=KEN-1 new=1|" \
  "each arrival is announced once, however many polls pass"
assert_eq "$([ -e "$BOX/to-lane.cursor" ] && cat "$BOX/to-lane.cursor" || echo none)" \
  "none" "the watch moves no cursor"
stop_watch
assert_eq "$([ -e "$BOX/to-lane.watch" ] && echo kept || echo withdrawn)" "withdrawn" \
  "a stopped watch withdraws its liveness record"
send_directive 'After the stop.'
assert_eq "${SENT##* }" "monitor=none" "so a send after the stop reads no monitor, and the lane is woken"

# The row the delivery claim stands on: the lane is idle, with nothing running
# but its watch; a directive lands; the command the announcement names, run as
# the woken turn runs it, hands the directive over; and nothing wrote to a pane.
# The woken turn runs it from another checkout, where a read that resolved its
# own root would open that checkout's mailbox and leave the lane's unread.
new_lane idle
OTHER="$TMP_ROOT/other-checkout"
mkdir -p "$OTHER"
git -C "$OTHER" init -q
git -C "$OTHER" config gc.auto 0
git -C "$OTHER" config maintenance.auto false
start_watch
await_polls 1
send_directive 'Hold the PR.'
await_announced 1
READ=""
if [ "$(announced)" -ge 1 ]; then
  READ="$(cd "$OTHER" && PATH="$STUB_BIN:$PATH" eval "$(sed -n 3p "$WATCH_OUT")")"
fi
assert_eq "$(jq -r '.kind + " " + .text' <<<"${READ:-null}" 2>/dev/null)" "directive Hold the PR." \
  "a directive sent to an idle lane is read by the command its watch's announcement names, from any checkout"
assert_eq "$(cat "$BOX/to-lane.cursor")=$([ -e "$OTHER/tmp" ] && echo stray || echo clean)" "1=clean" \
  "that inbox read advances the lane's cursor and opens no mailbox in the checkout it ran from"
assert_eq "$(wc -l <"$TMUX_LOG" | tr -d ' ')" "0" "the directive reached the idle lane with no pane write"
send_directive 'Then merge.'
await_announced 2
await_polls 2
assert_eq "$(mail_lines | tr '\n' '|')" "lane-mail: mail=KEN-1 new=1|lane-mail: mail=KEN-1 new=1|" \
  "an empty mailbox wakes nobody, and mail the lane has read is not announced again"
stop_watch

# An answer belongs to the `wait` that asked for it: the watch announces nothing
# for one, so the directive after it is announced alone.
new_lane answer
start_watch
await_polls 1
ASK="$(lm ask --item KEN-1 --file "$(text q 'Merge now?')")"
ASK="${ASK#id=}"
lm send --item KEN-1 --root "$LANE" --re "$ASK" --file "$(text a 'Merge it.')" >/dev/null
send_directive 'Also tag it.'
await_announced 1
await_polls 2
assert_eq "$(mail_lines | tr '\n' '|')" "lane-mail: mail=KEN-1 new=1|" "an answer wakes nothing"
assert_eq "$(lm wait --item KEN-1 --id "$ASK" --timeout 5 --interval 1)" "Merge it." \
  "the ask's wait still receives its answer"
stop_watch

# A watch started over a cursor the lane already moved: what it read is never
# announced, by a re-armed watch or after a hook read it between two polls.
new_lane read_first
send_directive 'Already read.'
lm inbox --item KEN-1 >/dev/null
start_watch
await_polls 1
send_directive 'Not yet read.'
await_announced 1
await_polls 2
assert_eq "$(mail_lines | tr '\n' '|')" "lane-mail: mail=KEN-1 new=1|" \
  "a watch announces nothing the cursor already passed"
stop_watch

# A watch run from another checkout names the lane with --root, and so does the
# command its announcement hands the woken turn.
new_lane rooted
mkdir -p "$TMP_ROOT/elsewhere"
send_directive 'From afar.'
stop_watch
: >"$WATCH_OUT"
(cd "$TMP_ROOT/elsewhere" && exec "$LANE_MAIL" watch --item KEN-1 --root "$LANE" --interval 1) \
  >"$WATCH_OUT" 2>"$WATCH_ERR" &
WATCH_PID=$!
await_announced 1
assert_eq "$(sed -n 3p "$WATCH_OUT")" "$(printf '%q inbox --item KEN-1 --root %q' "$LANE_MAIL" "$LANE")" \
  "a watch given --root hands over the inbox command with that root"
stop_watch

# The liveness record the receipt reads, judged on its age alone. At interval
# 5 the window is fifteen seconds: rows sit either side of it, and a record
# stamped ahead of the sender's clock is no evidence of a poll.
liveness_rows() { # [BIN]
  local row age rest
  new_lane "liveness${1:+-mutant}"
  for row in "17|none|a record just past twice its interval plus five seconds reads as no monitor" \
    "12|live|a record just inside that window reads as a live monitor" \
    "-60|none|a record stamped ahead of the sender's clock reads as no monitor"; do
    age="${row%%|*}"
    printf 'at=%s interval=5\n' "$(( $(date -u +%s) - age ))" >"$BOX/to-lane.watch"
    rest="${row#*|}"
    SENT="$(cd "$LANE" && "${1:-$LANE_MAIL}" send --item KEN-1 --root "$LANE" --directive \
      --file "$(text d "Liveness $age.")")"
    LIVENESS="$LIVENESS${SENT##* }|"
    [ -n "${1:-}" ] || assert_eq "${SENT##* }" "monitor=${rest%%|*}" "${rest#*|}"
  done
}
LIVENESS=""
liveness_rows

# Refusals, keyed on their first line.
new_lane refusals
RC=0
lm watch --item KEN-1 --interval soon >/dev/null 2>"$TMP_ROOT/err" || RC=$?
assert_eq "$RC=$(head -n 1 "$TMP_ROOT/err")" "2=lane-mail: seconds-invalid=--interval" \
  "an interval that is not a number of seconds is refused"
RC=0
lm watch --item KEN-9 --interval 1 >/dev/null 2>"$TMP_ROOT/err" || RC=$?
assert_eq "$RC=$(head -n 1 "$TMP_ROOT/err")" "2=lane-mail: mailbox-missing=$LANE/tmp/lane-mail/KEN-9" \
  "a watch of a mailbox no launch created is refused rather than polling nothing"
printf 'two\n' >"$BOX/to-lane.cursor"
RC=0
lm watch --item KEN-1 --interval 1 >/dev/null 2>"$TMP_ROOT/err" || RC=$?
assert_eq "$RC=$(head -n 1 "$TMP_ROOT/err")" "2=lane-mail: cursor-invalid=$BOX/to-lane.cursor" \
  "a cursor that holds no count stops the watch rather than announcing from zero"

new_lane removed
start_watch
await_polls 1
rm -rf -- "${LANE:?}/tmp"
TRIES=0
while kill -0 "$WATCH_PID" 2>/dev/null && [ "$TRIES" -lt 10 ]; do
  sleep 0.2
  TRIES=$((TRIES + 1))
done
RC=0
if kill -0 "$WATCH_PID" 2>/dev/null; then RC=running; else wait "$WATCH_PID" || RC=$?; fi
WATCH_PID=""
assert_eq "$RC=$(head -n 1 "$WATCH_ERR")" "2=lane-mail: mailbox-missing=$BOX" \
  "a watch whose mailbox is removed exits within two intervals"

# A long interval, so a stop that waited out the sleep would be seen. TERM ends
# the wait at once and the EXIT trap withdraws the liveness record.
term_row() { # [BIN] — sets TERMED to how the watch ended
  local tries=0
  new_lane "term${1:+-mutant}"
  start_watch "${1:-$LANE_MAIL}" --item KEN-1 --interval 30
  while [ ! -e "$BOX/to-lane.watch" ] && [ "$tries" -lt 25 ]; do sleep 0.2; tries=$((tries + 1)); done
  kill -TERM "$WATCH_PID"
  tries=0
  while kill -0 "$WATCH_PID" 2>/dev/null && [ "$tries" -lt 15 ]; do sleep 0.2; tries=$((tries + 1)); done
  if kill -0 "$WATCH_PID" 2>/dev/null; then TERMED=running; else TERMED=exited; fi
  # A KILL, not a second TERM: one still waiting would run its trap and blur
  # the record half of the verdict.
  kill -KILL "$WATCH_PID" 2>/dev/null || :
  wait "$WATCH_PID" 2>/dev/null || :
  WATCH_PID=""
  TERMED="$TERMED:$([ -e "$BOX/to-lane.watch" ] && echo record-kept || echo record-withdrawn)"
}
term_row
assert_eq "$TERMED" "exited:record-withdrawn" \
  "a TERM ends a watch mid-wait within three seconds and withdraws its liveness record"

# A KILL runs no trap, so what the lane's messages leave behind is what the
# poll removed before its wait: no copy of the mailbox under the watch's TMPDIR.
# The work directory itself stays, and counting it is what makes the copy count
# a reading of the watch's own files rather than of an empty directory.
kill_row() { # [BIN] — sets KILLED to the mailbox copies left behind, WORK_DIRS to the work directories there
  local tries=0 tag=real dir
  [ -z "${1:-}" ] || tag="$(basename -- "$(dirname -- "$1")")"
  dir="$TMP_ROOT/kill-tmp-$tag"
  new_lane "kill-$tag"
  send_directive 'A message worth keeping private.'
  mkdir -p "$dir"
  TMPDIR="$dir" start_watch "${1:-$LANE_MAIL}" --item KEN-1 --interval 30
  await_announced 1
  while [ -n "$(find "$dir" \( -name lane.raw -o -name lane.jsonl -o -name unread \) -print)" ] && [ "$tries" -lt 25 ]; do
    sleep 0.2
    tries=$((tries + 1))
  done
  kill -KILL "$WATCH_PID"
  wait "$WATCH_PID" 2>/dev/null || :
  WATCH_PID=""
  KILLED="$(find "$dir" \( -name lane.raw -o -name lane.jsonl -o -name unread \) -print | awk 'END { print NR + 0 }')"
  WORK_DIRS="$(find "$dir" -mindepth 1 -maxdepth 1 -type d -name 'lane-mail.*' -print | awk 'END { print NR + 0 }')"
}
kill_row
assert_eq "$KILLED/$WORK_DIRS" "0/1" \
  "a watch killed in its wait leaves no copy of the lane's mailbox in the work directory it made under TMPDIR"

# Controls, each a copy of lane-mail beside the libraries and siblings it
# sources, with one line of the watch removed.
mutant() { # NAME SED-EXPRESSION — MUTANT holds the copy
  local dir="$TMP_ROOT/mutant-$1"
  mkdir -p "$dir"
  sed "$2" "$LANE_MAIL" >"$dir/lane-mail"
  chmod +x "$dir/lane-mail"
  ln -s "$REPO_ROOT/skills/orch/scripts/lib" "$dir/lib"
  ln -s "$REPO_ROOT/skills/orch/scripts/git-context" "$dir/git-context"
  assert_eq "$(cmp -s "$dir/lane-mail" "$LANE_MAIL" && echo same || echo differs)" "differs" \
    "control: the $1 mutant really differs from lane-mail"
  MUTANT="$dir/lane-mail"
}

mutant announces-again 's@^      ANNOUNCED="\$(lm_count "\$WORK_DIR/lane.jsonl")"$@      :@'
new_lane control_again
send_directive 'Once.'
start_watch "$MUTANT"
await_announced 1
await_polls 2
assert_eq "$([ "$(announced)" -gt 1 ] && echo repeated || echo once)" "repeated" \
  "control: without the announced count the same directive is announced at every poll"
stop_watch

mutant cursor-ignored 's@^      \[ "\$ANNOUNCED" -ge "\$SEEN" \] || ANNOUNCED="\$SEEN"$@      :@'
new_lane control_cursor
send_directive 'Already read.'
lm inbox --item KEN-1 >/dev/null
start_watch "$MUTANT"
await_polls 1
send_directive 'Not yet read.'
await_announced 1
await_polls 2
assert_eq "$([ "$(mail_lines | tr '\n' '|')" = "lane-mail: mail=KEN-1 new=1|" ] && echo alone || echo read-mail-announced)" \
  "read-mail-announced" "control: without the cursor raise a watch announces mail the lane already read"
stop_watch

mutant foreground-sleep 's@^      sleep "\$INTERVAL" &$@      sleep "$INTERVAL"@;s@^      wait "\$!"$@      :@'
term_row "$MUTANT"
assert_eq "$TERMED" "running:record-kept" \
  "control: with the wait in the foreground a TERM waits out the interval"

mutant copies-kept 's@^      rm -f -- "\$WORK_DIR/lane.raw".*@      :@'
kill_row "$MUTANT"
assert_eq "$([ "$KILLED" -gt 0 ] && echo kept || echo none)" "kept" \
  "control: without the per-poll removal a killed watch leaves the mailbox copies behind"

# BSD mktemp, the one macOS ships, ignores TMPDIR for a bare template; this
# copy names another root the same way, so the row finds no work directory.
mutant tmpdir-ignored 's@^TMP_ROOT="\${TMPDIR:-/tmp}"$@TMP_ROOT="$KILL_ELSEWHERE"@'
export KILL_ELSEWHERE="$TMP_ROOT/kill-elsewhere"
mkdir -p "$KILL_ELSEWHERE"
kill_row "$MUTANT"
unset KILL_ELSEWHERE
assert_eq "$WORK_DIRS" "0" \
  "control: a work directory made outside TMPDIR leaves the killed-watch row nothing of its own to count"

mutant wider-window 's@now - at <= 2 \* interval + 5@now - at <= 4 * interval + 5@'
LIVENESS=""
liveness_rows "$MUTANT"
assert_eq "${LIVENESS%%|*}" "monitor=live" \
  "control: with the window widened a record just past the bound reads as live"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
