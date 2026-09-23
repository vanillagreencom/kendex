#!/usr/bin/env bash
# Tests for the one check oversee-watch runs about the session reading it: the
# OVERSEER's own pane. Every other check answers about a lane, and an overseer
# whose harness ended leaves its lanes working, this watch printing into a log
# nobody reads, and the fleet unattended. The lane side is oversee_watch_lanes.sh
# and the GitHub side oversee_watch.sh; all build their sandbox from
# lib/oversee-watch-harness.sh.
#
# The overseer pane here is %9, handed to the watch as $TMUX_PANE the way the
# shell the overseer started it in hands it over. `oversee-succeed` is a stub:
# what it does with a pane is its own suite's subject (oversee_succeed.sh), and
# what this one asserts is which of its two modes the watch calls, with what,
# and how often.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

# shellcheck source=lib/oversee-watch-harness.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/oversee-watch-harness.sh"
# The fleet log's `at` is written by `workflow-state append-file`, not by the
# publisher here, so a row that checks it reads the stamp back through the
# same ladder every other reader of that field uses.
# shellcheck source=../scripts/lib/date-ladder.sh
source "$REPO_ROOT/skills/orch/scripts/lib/date-ladder.sh"

PANE=%9
WINDOW=@7
# The line a live overseer's `--print-launch-line` would hand back, carrying a
# permission flag and a quoted brief: it crosses the fleet state and a file on
# its way to the relaunch, and a row below reads it back byte for byte.
LINE="env CLAUDE_CONFIG_DIR='/home/me/.claude' claude -n overseer --model fable --verbose 'Read .agents/skills/orch/SKILL.md'"
BYPASS_LINE="claude -n overseer --model old --dangerously-skip-permissions"
HANDOFF_DEFAULT=tmp/handoffs/OVERSEER-HANDOFF.md
# The measured Claude wall, and the instant a pass reading it is stamped at.
# Both are oversee_watch_usage_limit.sh's, so the wall an overseer meets and
# the wall a lane meets are the same text read by the same grammar; the row
# below pins what that pair resolves to.
WALL_BANNER="You've hit your usage limit \xc2\xb7 resets 9:50am (America/Los_Angeles)"
WALL_NOW=1788364800
# The account judgement that confirms a wall, and the two figures its line
# carries: `mark-reached kind=headroom` is oversee-succeed's own answer for a
# session whose account sits at or below its trigger, and the account and its
# reset come from the same `lanes context` row that measured the headroom.
WALL_ACCOUNT=9claude
WALL_RESETS=2026-09-02T16:50:00Z
WALL_MARK_LINE="oversee-succeed: mark-reached kind=headroom value=0 mark=10 succession=on account=$WALL_ACCOUNT resets=$WALL_RESETS"

# oversee-succeed stub. `--print-launch-line` answers with succeed.line (or the
# default below), `--dead-pane PANE --line-file PATH` records the relaunch
# and the file's contents, and `--walled-pane PANE` records the relaunch and
# prints the line it would have built. `--check-marks` answers with succeed.check, or with
# a below-mark line, which is the world every case that does not speak about
# the overseer's own marks runs in; succeed.check-later answers every reading
# after the first, and succeed.check-rc fails that judgement.
# Every mode appends its argv to succeed.args, so a case
# reads which mode ran and how many times. succeed.print-fail fails the print,
# succeed.rc is the relaunch's exit status.
cat > "$TMP_ROOT/bin/succeed-stub.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$*" >> "$STUB_DIR/succeed.args"
case "${1:-}" in
  --print-launch-line)
    [[ ! -f "$STUB_DIR/succeed.print-fail" && "$(cat "$STUB_DIR/cmd-${TMUX_PANE}.txt" 2>/dev/null)" != bash ]] \
      || { echo "oversee-succeed: no-status-line pane=$2" >&2; exit 1; }
    if [[ -f "$STUB_DIR/succeed.then-dead" ]]; then
      printf 'bash\n' > "$STUB_DIR/cmd-${TMUX_PANE}.txt"
      printf 'dev@host ~/kendex $\n' > "$STUB_DIR/pane-${TMUX_PANE}.txt"
      rm -- "$STUB_DIR/succeed.then-dead"
    fi
    if [[ -f "$STUB_DIR/succeed.line" ]]; then cat "$STUB_DIR/succeed.line"
    else echo "claude -n overseer 'brief'"; fi
    exit 0 ;;
  --check-marks)
    # The lane-read window this judgement inherits, recorded per call: the
    # watch names its own pass interval there so the reader inside serves a
    # figure it has not come round for yet instead of posting for it again.
    printf '%s\n' "${ORCH_LANES_USAGE_MAX_AGE:-unset}" >> "$STUB_DIR/succeed.max-age"
    rc=0; [[ ! -f "$STUB_DIR/succeed.check-rc" ]] || rc="$(cat "$STUB_DIR/succeed.check-rc")"
    # stdout is handed away before the wait: the watch reads this mode in a
    # command substitution, which stays open while any writer holds that pipe,
    # so a sleep left behind by the ceiling would outlast the kill.
    [[ ! -f "$STUB_DIR/succeed.check-hang" ]] || { exec 1>/dev/null; sleep 120; }
    if [[ "$rc" -ne 0 ]]; then
      echo "oversee-succeed: pane-unreadable pane=${TMUX_PANE:-none}" >&2
      exit "$rc"
    fi
    # succeed.check-later answers every reading after the first one taken
    # SINCE succeed.check-count was last cleared, so one process can be given
    # two different judgements. Nothing else can tell a reading memoised for
    # the pass from one memoised for the whole invocation. The counter is its
    # own file rather than a count of succeed.args, which accumulates across
    # every run a case makes.
    printf 'x' >> "$STUB_DIR/succeed.check-count"
    if [[ -f "$STUB_DIR/succeed.check-later" \
       && "$(wc -c < "$STUB_DIR/succeed.check-count")" -gt 1 ]]
    then cat "$STUB_DIR/succeed.check-later"
    elif [[ -f "$STUB_DIR/succeed.check" ]]; then cat "$STUB_DIR/succeed.check"
    else echo "oversee-succeed: context-below-mark tokens=100000 mark=500000 headroom=80"; fi
    exit 0 ;;
  --dead-pane)
    printf '%s\n' "$*" >> "$STUB_DIR/succeed.launched"
    [[ "${3:-}" != --line-file ]] || cat -- "$4" >> "$STUB_DIR/succeed.line-file"
    rc=0; [[ ! -f "$STUB_DIR/succeed.rc" ]] || rc="$(cat "$STUB_DIR/succeed.rc")"
    [[ "$rc" -eq 0 ]] || echo "oversee-succeed: pane-unreadable pane=$2" >&2
    exit "$rc" ;;
  --walled-pane)
    printf '%s\n' "$*" >> "$STUB_DIR/succeed.launched"
    rc=0; [[ ! -f "$STUB_DIR/succeed.rc" ]] || rc="$(cat "$STUB_DIR/succeed.rc")"
    # The three answers this mode gives its caller: the line it built on
    # stdout at 0, the fleet having no room at 3, and every other failure at 1.
    case "$rc" in
      0) if [[ -f "$STUB_DIR/succeed.line" ]]; then cat "$STUB_DIR/succeed.line"
         else echo "env CLAUDE_CONFIG_DIR='/home/me/.eclaude' claude -n overseer 'brief'"; fi ;;
      3) echo "oversee-succeed: no-lane-qualifies entries=1 mark=wall" >&2 ;;
      *) echo "oversee-succeed: pane-unreadable pane=$2" >&2 ;;
    esac
    exit "$rc" ;;
esac
printf 'unexpected oversee-succeed call: %s\n' "$*" >&2
exit 2
EOF
chmod +x "$TMP_ROOT/bin/succeed-stub.sh"

# A repeat pass is a child of the live watch that already published the
# command. The wrapper gives a one-pass fixture that same process boundary.
cat > "$TMP_ROOT/bin/watch-child-stub.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
export OVERSEE_WATCH_REPEAT_OWNER=$$
"$CHILD_WATCH_BIN" "$@"
EOF
chmod +x "$TMP_ROOT/bin/watch-child-stub.sh"

echo "=== oversee-watch: the overseer's own pane ==="

# overseer_case NAME STATE — a fresh sandbox whose overseer pane reads STATE,
# with no lane window and no item, so the only thing any pass can find is the
# overseer. `exited` is the shape the shared judge answers on: a bare shell in
# the pane with nothing under it, which is what an overseer that ran /exit
# leaves. `idle` is the harness still there, drawing its composer.
overseer_case() { # NAME STATE
  new_case "$1"
  printf '' > "$STUB_DIR/windows.txt"
  printf '%s\n' "$WINDOW" > "$STUB_DIR/window-id-$PANE.txt"
  printf '7000 %s\n' "$PANE" > "$STUB_DIR/pane-key-$PANE.txt"
  printf '9009\n' > "$STUB_DIR/panepid-$PANE.txt"
  case "$2" in
    exited) printf 'bash\n' > "$STUB_DIR/cmd-$PANE.txt"
            printf 'dev@host ~/kendex $\n' > "$STUB_DIR/pane-$PANE.txt"
            touch "$STUB_DIR/repeat-child" ;;
    idle)   printf 'claude\n' > "$STUB_DIR/cmd-$PANE.txt"
            printf '%b\n' '⏺ Watching the fleet.' '\xe2\x9d\xaf\xc2\xa0' > "$STUB_DIR/pane-$PANE.txt" ;;
    # The harness alive and the account spent: the banner below the last turn,
    # with the composer under it, which is the shape the shared judge answers
    # `walled` on. The clock is pinned so the reset the banner states resolves
    # to one instant on a runner in any zone.
    walled) printf 'claude\n' > "$STUB_DIR/cmd-$PANE.txt"
            printf '%b\n' '⏺ Watching the fleet.' "$WALL_BANNER" '\xe2\x9d\xaf\xc2\xa0' > "$STUB_DIR/pane-$PANE.txt"
            printf '%s\n' "$WALL_NOW" > "$STUB_DIR/now.epoch"
            touch "$STUB_DIR/repeat-child" ;;
    # A turn in flight behind a limit phrase the overseer printed in its own
    # output: the judge answers `working`, so nothing here is touched.
    limit_text) printf 'claude\n' > "$STUB_DIR/cmd-$PANE.txt"
            printf '%b\n' '⏺ Reading the suite.' "  printf \"$WALL_BANNER\"" 'esc to interrupt' > "$STUB_DIR/pane-$PANE.txt" ;;
    *) echo "overseer_case: unknown state $2" >&2; exit 1 ;;
  esac
  rm -rf -- "${CASE_REPO_ROOT:?}/tmp/lane-mail"
}

# recorded FIELD — the overseer record the fleet state now holds.
recorded() { jq -r ".overseer.$1 // \"none\"" "$STUB_DIR/oversee-state.json"; }
# state_with LINE — a fleet state already naming this pane, its window and LINE.
state_with() { # LINE
  jq -n --arg server "7000" --arg pane "$PANE" --arg window "$WINDOW" --arg line "$1" \
    '{triaged: [], overseer: {server: $server, pane: $pane, window: $window, launch_line: $line}}' \
    > "$STUB_DIR/oversee-state.json"
}
# succeed_calls MODE — how many times the stub was called in MODE. A stub
# never called wrote no file at all, which is zero calls and not a read
# failure, so the count is taken from what the file holds rather than from
# grep's status.
succeed_calls() { grep -c -- "^$1" < <(cat -- "$STUB_DIR/succeed.args" 2>/dev/null) || true; }
# notice CHANNEL — the delivered text, from the fleet log or the mailbox.
fleet_log_text() { jq -r '(.fleet_log // []) | map(select(.item == "overseer")) | last | .text // "none"' "$STUB_DIR/oversee-state.json"; }
fleet_log_kind() { jq -r '(.fleet_log // []) | map(select(.item == "overseer")) | last | .kind // "none"' "$STUB_DIR/oversee-state.json"; }
fleet_log_at() { jq -r '(.fleet_log // []) | map(select(.item == "overseer")) | last | .at // "none"' "$STUB_DIR/oversee-state.json"; }
mailbox() { # FIELD
  local f="$CASE_REPO_ROOT/tmp/lane-mail/overseer/to-lane.jsonl"
  [[ -f "$f" ]] || { echo none; return 0; }
  tail -n 1 "$f" | jq -r ".$1 // \"none\""
}
mailbox_lines() {
  local f="$CASE_REPO_ROOT/tmp/lane-mail/overseer/to-lane.jsonl"
  [[ -f "$f" ]] && wc -l < "$f" | tr -d ' ' || echo 0
}
mail_cursor_count() {
  local f
  f="$(find "$STATE_DIR" -maxdepth 1 -type f -name 'overseer-mail__*' -print -quit)"
  [[ -n "$f" ]] && awk '{print $1}' "$f" || echo 0
}

RUN_SEQ=0
run() { # ENV=VAL... -- ARGS...
  local arg repeat_parent=0 target
  ERR="$TMP_ROOT/run-$((++RUN_SEQ)).err"
  for arg in "$@"; do
    [[ "$arg" != --repeat && "$arg" != --repeat=* ]] || repeat_parent=1
  done
  target="${WATCH_BIN:-.agents/skills/orch/scripts/oversee-watch}"
  if [[ -f "$STUB_DIR/repeat-child" && "$repeat_parent" -eq 0 ]]; then
    OUT="$(WATCH_BIN="$TMP_ROOT/bin/watch-child-stub.sh" run_watch \
      OVERSEE_WATCH_SUCCEED="$TMP_ROOT/bin/succeed-stub.sh" CHILD_WATCH_BIN="$target" "$@" 2>"$ERR" </dev/null)" \
      && RC=0 || RC=$?
  else
    OUT="$(run_watch OVERSEE_WATCH_SUCCEED="$TMP_ROOT/bin/succeed-stub.sh" "$@" 2>"$ERR" </dev/null)" \
    && RC=0 || RC=$?
  fi
}

# --- the death itself, and the relaunch it ends in -------------------------
# Two passes in one run: the first reading is a poll that caught a live session
# between its harness and its shell, and only the second is news.
overseer_case dead_relaunch exited
state_with "$LINE"
FL_BEFORE="$(date -u +%s)"
run TMUX_PANE="$PANE" -- --max-loops 2
FL_AFTER="$(date -u +%s)"
assert_eq "$RC" "3" "a relaunched overseer ends the watch with its own status" "$ERR"
assert_eq "$(head -n 1 <<<"$OUT")" "EVENT overseer-dead $PANE window=$WINDOW passes=2 succession=on" \
  "the event names the pane, its window, the passes it took and the setting" "$ERR"
assert_eq "$(succeed_calls --dead-pane)" "1" "the launch path is called once" "$ERR"
# The line reaches the launcher through a file in the watch's own scratch
# directory, whose name is a fresh mktemp -d per run: the launched argv is
# read with that path's leading directories replaced, so the row pins the
# call's shape and the file it names rather than one run's temporary path.
assert_eq "$(sed 's|--line-file .*/|--line-file |' "$STUB_DIR/succeed.launched")" \
  "--dead-pane $PANE --line-file overseer-line" \
  "the relaunch names the dead pane and the file holding its line" "$ERR"
assert_eq "$(cat "$STUB_DIR/succeed.line-file")" "$LINE" \
  "the file holds the recorded launch line, quoting and all" "$ERR"
assert_eq "$(succeed_calls --check-marks)" "0" \
  "a dead overseer runs no turn, so neither of its own marks is judged" "$ERR"

# A pass that found nothing to relaunch leaves every other check its turn; a
# pass that relaunched does not, because the successor drains that mail itself.
assert_not_contains "$OUT" "EVENT heartbeat" "the relaunching pass never reaches the heartbeat" "$ERR"

# --- the two channels the notice reaches a successor on --------------------
assert_eq "$(fleet_log_kind)" "close" "the fleet log records the death as a close" "$ERR"
assert_contains "$(fleet_log_text)" "overseer-dead: the overseer session in tmux window $WINDOW (pane $PANE) read exited on 2 consecutive watch passes" \
  "the fleet log entry names the window, the pane and the passes" "$ERR"
assert_contains "$(fleet_log_text)" "A successor is being launched into that window from the recorded launch line." \
  "and says a successor is coming" "$ERR"
assert_eq "$(mailbox kind)" "directive" "the overseer mailbox carries it as a directive" "$ERR"
assert_eq "$(mailbox from)" "owner" "which a successor reads as an owner-note" "$ERR"
assert_eq "$(mailbox text)" "$(fleet_log_text)" \
  "both channels carry one text, so they cannot describe the death differently" "$ERR"

# The published record carries no time of its own, so the entry's `at` can
# only be the append's clock reading. A successor reads the fleet log in
# order, and a time the publisher chose would misdate it.
FL_AT="$(fleet_log_at)"
FL_AT_EPOCH="$(to_epoch "$FL_AT")" || FL_AT_EPOCH=""
assert_eq "$([[ "$FL_AT" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] && echo iso || echo "$FL_AT")" \
  "iso" "the fleet log entry is dated in the ISO8601 UTC form" "$ERR"
assert_eq "$([[ -n "$FL_AT_EPOCH" && "$FL_AT_EPOCH" -ge "$FL_BEFORE" && "$FL_AT_EPOCH" -le "$FL_AFTER" ]] \
  && echo in-window || echo "$FL_AT")" \
  "in-window" "and inside the window this run took, so the append stamped it" "$ERR"

# --- one pass is not a death ----------------------------------------------
overseer_case dead_one_pass exited
state_with "$LINE"
printf 'Retain this event for the next live overseer.\n' > "$TMP_ROOT/held-event.txt"
(cd "$CASE_REPO_ROOT" && "$REPO_ROOT/skills/orch/scripts/lane-mail" send \
  --item overseer --directive --file "$TMP_ROOT/held-event.txt" >/dev/null)
HELD_EVENT="$(jq -r .id "$CASE_REPO_ROOT/tmp/lane-mail/overseer/to-lane.jsonl")"
run TMUX_PANE="$PANE" -- --max-loops 1
assert_eq "rc=$RC first=$(head -n 1 <<<"$OUT")" "rc=0 first=EVENT heartbeat loops=1 interval=0s since=none" \
  "one exited reading is a poll, not news" "$ERR"
assert_eq "$(succeed_calls --dead-pane)" "0" "and nothing is launched on it" "$ERR"
assert_eq "events=$(grep -c '^EVENT owner-note' <<<"$OUT" || true) cursor=$(mail_cursor_count)" \
  "events=0 cursor=0" "and its event baseline stays unchanged" "$ERR"
printf 'claude\n' > "$STUB_DIR/cmd-$PANE.txt"
printf '%b\n' '⏺ The overseer is live.' '\xe2\x9d\xaf\xc2\xa0' > "$STUB_DIR/pane-$PANE.txt"
run TMUX_PANE="$PANE" -- --max-loops 1
assert_eq "events=$(grep -c "^EVENT owner-note $HELD_EVENT$" <<<"$OUT" || true) cursor=$(mail_cursor_count)" \
  "events=1 cursor=1" "the later live reading delivers the retained event" "$ERR"

# --- a live overseer ------------------------------------------------------
overseer_case alive idle
state_with "$LINE"
run TMUX_PANE="$PANE" -- --max-loops 2
assert_eq "rc=$RC first=$(head -n 1 <<<"$OUT")" "rc=0 first=EVENT heartbeat loops=2 interval=0s since=none" \
  "an overseer at its composer emits nothing, however many passes run" "$ERR"
assert_eq "$(succeed_calls --dead-pane)" "0" "and nothing is launched for it" "$ERR"
assert_eq "$(mailbox kind)" "none" "and no notice is delivered" "$ERR"

# A pane that comes back to life clears its count, so the next death starts
# over rather than firing on its first reading.
overseer_case dead_then_alive exited
state_with "$LINE"
run TMUX_PANE="$PANE" -- --max-loops 1
printf 'claude\n' > "$STUB_DIR/cmd-$PANE.txt"
printf '%b\n' '⏺ Back at it.' '\xe2\x9d\xaf\xc2\xa0' > "$STUB_DIR/pane-$PANE.txt"
run TMUX_PANE="$PANE" -- --max-loops 1
printf 'bash\n' > "$STUB_DIR/cmd-$PANE.txt"
printf 'dev@host ~/kendex $\n' > "$STUB_DIR/pane-$PANE.txt"
run TMUX_PANE="$PANE" -- --max-loops 1
assert_eq "rc=$RC launched=$(succeed_calls --dead-pane)" "rc=0 launched=0" \
  "a pane that drew a live screen between two exited ones starts its count over" "$ERR"

# --- the overseer's own marks ---------------------------------------------
# The event reaches an overseer BETWEEN turn ends, where its own turn-end hook
# cannot. The judgement is oversee-succeed's, so what is asserted here is which
# of its answers becomes an event, what that event carries, how often a
# standing mark comes back, and which answers leave a standing mark where it is.
MARK_LINE="oversee-succeed: mark-reached kind=context value=612000 mark=500000 succession=on headroom=80"
marks_seen() { grep -c '^EVENT overseer-mark' <<<"$OUT" || true; }
mark_stands() { printf '%s\n' "$MARK_LINE" > "$STUB_DIR/succeed.check"; }
mark_lifts() { rm -f -- "${STUB_DIR:?}/succeed.check"; }

overseer_case mark_reported idle
state_with "$LINE"
mark_stands
run TMUX_PANE="$PANE" ORCH_OVERSEER_MARK_REPEAT=3 ORCH_OVERSEER_PREFERENCE=claude:1:high -- --max-loops 1
assert_eq "rc=$RC first=$(head -n 1 <<<"$OUT")" \
  "rc=0 first=EVENT overseer-mark $PANE kind=context value=612000 mark=500000 succession=on" \
  "a reached mark becomes the event, carrying its kind, the value read and the mark crossed" "$ERR"
assert_contains "$OUT" "-- [FLAGS] at the next safe point, with ORCH_OVERSEER_PREFERENCE=claude:1:high choosing the successor lane." \
  "and the line under it names the succession and the fleet's preference" "$ERR"

# The same mark stands on every pass until the overseer hands over. A line on
# each would bury every other event in the block; one that never came back
# would let the mark ride out the fleet after a single reading.
for pass in 1 2; do
  run TMUX_PANE="$PANE" ORCH_OVERSEER_MARK_REPEAT=3 -- --max-loops 1
  assert_eq "rc=$RC marks=$(marks_seen)" "rc=0 marks=0" \
    "pass $pass under the repeat count leaves the standing mark unsaid" "$ERR"
done
run TMUX_PANE="$PANE" ORCH_OVERSEER_MARK_REPEAT=3 -- --max-loops 1
assert_eq "rc=$RC marks=$(marks_seen)" "rc=0 marks=1" \
  "and the repeat count brings the standing mark back" "$ERR"

# An overseer with room is told nothing, and a mark that lifts and returns is
# news again rather than waiting out the count from its first crossing.
overseer_case mark_below idle
state_with "$LINE"
run TMUX_PANE="$PANE" ORCH_OVERSEER_MARK_REPEAT=3 -- --max-loops 1
assert_eq "rc=$RC marks=$(marks_seen) first=$(head -n 1 <<<"$OUT")" \
  "rc=0 marks=0 first=EVENT heartbeat loops=1 interval=0s since=none" \
  "an overseer under both marks is reported nothing" "$ERR"
mark_stands
run TMUX_PANE="$PANE" ORCH_OVERSEER_MARK_REPEAT=3 -- --max-loops 1
assert_eq "marks=$(marks_seen)" "marks=1" "the crossing is the event" "$ERR"
mark_lifts
run TMUX_PANE="$PANE" ORCH_OVERSEER_MARK_REPEAT=3 -- --max-loops 1
assert_eq "marks=$(marks_seen)" "marks=0" "a mark that lifts says nothing on its way down" "$ERR"
mark_stands
run TMUX_PANE="$PANE" ORCH_OVERSEER_MARK_REPEAT=3 -- --max-loops 1
assert_eq "marks=$(marks_seen)" "marks=1" \
  "and a mark reached again is news, not a pass of the count it left behind" "$ERR"

# A reading that could not be taken is that script's own answer, and it settles
# nothing: the standing mark keeps its place in the repeat count instead of
# coming back as a fresh crossing on the next pass that could measure.
overseer_case mark_unmeasured idle
state_with "$LINE"
mark_stands
run TMUX_PANE="$PANE" ORCH_OVERSEER_MARK_REPEAT=3 -- --max-loops 1
assert_eq "marks=$(marks_seen)" "marks=1" "the crossing is reported once" "$ERR"
printf '%s\n' "oversee-succeed: mark-unmeasured kind=headroom reason=headroom-unreadable succession=on" \
  > "$STUB_DIR/succeed.check"
run TMUX_PANE="$PANE" ORCH_OVERSEER_MARK_REPEAT=3 -- --max-loops 1
assert_eq "rc=$RC marks=$(marks_seen)" "rc=0 marks=0" \
  "an unmeasured reading reports no mark and ends no pass" "$ERR"
assert_contains "$(cat "$ERR")" "oversee-watch: overseer-mark-unjudged" \
  "and says so under the key a judgement that failed takes" "$ERR"
mark_stands
run TMUX_PANE="$PANE" ORCH_OVERSEER_MARK_REPEAT=3 -- --max-loops 1
assert_eq "marks=$(marks_seen)" "marks=0" \
  "and the standing mark kept its place in the count rather than starting over" "$ERR"

# The judgement reads every account the fleet can launch on, and a pass that
# spent its whole interval there would delay every other event it carries.
if command -v timeout >/dev/null 2>&1; then
  # The copy shortens the ceiling so the row need not wait out the real one.
  CEILING_DIR="$TMP_ROOT/ceiling"
  mkdir -p "$CEILING_DIR/orch"
  cp -R "$REPO_ROOT/skills/orch/scripts" "$CEILING_DIR/orch/scripts"
  ln -s "$REPO_ROOT/skills/github" "$CEILING_DIR/github"
  sed 's/^MARK_CEILING=60$/MARK_CEILING=1/' \
    "$REPO_ROOT/skills/orch/scripts/oversee-watch" > "$CEILING_DIR/orch/scripts/oversee-watch"
  chmod +x "$CEILING_DIR/orch/scripts/oversee-watch"
  assert_eq "$(cmp -s "$CEILING_DIR/orch/scripts/oversee-watch" "$REPO_ROOT/skills/orch/scripts/oversee-watch" && echo same || echo differs)" \
    "differs" "the shortened-ceiling copy really differs from the watch"
  overseer_case mark_ceiling idle
  state_with "$LINE"
  mark_stands
  touch "$STUB_DIR/succeed.check-hang"
  WATCH_BIN="$CEILING_DIR/orch/scripts/oversee-watch" run TMUX_PANE="$PANE" -- --max-loops 1
  assert_eq "rc=$RC marks=$(marks_seen)" "rc=0 marks=0" \
    "a judgement the ceiling abandoned reports no mark and ends no pass" "$ERR"
  assert_contains "$(cat "$ERR")" "oversee-watch: overseer-mark-unjudged path=" \
    "and says so under the key a judgement that failed takes" "$ERR"
  assert_contains "$(cat "$ERR")" "seconds=1" "naming the seconds it was given" "$ERR"
else
  printf '  skip  a judgement past the ceiling: this host has no timeout to bound it with\n'
fi

# Succession off launches nothing, so the line says so: an overseer past its
# own mark still has to hand over, by hand.
overseer_case mark_succession_off idle
state_with "$LINE"
printf '%s\n' "oversee-succeed: mark-reached kind=headroom value=20 mark=20 succession=off account=claude resets=2026-07-27T06:00:00Z" \
  > "$STUB_DIR/succeed.check"
run ORCH_OVERSEER_SUCCESSION=off TMUX_PANE="$PANE" -- --max-loops 1
assert_eq "rc=$RC first=$(head -n 1 <<<"$OUT")" \
  "rc=0 first=EVENT overseer-mark $PANE kind=headroom value=20 mark=20 succession=off" \
  "the account mark reports its own kind and value, with the setting on the line" "$ERR"
assert_contains "$OUT" "ORCH_OVERSEER_SUCCESSION is off, so no successor opens" \
  "and the line under it sends the overseer to a handoff by hand" "$ERR"

# A judgement that could not be made settles nothing: it is not a mark, and it
# is not evidence that a standing mark lifted.
overseer_case mark_unjudged idle
state_with "$LINE"
mark_stands
run TMUX_PANE="$PANE" ORCH_OVERSEER_MARK_REPEAT=3 -- --max-loops 1
assert_eq "marks=$(marks_seen)" "marks=1" "the crossing is reported once" "$ERR"
printf '2\n' > "$STUB_DIR/succeed.check-rc"
run TMUX_PANE="$PANE" ORCH_OVERSEER_MARK_REPEAT=3 -- --max-loops 1
assert_eq "rc=$RC marks=$(marks_seen)" "rc=0 marks=0" \
  "a judgement that failed reports no mark and ends no pass" "$ERR"
assert_contains "$(cat "$ERR")" "oversee-watch: overseer-mark-unjudged" \
  "and says so under its own key" "$ERR"
assert_contains "$(cat "$ERR")" "oversee-succeed: pane-unreadable" \
  "with the judge's own keyed line standing under the watch's" "$ERR"
rm -f -- "${STUB_DIR:?}/succeed.check-rc"
run TMUX_PANE="$PANE" ORCH_OVERSEER_MARK_REPEAT=3 -- --max-loops 1
assert_eq "marks=$(marks_seen)" "marks=0" \
  "and the standing mark kept its place in the count rather than starting over" "$ERR"

# The judge itself absent from the install: OVERSEE_WATCH_SUCCEED names the
# path, and a tree with no oversee-succeed there takes this arm on every pass.
# The mark is unjudged rather than read as lifted, and the setting is named so
# the path can be corrected.
NO_JUDGE="$TMP_ROOT/no-such-oversee-succeed"
overseer_case mark_no_judge idle
state_with "$LINE"
run TMUX_PANE="$PANE" OVERSEE_WATCH_SUCCEED="$NO_JUDGE" -- --max-loops 1
assert_eq "rc=$RC marks=$(marks_seen) line=$(grep -c "^oversee-watch: overseer-mark-unjudged path=$NO_JUDGE setting=OVERSEE_WATCH_SUCCEED\$" "$ERR")" \
  "rc=0 marks=0 line=1" \
  "a judge the install has not got leaves the mark unjudged and names the setting" "$ERR"

# A standing mark belongs to the session that reached it. The session dies with
# its mark standing and a replacement starts in the same pane, which is the
# shape a refused succession leaves the operator: its own first crossing is the
# event, rather than a pass of a count the dead session ran up.
# The case opens on the dead shape so every pass here is a repeat child, the
# way a running watch's passes are; the pane is made live for the first of them.
overseer_case mark_dead_replacement exited
state_with "$LINE"
printf 'claude\n' > "$STUB_DIR/cmd-$PANE.txt"
printf '%b\n' '⏺ Watching the fleet.' '\xe2\x9d\xaf\xc2\xa0' > "$STUB_DIR/pane-$PANE.txt"
printf '%s\n' "oversee-succeed: mark-reached kind=headroom value=12 mark=20 succession=on" \
  > "$STUB_DIR/succeed.check"
run TMUX_PANE="$PANE" ORCH_OVERSEER_MARK_REPEAT=3 -- --max-loops 1
assert_eq "marks=$(marks_seen)" "marks=1" "the dying session's own crossing is reported once" "$ERR"
run TMUX_PANE="$PANE" ORCH_OVERSEER_MARK_REPEAT=3 -- --max-loops 1
assert_eq "marks=$(marks_seen)" "marks=0" "and its next pass stands under the repeat count" "$ERR"
printf 'bash\n' > "$STUB_DIR/cmd-$PANE.txt"
printf 'dev@host ~/kendex $\n' > "$STUB_DIR/pane-$PANE.txt"
run TMUX_PANE="$PANE" ORCH_OVERSEER_MARK_REPEAT=3 -- --max-loops 1
assert_eq "rc=$RC marks=$(marks_seen)" "rc=0 marks=0" \
  "the pane then reads dead, which judges no mark of its own" "$ERR"
printf 'claude\n' > "$STUB_DIR/cmd-$PANE.txt"
printf '%b\n' '⏺ Replacement is live.' '\xe2\x9d\xaf\xc2\xa0' > "$STUB_DIR/pane-$PANE.txt"
printf '%s\n' "$LINE" > "$STUB_DIR/succeed.line"
run TMUX_PANE="$PANE" ORCH_OVERSEER_MARK_REPEAT=3 -- --max-loops 1
assert_eq "marks=$(marks_seen)" "marks=1" \
  "and the same-pane replacement is told its own crossing at once" "$ERR"

# --- succession off -------------------------------------------------------
overseer_case succession_off exited
state_with "$LINE"
run ORCH_OVERSEER_SUCCESSION=off TMUX_PANE="$PANE" -- --max-loops 2
assert_eq "$RC" "4" "with succession off the child tells its live owner to stop" "$ERR"
assert_eq "$(head -n 1 <<<"$OUT")" "EVENT overseer-dead $PANE window=$WINDOW passes=2 succession=off" \
  "the event says the setting is off" "$ERR"
assert_eq "$(succeed_calls --dead-pane)" "0" "and nothing is launched" "$ERR"
assert_contains "$(fleet_log_text)" "ORCH_OVERSEER_SUCCESSION is off, so no successor is launched; start one by hand." \
  "the notice tells the reader why the pane is still the dead one" "$ERR"
assert_eq "$(mailbox kind)" "directive" "the notice is still delivered" "$ERR"

# --- a death the watch cannot act on --------------------------------------
# No line in the state and none derivable: the notice goes out and says so,
# rather than a launch of nothing or a silence.
overseer_case no_line exited
state_with ""
run TMUX_PANE="$PANE" -- --max-loops 2
assert_eq "rc=$RC first=$(head -n 1 <<<"$OUT")" \
  "rc=4 first=EVENT overseer-dead $PANE window=$WINDOW passes=2 succession=on" \
  "a death with no recorded line is still the event" "$ERR"
assert_eq "$(succeed_calls --dead-pane)" "0" "and launches nothing" "$ERR"
assert_contains "$(fleet_log_text)" "The fleet state records no overseer launch line, so no successor is launched; start one by hand." \
  "the notice names the missing line as the reason" "$ERR"
assert_eq "$(succeed_calls --print-launch-line)" "0" \
  "the child does not try to replace the command its owner published" "$ERR"

# A launcher that refuses leaves one bounded retry. The watch records each
# outcome and keeps the owner notes unread for the replacement.
overseer_case relaunch_refused exited
state_with "$LINE"
printf '4\n' > "$STUB_DIR/succeed.rc"
run TMUX_PANE="$PANE" -- --max-loops 2
assert_eq "rc=$RC launched=$(succeed_calls --dead-pane)" "rc=0 launched=1" \
  "a refused relaunch neither ends the watch nor is retried in the same pass" "$ERR"
assert_contains "$(cat "$ERR")" "oversee-watch: overseer-relaunch-failed pane=$PANE attempt=1 retry=pending step=launcher" \
  "the first refusal records a pending retry" "$ERR"
assert_contains "$(cat "$ERR")" "oversee-succeed: pane-unreadable pane=$PANE" \
  "with the launcher's own keyed line under it" "$ERR"
assert_not_contains "$OUT" "EVENT owner-note" \
  "the failed pass leaves the recovery notes unread for the replacement" "$ERR"
assert_eq "mail=$(mailbox_lines) log=$(jq '[.fleet_log[] | select(.item == "overseer")] | length' "$STUB_DIR/oversee-state.json")" \
  "mail=2 log=2" "the death and first failed outcome reach both channels" "$ERR"
assert_contains "$(mailbox text)" "overseer-relaunch-failed: successor launch for tmux window $WINDOW (pane $PANE) failed on attempt 1; retry=pending; step=launcher." \
  "the mailbox carries the first failed outcome" "$ERR"
assert_eq "$(mailbox text)" "$(fleet_log_text)" \
  "the fleet log carries that same first failed outcome" "$ERR"
run TMUX_PANE="$PANE" -- --max-loops 1
assert_eq "events=$(grep -c '^EVENT overseer-dead' <<<"$OUT" || true) launched=$(succeed_calls --dead-pane)" \
  "events=0 launched=2" "the next pass retries without repeating the death event" "$ERR"
assert_contains "$(cat "$ERR")" "oversee-watch: overseer-relaunch-failed pane=$PANE attempt=2 retry=exhausted step=launcher" \
  "the second refusal records that the retry is spent" "$ERR"
assert_eq "mail=$(mailbox_lines) log=$(jq '[.fleet_log[] | select(.item == "overseer")] | length' "$STUB_DIR/oversee-state.json")" \
  "mail=3 log=3" "the final failed outcome reaches both channels" "$ERR"
assert_contains "$(mailbox text)" "overseer-relaunch-failed: successor launch for tmux window $WINDOW (pane $PANE) failed on attempt 2; retry=exhausted; step=launcher." \
  "the mailbox carries the exhausted failed outcome" "$ERR"
assert_eq "$(mailbox text)" "$(fleet_log_text)" \
  "the fleet log carries that same exhausted failed outcome" "$ERR"
run TMUX_PANE="$PANE" -- --max-loops 1
assert_eq "events=$(grep -c '^EVENT overseer-dead' <<<"$OUT" || true) launched=$(succeed_calls --dead-pane)" \
  "events=0 launched=2" "later passes neither repeat the event nor exceed the retry bound" "$ERR"

# A manual live replacement owns the mailbox the dead watch held. Its first
# pass receives the death and both failed outcomes, then advances the cursor so
# a later pass cannot replay them.
printf 'claude\n' > "$STUB_DIR/cmd-$PANE.txt"
printf '%b\n' '⏺ Replacement is live.' '\xe2\x9d\xaf\xc2\xa0' > "$STUB_DIR/pane-$PANE.txt"
printf '%s\n' "$LINE" > "$STUB_DIR/succeed.line"
run TMUX_PANE="$PANE" -- --max-loops 1
assert_eq "notes=$(grep -c '^EVENT owner-note' <<<"$OUT" || true) cursor=$(mail_cursor_count)" \
  "notes=3 cursor=3" "the live replacement receives every held recovery note and advances the cursor" "$ERR"
assert_contains "$OUT" "overseer-dead: the overseer session in tmux window $WINDOW" \
  "the delivered notes include the death" "$ERR"
assert_contains "$OUT" "failed on attempt 1; retry=pending; step=launcher" \
  "the delivered notes include the first failed launch" "$ERR"
assert_contains "$OUT" "failed on attempt 2; retry=exhausted; step=launcher" \
  "the delivered notes include the exhausted retry" "$ERR"
run TMUX_PANE="$PANE" -- --max-loops 1
assert_eq "notes=$(grep -c '^EVENT owner-note' <<<"$OUT" || true) cursor=$(mail_cursor_count)" \
  "notes=0 cursor=3" "the replacement's later pass replays none of the recovery notes" "$ERR"

# --- recording the line while the overseer is alive ------------------------
# The first watch of a fleet: no record, so the pane, its window and the line
# `oversee-succeed --print-launch-line` builds are written before anything
# needs them.
overseer_case record_first_start idle
printf '{"triaged":[]}\n' > "$STUB_DIR/oversee-state.json"
printf '%s\n' "$LINE" > "$STUB_DIR/succeed.line"
run TMUX_PANE="$PANE" -- --max-loops 1 --handoff tmp/handoffs/FLEET.md -- --verbose --model fable
assert_eq "server=$(recorded server) pane=$(recorded pane) window=$(recorded window)" "server=7000 pane=$PANE window=$WINDOW" \
  "the first start records the tmux server, pane and window" "$ERR"
assert_eq "$(recorded launch_line)" "$LINE" "and the line a successor of it would run" "$ERR"
assert_eq "$(grep -- '^--print-launch-line' "$STUB_DIR/succeed.args")" \
  "--print-launch-line --handoff tmp/handoffs/FLEET.md -- --verbose --model fable" \
  "the handoff path and the overseer's own flags reach the builder" "$ERR"
assert_eq "$(succeed_calls --print-launch-line)" "1" \
  "and the line is built once, not once per pass" "$ERR"

# A manual replacement can reuse the same durable tmux server, pane and window.
# Its new watch owns the command and replaces the former session's bypass flag.
overseer_case record_same_pane_restart idle
jq -n --arg pane "$PANE" --arg window "$WINDOW" \
  '{triaged: [], overseer: {server: "7000", pane: $pane, window: $window, launch_line: "claude -n overseer --model old --dangerously-skip-permissions"}}' \
  > "$STUB_DIR/oversee-state.json"
printf '%s\n' "$LINE" > "$STUB_DIR/succeed.line"
run TMUX_PANE="$PANE" -- --max-loops 1 -- --model fable
assert_eq "server=$(recorded server) pane=$(recorded pane) window=$(recorded window) line=$(recorded launch_line)" \
  "server=7000 pane=$PANE window=$WINDOW line=$LINE" \
  "a same-pane replacement records its current restricted command" "$ERR"
assert_eq "$(succeed_calls --print-launch-line)" "1" \
  "the live replacement derives its command once at watch startup" "$ERR"

# A live replacement that cannot derive or publish its command stops before
# it can consume the prior session's bypass line.
overseer_case record_derivation_failure idle
state_with "$BYPASS_LINE"
touch "$STUB_DIR/succeed.print-fail"
run TMUX_PANE="$PANE" -- --max-loops 2 -- --model fable
assert_eq "rc=$RC events=$(grep -c '^EVENT overseer-dead' <<<"$OUT" || true) launched=$(succeed_calls --dead-pane)" \
  "rc=2 events=0 launched=0" "a derivation failure cannot reach the dead-pane launcher" "$ERR"
assert_eq "$(recorded launch_line)" "$BYPASS_LINE" \
  "the stopped invocation cannot consume the older bypass line" "$ERR"

overseer_case record_write_failure idle
state_with "$BYPASS_LINE"
printf '2\n' > "$STUB_DIR/workflow-state.rc"
run TMUX_PANE="$PANE" -- --max-loops 2 -- --model fable
assert_eq "rc=$RC events=$(grep -c '^EVENT overseer-dead' <<<"$OUT" || true) launched=$(succeed_calls --dead-pane)" \
  "rc=2 events=0 launched=0" "a state-write failure cannot reach the dead-pane launcher" "$ERR"
assert_eq "$(recorded launch_line)" "$BYPASS_LINE" \
  "the failed write leaves the older bypass line unreachable" "$ERR"

# The window the record names is read on its own, after the key: a pane whose
# window tmux will not report, and one it reports as something that is not a
# window id, both leave the record unwritten rather than naming a window a
# successor cannot be opened in.
overseer_case record_window_unreadable idle
state_with "$BYPASS_LINE"
touch "$STUB_DIR/window-id-fail-$PANE"
run TMUX_PANE="$PANE" -- --max-loops 1
assert_eq "rc=$RC line=$(grep -c "^oversee-watch: overseer-unrecorded pane=$PANE step=window\$" "$ERR")" \
  "rc=2 line=1" "a window tmux will not report stops the record, naming the step" "$ERR"
assert_eq "$(grep -c "^E_WINDOW pane=$PANE\$" "$ERR")" "1" \
  "and tmux's own words are replayed under that line, not swallowed" "$ERR"
assert_eq "$(recorded launch_line)" "$BYPASS_LINE" \
  "and the older line is left where it was" "$ERR"

overseer_case record_window_malformed idle
state_with "$BYPASS_LINE"
printf 'window7\n' > "$STUB_DIR/window-id-$PANE.txt"
run TMUX_PANE="$PANE" -- --max-loops 1
assert_eq "rc=$RC line=$(grep -c "^oversee-watch: overseer-unrecorded pane=$PANE step=window\$" "$ERR")" \
  "rc=2 line=1" "a window id that is not @N stops the record on the same step" "$ERR"

# The key is read through the orch library, which discards tmux's stderr, so a
# refusal there cannot replay it. It names the read that failed instead: a
# `step=identity` line with nothing under it leaves the operator no reason at
# all, which is the whole difference between these two steps.
overseer_case record_identity_unreadable idle
state_with "$BYPASS_LINE"
printf 'E_PID pane=%s\n' "$PANE" > "$STUB_DIR/pane-key-fail-$PANE"
run TMUX_PANE="$PANE" -- --max-loops 1
assert_eq "rc=$RC line=$(grep -c "^oversee-watch: overseer-unrecorded pane=$PANE step=identity\$" "$ERR")" \
  "rc=2 line=1" "a key tmux will not answer stops the record, naming the step" "$ERR"
assert_eq "$(grep -c "^tmux reported no server pid for pane $PANE\$" "$ERR")" "1" \
  "and the refusal carries a reason of its own, since the library keeps tmux's" "$ERR"
assert_eq "$(recorded launch_line)" "$BYPASS_LINE" \
  "and the older line is left where it was" "$ERR"

overseer_case record_identity_malformed idle
state_with "$BYPASS_LINE"
printf 'not-a-pid\n' > "$STUB_DIR/pane-key-$PANE.txt"
run TMUX_PANE="$PANE" -- --max-loops 1
assert_eq "rc=$RC line=$(grep -c "^oversee-watch: overseer-unrecorded pane=$PANE step=identity\$" "$ERR")" \
  "rc=2 line=1" "a key that is not <pid> <pane> stops the record on the same step" "$ERR"
assert_eq "$(grep -c "^the pane key read back as: not-a-pid $PANE\$" "$ERR")" "1" \
  "and the refusal replays what it read" "$ERR"

# A death count from another tmux server does not apply to a pane number that
# the new server reused.
overseer_case death_new_server exited
state_with "$LINE"
run TMUX_PANE="$PANE" -- --max-loops 1
printf '8000 %s\n' "$PANE" > "$STUB_DIR/pane-key-$PANE.txt"
printf '%s\n' "$LINE" > "$STUB_DIR/succeed.line"
run TMUX_PANE="$PANE" -- --max-loops 1
assert_eq "rc=$RC launched=$(succeed_calls --dead-pane)" "rc=0 launched=0" \
  "a new server starts a new death count for its reused pane number" "$ERR"

# A watch started without --handoff records a line whose brief still points at
# a file: the default path is the one ../workflows/oversee.md § 5. Stop names.
overseer_case record_default_handoff idle
printf '{"triaged":[]}\n' > "$STUB_DIR/oversee-state.json"
run TMUX_PANE="$PANE" -- --max-loops 1
assert_eq "$(grep -- '^--print-launch-line' "$STUB_DIR/succeed.args")" \
  "--print-launch-line --handoff $HANDOFF_DEFAULT" \
  "a watch given no handoff path passes the workflow's own" "$ERR"

# --- what leaves the overseer unwatched -----------------------------------
# Off tmux, or started from something that is not the overseer's pane, nothing
# can report an overseer that dies. That is said, not left silent.
overseer_case unwatched_no_pane idle
state_with "$LINE"
run -- --max-loops 2
assert_eq "rc=$RC" "rc=0" "a watch with no pane still runs the fleet" "$ERR"
assert_eq "$(grep -c 'oversee-watch: overseer-unwatched var=TMUX_PANE' "$ERR")" "1" \
  "and says once that an overseer that dies is reported by nothing" "$ERR"

# A pane the watch cannot read settles nothing: no count, no event, and the
# reason named.
overseer_case unreadable_pane exited
state_with "$LINE"
touch "$STUB_DIR/window-id-fail-$PANE"
run TMUX_PANE="$PANE" -- --max-loops 2
assert_eq "rc=$RC launched=$(succeed_calls --dead-pane)" "rc=0 launched=0" \
  "an unreadable overseer pane launches nothing" "$ERR"
assert_eq "$(grep -c "oversee-watch: overseer-unreadable pane=$PANE field=window_id" "$ERR")" "1" \
  "and the reason is named once" "$ERR"

# --- the settings this check reads ----------------------------------------
overseer_case dead_passes_one exited
state_with "$LINE"
run ORCH_OVERSEER_DEAD_PASSES=1 TMUX_PANE="$PANE" -- --max-loops 1
assert_eq "rc=$RC first=$(head -n 1 <<<"$OUT")" \
  "rc=3 first=EVENT overseer-dead $PANE window=$WINDOW passes=1 succession=on" \
  "a one-pass setting fires on the first reading and says so" "$ERR"

# A repeat count of 0, or one no arithmetic can read, would make the pass
# comparison read 0 and report a standing mark on every pass — the flood the
# count exists to bound.
for row in \
  "ORCH_OVERSEER_DEAD_PASSES=0|dead-passes-invalid ORCH_OVERSEER_DEAD_PASSES=0|a zero pass count refuses" \
  "ORCH_OVERSEER_DEAD_PASSES=two|dead-passes-invalid ORCH_OVERSEER_DEAD_PASSES=two|a non-numeric pass count refuses" \
  "ORCH_OVERSEER_MARK_REPEAT=0|mark-repeat-invalid ORCH_OVERSEER_MARK_REPEAT=0|a zero repeat count refuses" \
  "ORCH_OVERSEER_MARK_REPEAT=five|mark-repeat-invalid ORCH_OVERSEER_MARK_REPEAT=five|a non-numeric repeat count refuses"; do
  IFS='|' read -r row_env row_want row_label <<<"$row"
  overseer_case "setting_${row_env//[^A-Za-z0-9]/_}" idle
  run "$row_env" TMUX_PANE="$PANE" -- --max-loops 1
  assert_eq "rc=$RC line=$(grep -c "^oversee-watch: $row_want\$" "$ERR")" "rc=2 line=1" "$row_label" "$ERR"
done

overseer_case handoff_alphabet idle
run TMUX_PANE="$PANE" -- --max-loops 1 --handoff 'tmp/hand off.md'
assert_eq "rc=$RC line=$(grep -c '^oversee-watch: handoff-invalid path=tmp/hand off.md$' "$ERR")" "rc=2 line=1" \
  "a handoff path oversee-succeed would refuse is refused here, at the start" "$ERR"

# --- repeat mode ----------------------------------------------------------
# The watch for a session: it passes its own flags and handoff down to every
# pass, and ends when one of them hands the window to a successor. Two watches
# on one fleet would each replay what the other drained.
overseer_case repeat_stops idle
state_with "$LINE"
printf '%s\n' "$LINE" > "$STUB_DIR/succeed.line"
touch "$STUB_DIR/succeed.then-dead"
jq -n '{issue_id: "oversee", triaged: [], lanes: []}' > "$STUB_DIR/state.json"
run TMUX_PANE="$PANE" -- --max-loops 1 --repeat 0 --state "$STUB_DIR/state.json" -- --verbose
assert_eq "$RC" "0" "repeat mode ends cleanly once a successor holds the window" "$ERR"
assert_eq "$(grep -c '^EVENT overseer-dead' <<<"$OUT")" "1" "after reporting the death once" "$ERR"
assert_eq "$(succeed_calls --dead-pane)" "1" "having launched one successor" "$ERR"
assert_eq "$(grep -c "oversee-watch: overseer-succeeded pane=$PANE" "$ERR")" "1" \
  "and saying why it stopped" "$ERR"
assert_eq "$(grep -- '^--print-launch-line' "$STUB_DIR/succeed.args" | head -n 1)" \
  "--print-launch-line --handoff $HANDOFF_DEFAULT -- --verbose" \
  "the overseer's own flags reach each pass through the repeat loop" "$ERR"

overseer_case repeat_off_stops idle
state_with "$LINE"
touch "$STUB_DIR/succeed.then-dead"
jq -n '{issue_id: "oversee", triaged: [], lanes: []}' > "$STUB_DIR/state.json"
run ORCH_OVERSEER_SUCCESSION=off TMUX_PANE="$PANE" -- --max-loops 1 --repeat 0 --state "$STUB_DIR/state.json"
assert_eq "rc=$RC events=$(grep -c '^EVENT overseer-dead' <<<"$OUT" || true) launched=$(succeed_calls --dead-pane)" \
  "rc=0 events=1 launched=0" "repeat mode stops after the notice for a manual replacement" "$ERR"

overseer_case repeat_exhausted_stops idle
state_with "$LINE"
printf '4\n' > "$STUB_DIR/succeed.rc"
touch "$STUB_DIR/succeed.then-dead"
jq -n '{issue_id: "oversee", triaged: [], lanes: []}' > "$STUB_DIR/state.json"
run TMUX_PANE="$PANE" -- --max-loops 2 --repeat 0 --state "$STUB_DIR/state.json"
assert_eq "rc=$RC events=$(grep -c '^EVENT overseer-dead' <<<"$OUT" || true) launched=$(succeed_calls --dead-pane) mail=$(mailbox_lines)" \
  "rc=0 events=1 launched=2 mail=3" "repeat mode stops after the bounded recovery attempts" "$ERR"

# --- controls -------------------------------------------------------------
# The mutant tree keeps orch's place in a skills tree so its libraries resolve
# the github skill beside it, the same shape oversee_watch_usage_limit.sh uses.
MUTANT_DIR="$TMP_ROOT/mutant"
mkdir -p "$MUTANT_DIR/orch"
cp -R "$REPO_ROOT/skills/orch/scripts" "$MUTANT_DIR/orch/scripts"
ln -s "$REPO_ROOT/skills/github" "$MUTANT_DIR/github"
mutate() { # SED_EXPR LABEL
  sed "$1" "$REPO_ROOT/skills/orch/scripts/oversee-watch" > "$MUTANT_DIR/orch/scripts/oversee-watch"
  assert_eq "$(cmp -s "$MUTANT_DIR/orch/scripts/oversee-watch" "$REPO_ROOT/skills/orch/scripts/oversee-watch" && echo same || echo differs)" \
    "differs" "control: the mutant really $2"
}

# Control 1: the debounce removed. One exited reading then fires, which is the
# poll that caught a live session between its harness and its shell relaunching
# an overseer that never died.
mutate 's/^    if (( count < DEAD_PASSES )); then$/    if false; then/' "removes the consecutive-pass debounce"
overseer_case debounce_mutant exited
state_with "$LINE"
WATCH_BIN="$MUTANT_DIR/orch/scripts/oversee-watch" run TMUX_PANE="$PANE" -- --max-loops 1
assert_eq "rc=$RC launched=$(succeed_calls --dead-pane)" "rc=3 launched=1" \
  "control: without the debounce a single reading relaunches the overseer" "$ERR"

# Control 2: the succession setting ignored. The row above that reports and
# launches nothing then launches, which is an operator's `off` overridden.
mutate 's/^  \[\[ "\${ORCH_OVERSEER_SUCCESSION:-on}" != off \]\] || succession=off$/  :/' \
  "ignores ORCH_OVERSEER_SUCCESSION"
overseer_case succession_mutant exited
state_with "$LINE"
WATCH_BIN="$MUTANT_DIR/orch/scripts/oversee-watch" run ORCH_OVERSEER_SUCCESSION=off TMUX_PANE="$PANE" -- --max-loops 2
assert_eq "rc=$RC launched=$(succeed_calls --dead-pane)" "rc=3 launched=1" \
  "control: without the setting read, an operator's off still launches a successor" "$ERR"

# Control 3: a failed launch marked reported immediately has no bounded retry.
mutate 's/^    rows="$(lane_row_set "$row" "$rows" "$identity" "pending:$attempt")"$/    rows="$(lane_row_set "$row" "$rows" "$identity" reported)"/' \
  "drops the pending recovery state"
overseer_case pending_mutant exited
state_with "$LINE"
printf '4\n' > "$STUB_DIR/succeed.rc"
WATCH_BIN="$MUTANT_DIR/orch/scripts/oversee-watch" run TMUX_PANE="$PANE" -- --max-loops 2
WATCH_BIN="$MUTANT_DIR/orch/scripts/oversee-watch" run TMUX_PANE="$PANE" -- --max-loops 1
assert_eq "$(succeed_calls --dead-pane)" "1" \
  "control: without pending state the next pass cannot retry" "$ERR"

# Control 4: without the pass-level gate, an event consumer advances its
# baseline on the first exited reading.
mutate 's/^  if check_overseer; then$/  check_overseer || :; if true; then/' \
  "runs event consumers after an exited reading"
overseer_case consumer_mutant exited
state_with "$LINE"
printf 'Consumed without a reader.\n' > "$TMP_ROOT/mutant-event.txt"
(cd "$CASE_REPO_ROOT" && "$REPO_ROOT/skills/orch/scripts/lane-mail" send \
  --item overseer --directive --file "$TMP_ROOT/mutant-event.txt" >/dev/null)
WATCH_BIN="$MUTANT_DIR/orch/scripts/oversee-watch" run TMUX_PANE="$PANE" -- --max-loops 1
assert_contains "$OUT" "EVENT owner-note" \
  "control: without the gate the first exited reading consumes the event" "$ERR"

# Control 5: without the watch invocation's ownership write, the same-pane
# manual replacement retains the former session's bypass command.
mutate 's/overseer_command_record$/ : # owner write removed/' \
  "drops the current watch command write"
overseer_case identity_mutant idle
jq -n --arg pane "$PANE" --arg window "$WINDOW" \
  '{triaged: [], overseer: {server: "7000", pane: $pane, window: $window, launch_line: "claude -n overseer --model old --dangerously-skip-permissions"}}' \
  > "$STUB_DIR/oversee-state.json"
printf '%s\n' "$LINE" > "$STUB_DIR/succeed.line"
WATCH_BIN="$MUTANT_DIR/orch/scripts/oversee-watch" run TMUX_PANE="$PANE" -- --max-loops 1
assert_eq "line=$(recorded launch_line) derived=$(succeed_calls --print-launch-line)" \
  "line=claude -n overseer --model old --dangerously-skip-permissions derived=0" \
  "control: without the ownership write a same-pane replacement keeps the old command" "$ERR"

# Control 6: the publisher dating the record itself. `append-file` keeps an
# `at` the clock has already passed, so the entry carries whatever the
# publisher typed and the fleet log a successor reads in order is misdated.
mutate 's/{kind: "close", item: "overseer"/{at: "1999-01-01T00:00:00Z", kind: "close", item: "overseer"/' \
  "dates the published record itself"
overseer_case publish_at_mutant exited
state_with "$LINE"
WATCH_BIN="$MUTANT_DIR/orch/scripts/oversee-watch" run TMUX_PANE="$PANE" -- --max-loops 2
assert_eq "$(fleet_log_at)" "1999-01-01T00:00:00Z" \
  "control: a publisher-written at reaches the log in place of the append's stamp" "$ERR"

# Control 6: the repeat count ignored, so a standing mark is reported on every
# pass. The overseer's block then carries one overseer-mark line per pass and
# every other event it is meant to read sits under a wall of them.
mutate 's/^    (( passes < MARK_REPEAT )) || passes=0$/    passes=0/' \
  "ignores ORCH_OVERSEER_MARK_REPEAT"
overseer_case repeat_mutant idle
state_with "$LINE"
mark_stands
WATCH_BIN="$MUTANT_DIR/orch/scripts/oversee-watch" run TMUX_PANE="$PANE" ORCH_OVERSEER_MARK_REPEAT=3 -- --max-loops 1
WATCH_BIN="$MUTANT_DIR/orch/scripts/oversee-watch" run TMUX_PANE="$PANE" ORCH_OVERSEER_MARK_REPEAT=3 -- --max-loops 1
assert_eq "marks=$(marks_seen)" "marks=1" \
  "control: without the repeat count the standing mark is reported on the very next pass" "$ERR"

# --- the overseer's account spent, which is a death by the other road -------
# A walled overseer is not dead: its harness is running and its lanes keep
# working, so nothing but this check notices that it takes no turn, answers no
# lane and reads no mail. The recovery is the dead arm's, on the same two
# channels and with the same row machinery, and it differs where it has to:
# the successor's account is picked afresh, never taken from the recorded line
# which names the account that just walled.
#
# TWO readings gate it, and the second is the load-bearing one. This pane is
# the one pane in a fleet carrying the limit banners the watch relays about
# OTHER lanes, so the screen cannot tell those from the overseer's own account
# running out — and acting on the screen alone closes a window whose harness
# is alive. `wall_confirmed` is the account judgement that settles it.
wall_confirmed() { printf '%s\n' "$WALL_MARK_LINE" > "$STUB_DIR/succeed.check"; }

overseer_case walled_relaunch walled
state_with "$LINE"
wall_confirmed
run TMUX_PANE="$PANE" -- --max-loops 2 -- --verbose
assert_eq "$RC" "3" "a relaunched walled overseer ends the watch with the same status a death does" "$ERR"
assert_eq "$(head -n 1 <<<"$OUT")" "EVENT overseer-walled $PANE window=$WINDOW passes=2 succession=on" \
  "the event names the pane, its window, the passes it took and the setting" "$ERR"
assert_contains "$OUT" "$(printf "%b" "$WALL_BANNER")" \
  "the banner's own window follows the line, as a lane's usage-limit payload does" "$ERR"
assert_eq "$(succeed_calls --walled-pane)" "1" "the re-picking launch path is called once" "$ERR"
assert_eq "$(cat "$STUB_DIR/succeed.launched")" \
  "--walled-pane $PANE --handoff $HANDOFF_DEFAULT -- --verbose" \
  "naming the walled pane, the handoff path and the overseer's own flags" "$ERR"
assert_eq "$(succeed_calls --dead-pane)" "0" \
  "the recorded line is never sent: it names the account that walled" "$ERR"
assert_eq "$(succeed_calls --check-marks)" "2" \
  "each pass takes its own account judgement, and it is what confirms the wall" "$ERR"
assert_contains "$(cat "$ERR")" "env CLAUDE_CONFIG_DIR='/home/me/.eclaude' claude -n overseer" \
  "the launch line the recovery used is in the pass output" "$ERR"
assert_eq "$(fleet_log_kind)" "close" "the fleet log records the wall as a close" "$ERR"
assert_contains "$(fleet_log_text)" "overseer-walled: the overseer session in tmux window $WINDOW (pane $PANE) read walled on 2 consecutive watch passes" \
  "the fleet log entry names the window, the pane and the passes" "$ERR"
assert_contains "$(fleet_log_text)" "on an account the lane pick judged, never on the spent one." \
  "and says where the successor's account came from" "$ERR"
assert_eq "$(mailbox text)" "$(fleet_log_text)" \
  "both channels carry one text, so they cannot describe the wall differently" "$ERR"

# The account's own measurement is what separates the overseer's wall from a
# wall it reported about a lane. This pane reads walled and its account
# measures room, which is every relayed banner: nothing is launched, no window
# is closed and the pass carries on as it does for any working overseer.
overseer_case walled_quoted walled
state_with "$LINE"
run TMUX_PANE="$PANE" -- --max-loops 2
assert_eq "rc=$RC events=$(grep -c '^EVENT overseer-walled' <<<"$OUT" || true) launched=$(succeed_calls --walled-pane) mail=$(mailbox_lines)" \
  "rc=0 events=0 launched=0 mail=0" \
  "a wall the account refutes launches nothing and publishes nothing" "$ERR"
assert_contains "$(cat "$ERR")" "oversee-watch: overseer-wall-unconfirmed pane=$PANE answer=below-mark" \
  "and the watch says which judgement refuted it" "$ERR"

# A judgement that could not be made refutes nothing and confirms nothing, so
# the destructive half waits for a pass that can measure.
overseer_case walled_unjudged walled
state_with "$LINE"
printf '2\n' > "$STUB_DIR/succeed.check-rc"
run TMUX_PANE="$PANE" -- --max-loops 2
assert_eq "rc=$RC launched=$(succeed_calls --walled-pane) mail=$(mailbox_lines)" \
  "rc=0 launched=0 mail=0" \
  "a wall nothing could judge closes no window" "$ERR"
assert_contains "$(cat "$ERR")" "oversee-watch: overseer-wall-unjudged pane=$PANE" \
  "and says the judgement itself is what is missing" "$ERR"

# One reading of the marks per pass. A wall the account refutes falls through
# to the live arm, which reports the crossing off that same reading rather
# than measuring every account of the fleet a second time.
overseer_case walled_one_judgement walled
state_with "$LINE"
printf '%s\n' "oversee-succeed: mark-reached kind=context value=612000 mark=500000 succession=on headroom=80" \
  > "$STUB_DIR/succeed.check"
run TMUX_PANE="$PANE" -- --max-loops 1
assert_eq "judged=$(succeed_calls --check-marks) marks=$(grep -c '^EVENT overseer-mark' <<<"$OUT" || true)" \
  "judged=1 marks=1" \
  "the refuted wall reports the standing context mark off the one reading it took" "$ERR"

# The usage endpoint answered every account 429 on the control host because
# each watch, each judgement and each pick refreshed the same accounts
# independently. A pass names its OWN interval to the lane reader inside the
# judgement, so a figure this watch has not come round for yet is served
# rather than posted for again. One pass, so the interval is never slept.
overseer_case mark_interval walled
state_with "$LINE"
printf '%s\n' "oversee-succeed: mark-reached kind=context value=612000 mark=500000 succession=on headroom=80" \
  > "$STUB_DIR/succeed.check"
run TMUX_PANE="$PANE" -- --max-loops 1 --interval 45
assert_eq "judged=$(succeed_calls --check-marks) age=$(paste -sd, "$STUB_DIR/succeed.max-age")" \
  "judged=1 age=45" \
  "the judgement is told this watch's pass interval as the age a usage figure may be served at" "$ERR"

# One reading is a poll, exactly as it is for a death.
overseer_case walled_one_pass walled
state_with "$LINE"
wall_confirmed
run TMUX_PANE="$PANE" -- --max-loops 1
assert_eq "rc=$RC first=$(head -n 1 <<<"$OUT") launched=$(succeed_calls --walled-pane)" \
  "rc=0 first=EVENT heartbeat loops=1 interval=0s since=none launched=0" \
  "one walled reading is a poll, not news" "$ERR"

# A wall that lifts leaves no row and publishes nothing: the account came back
# before the threshold, and the next wall starts its count over.
overseer_case walled_then_alive walled
state_with "$LINE"
wall_confirmed
run TMUX_PANE="$PANE" -- --max-loops 1
printf '%b\n' '⏺ Back at it.' '\xe2\x9d\xaf\xc2\xa0' > "$STUB_DIR/pane-$PANE.txt"
run TMUX_PANE="$PANE" -- --max-loops 1
printf '%b\n' '⏺ Watching the fleet.' "$WALL_BANNER" '\xe2\x9d\xaf\xc2\xa0' > "$STUB_DIR/pane-$PANE.txt"
run TMUX_PANE="$PANE" -- --max-loops 1
assert_eq "rc=$RC launched=$(succeed_calls --walled-pane) mail=$(mailbox_lines)" \
  "rc=0 launched=0 mail=0" \
  "a reading that cleared leaves no row and publishes nothing" "$ERR"

# The wall comes from the shared judge and never from limit text the overseer
# printed in its own output: a turn in flight behind that text is a working
# overseer, and a working overseer is never read as walled at all.
overseer_case walled_limit_text limit_text
state_with "$LINE"
run TMUX_PANE="$PANE" -- --max-loops 2
assert_eq "rc=$RC first=$(head -n 1 <<<"$OUT") launched=$(succeed_calls --walled-pane) mail=$(mailbox_lines)" \
  "rc=0 first=EVENT heartbeat loops=2 interval=0s since=none launched=0 mail=0" \
  "an overseer printing limit text while working is left alone" "$ERR"

# No account qualifies. oversee-succeed answers exit 3, which a retry cannot
# improve on, so the pass publishes ONE notice naming the spent account and
# when its binding bucket frees up, and stops the repeat the way notice-only
# recovery does. Both figures come from the account judgement that confirmed
# the wall, which is the reading the fleet waits on.
overseer_case walled_no_room walled
state_with "$LINE"
wall_confirmed
printf '3\n' > "$STUB_DIR/succeed.rc"
run TMUX_PANE="$PANE" -- --max-loops 2
assert_eq "rc=$RC launched=$(succeed_calls --walled-pane)" "rc=4 launched=1" \
  "the child tells its live owner to stop, having tried the recovery once" "$ERR"
assert_eq "$(mailbox text)" \
  "overseer-recovery-blocked: no account qualifies for a successor to the overseer in tmux window $WINDOW (pane $PANE). Its own account is $WALL_ACCOUNT and its binding bucket frees up at $WALL_RESETS. The repeat stops; start a fresh overseer by hand once an account has room." \
  "the notice names the spent account and when it frees up" "$ERR"
assert_eq "$(fleet_log_text)" "$(mailbox text)" \
  "and reaches the fleet log with that same text" "$ERR"
assert_eq "mail=$(mailbox_lines) log=$(jq '[.fleet_log[] | select(.item == "overseer")] | length' "$STUB_DIR/oversee-state.json")" \
  "mail=2 log=2" "the wall and the blocked recovery are the whole of what went out" "$ERR"
assert_contains "$(cat "$ERR")" "oversee-watch: overseer-recovery-blocked pane=$PANE account=$WALL_ACCOUNT resets=$WALL_RESETS" \
  "with the watch's own keyed line naming both" "$ERR"
run TMUX_PANE="$PANE" -- --max-loops 1
assert_eq "launched=$(succeed_calls --walled-pane) mail=$(mailbox_lines)" "launched=1 mail=2" \
  "a later pass neither retries the same accounts nor repeats the notice" "$ERR"

# An account judgement that named neither figure. The notice says so rather
# than carrying a figure from somewhere else: the words are `unknown` and
# `none`, which is what the reader acts on.
overseer_case walled_no_room_unnamed walled
state_with "$LINE"
printf '%s\n' "oversee-succeed: mark-reached kind=headroom value=0 mark=10 succession=on" \
  > "$STUB_DIR/succeed.check"
printf '3\n' > "$STUB_DIR/succeed.rc"
run TMUX_PANE="$PANE" -- --max-loops 2
assert_contains "$(mailbox text)" "Its own account is unknown and its binding bucket frees up at none." \
  "a judgement naming neither figure gives the notice no figure to print" "$ERR"

# A launcher that refuses leaves one bounded retry, written to the WALLED row:
# the death's row is untouched throughout, so the two cases never spend each
# other's attempts.
overseer_case walled_relaunch_refused walled
state_with "$LINE"
wall_confirmed
printf '4\n' > "$STUB_DIR/succeed.rc"
run TMUX_PANE="$PANE" -- --max-loops 2
assert_eq "rc=$RC walled=$(succeed_calls --walled-pane) events=$(grep -c '^EVENT overseer-walled' <<<"$OUT" || true)" \
  "rc=0 walled=1 events=1" \
  "a refused walled relaunch neither ends the watch nor is retried in the same pass" "$ERR"
assert_contains "$(cat "$ERR")" "oversee-watch: overseer-relaunch-failed pane=$PANE attempt=1 retry=pending step=launcher" \
  "the first refusal records a pending retry" "$ERR"
run TMUX_PANE="$PANE" -- --max-loops 1
assert_eq "walled=$(succeed_calls --walled-pane) events=$(grep -c '^EVENT overseer-walled' <<<"$OUT" || true) mail=$(mailbox_lines)" \
  "walled=2 events=0 mail=3" \
  "the next pass retries off the walled row without repeating the event" "$ERR"
assert_contains "$(cat "$ERR")" "oversee-watch: overseer-relaunch-failed pane=$PANE attempt=2 retry=exhausted step=launcher" \
  "the second refusal records that the retry is spent" "$ERR"
run TMUX_PANE="$PANE" -- --max-loops 1
assert_eq "rc=$RC walled=$(succeed_calls --walled-pane) mail=$(mailbox_lines)" "rc=4 walled=2 mail=3" \
  "later passes read the row reported, stop the repeat and call nothing" "$ERR"
assert_eq "$(succeed_calls --dead-pane)" "0" \
  "and the death's own launch path was never reached" "$ERR"

# Succession off is read here as it is on the dead path: the notice goes out
# and no successor opens.
overseer_case walled_succession_off walled
state_with "$LINE"
printf '%s\n' "oversee-succeed: mark-reached kind=headroom value=0 mark=10 succession=off account=$WALL_ACCOUNT resets=$WALL_RESETS" \
  > "$STUB_DIR/succeed.check"
run ORCH_OVERSEER_SUCCESSION=off TMUX_PANE="$PANE" -- --max-loops 2
assert_eq "rc=$RC first=$(head -n 1 <<<"$OUT") launched=$(succeed_calls --walled-pane)" \
  "rc=4 first=EVENT overseer-walled $PANE window=$WINDOW passes=2 succession=off launched=0" \
  "with succession off the wall is reported and nothing is launched" "$ERR"

# A fleet state with no recorded line stops a DEATH, which has nothing else to
# send. A wall picks its own account and builds its own line, so it launches.
overseer_case walled_no_line walled
state_with ""
wall_confirmed
run TMUX_PANE="$PANE" -- --max-loops 2
assert_eq "rc=$RC launched=$(succeed_calls --walled-pane)" "rc=3 launched=1" \
  "a wall with no recorded line still recovers: it needs none" "$ERR"

# A reading of the other case clears this one's row, so a wall that the pane
# recovered from by dying, and then met again, starts its count over. The
# three passes below are one pane walled, then exited, then walled again.
walled_case_flip() { # LABEL BIN
  overseer_case "walled_flip_$1" walled
  state_with "$LINE"
  wall_confirmed
  WATCH_BIN="$2" run TMUX_PANE="$PANE" -- --max-loops 1
  printf 'bash\n' > "$STUB_DIR/cmd-$PANE.txt"
  printf 'dev@host ~/kendex $\n' > "$STUB_DIR/pane-$PANE.txt"
  WATCH_BIN="$2" run TMUX_PANE="$PANE" -- --max-loops 1
  printf 'claude\n' > "$STUB_DIR/cmd-$PANE.txt"
  printf '%b\n' '⏺ Watching the fleet.' "$WALL_BANNER" '\xe2\x9d\xaf\xc2\xa0' > "$STUB_DIR/pane-$PANE.txt"
  WATCH_BIN="$2" run TMUX_PANE="$PANE" -- --max-loops 1
}
walled_case_flip honest ""
assert_eq "walled=$(succeed_calls --walled-pane) dead=$(succeed_calls --dead-pane)" \
  "walled=0 dead=0" \
  "a wall, a death and a wall again: each case counts its own readings alone" "$ERR"

# --- controls for the walled arm -------------------------------------------
# Control 7: the walled reading dropped from the dispatch, which is what every
# pass did before this arm existed. The row is cleared, nothing is published
# and nothing is launched, on a pane walled for as many passes as one likes.
mutate 's/^    walled) ov_case=walled ;;$/    walled) : ;;/' \
  "drops the walled reading from the dispatch"
overseer_case walled_dispatch_mutant walled
state_with "$LINE"
wall_confirmed
WATCH_BIN="$MUTANT_DIR/orch/scripts/oversee-watch" run TMUX_PANE="$PANE" -- --max-loops 2
assert_eq "rc=$RC events=$(grep -c '^EVENT overseer-walled' <<<"$OUT" || true) launched=$(succeed_calls --walled-pane) mail=$(mailbox_lines)" \
  "rc=0 events=0 launched=0 mail=0" \
  "control: without the walled arm the pass clears the reading and emits nothing" "$ERR"

# Control 8: the two cases sharing one row. The second wall then reads as the
# second pass of the first one and fires on a single reading, which is the
# poll a threshold exists to rule out.
mutate 's/^  rows="$(lane_row_clear "$other" "$rows" "$identity")"$/  :/' \
  "lets a case keep the other case's row"
walled_case_flip mutant "$MUTANT_DIR/orch/scripts/oversee-watch"
assert_eq "$(succeed_calls --walled-pane)" "1" \
  "control: with the stale row kept, one fresh walled reading relaunches the overseer" "$ERR"

# Control 9: exit 3 handled as a launch that broke. The blocked notice then
# never goes out, so the fleet is never told which account has to free up.
mutate 's/^    3) overseer_recovery_blocked "$row" "$rows" "$identity" "$pane" "$window" ;;$/    3) ;;/' \
  "drops the blocked-recovery notice"
overseer_case walled_blocked_mutant walled
state_with "$LINE"
wall_confirmed
printf '3\n' > "$STUB_DIR/succeed.rc"
WATCH_BIN="$MUTANT_DIR/orch/scripts/oversee-watch" run TMUX_PANE="$PANE" -- --max-loops 2
assert_not_contains "$(mailbox text)" "overseer-recovery-blocked" \
  "control: without that arm a fleet with no room is told nothing" "$ERR"

# Control 10: the account judgement dropped, so the screen decides alone. The
# relayed banner of another lane then closes a window whose harness is alive.
mutate 's/^  \[\[ "$ov_case" != walled \]\] || overseer_wall_confirmed "$pane" || ov_case=""$/  :/' \
  "lets the screen confirm the wall by itself"
overseer_case walled_confirm_mutant walled
state_with "$LINE"
WATCH_BIN="$MUTANT_DIR/orch/scripts/oversee-watch" run TMUX_PANE="$PANE" -- --max-loops 2
assert_eq "rc=$RC launched=$(succeed_calls --walled-pane)" "rc=3 launched=1" \
  "control: without the account judgement a relayed lane banner relaunches a working overseer" "$ERR"

# Control 11: the row name hardcoded inside overseer_relaunch_failed, which is
# what it read before the walled arm existed. A walled recovery's pending
# state then lands on the death's row, the next walled pass clears it as the
# other case's, and the launcher is called on every pass with no bound.
mutate 's/^  local row="$1" rows="$2" identity="$3" pane="$4" window="$5" attempt="$6" step="$7"$/  local row=overseer-dead rows="$2" identity="$3" pane="$4" window="$5" attempt="$6" step="$7"/' \
  "hardcodes the death's row in the retry bookkeeping"
overseer_case walled_retry_row_mutant walled
state_with "$LINE"
wall_confirmed
printf '4\n' > "$STUB_DIR/succeed.rc"
for _ in 1 2 3; do
  WATCH_BIN="$MUTANT_DIR/orch/scripts/oversee-watch" run TMUX_PANE="$PANE" -- --max-loops 2
done
assert_eq "$(succeed_calls --walled-pane)" "3" \
  "control: with the death's row hardcoded the walled retry never reaches its bound" "$ERR"

# --- one reading per PASS, not per process -------------------------------
# A single invocation runs up to --max-loops passes an --interval apart, so a
# judgement memoised for the process would answer every later pass with the
# first one's reading. The rows below are the two ways that goes wrong, each
# inside ONE process.
#
# check_switch_after_first LINE — the stub answers LINE from the second
# reading of the next process on, its counter cleared here.
check_switch_after_first() { # LINE
  printf '%s\n' "$1" > "$STUB_DIR/succeed.check-later"
  : > "$STUB_DIR/succeed.check-count"
}
# Readings taken since that counter was last cleared, which is one run's own
# count where succeed_calls carries every run the case has made.
checks_since_switch() { wc -c < "$STUB_DIR/succeed.check-count" | tr -d ' '; }

# A wall that lands after the first pass. Pass 1 measures room, so the wall is
# refuted and its row cleared; passes 2 and 3 measure the account at its
# trigger, which is the threshold met on a reading taken after the wall
# landed. A reading memoised for the process never sees it.
overseer_case walled_confirmed_later walled
state_with "$LINE"
check_switch_after_first "$WALL_MARK_LINE"
run TMUX_PANE="$PANE" -- --max-loops 3 -- --verbose
assert_eq "rc=$RC judged=$(succeed_calls --check-marks) launched=$(succeed_calls --walled-pane)" \
  "rc=3 judged=3 launched=1" \
  "a wall the later passes confirm is recovered, not refuted against the first reading" "$ERR"

# A standing mark that lifts inside one process. The crossing ends its own
# pass, so the lift has to happen while the mark is standing silently under
# the repeat count: pass 1 of the second run holds it, pass 2 reads below-mark
# and clears the row, and the crossing after that is news again rather than a
# pass of the count the first crossing left behind.
overseer_case mark_lifts_mid_process idle
state_with "$LINE"
mark_stands
run TMUX_PANE="$PANE" ORCH_OVERSEER_MARK_REPEAT=5 -- --max-loops 1
assert_eq "marks=$(marks_seen)" "marks=1" "the crossing is reported once" "$ERR"
check_switch_after_first "oversee-succeed: context-below-mark tokens=100000 mark=500000 headroom=80"
run TMUX_PANE="$PANE" ORCH_OVERSEER_MARK_REPEAT=5 -- --max-loops 2
assert_eq "rc=$RC judged=$(checks_since_switch) marks=$(marks_seen)" \
  "rc=0 judged=2 marks=0" \
  "each pass of that run takes its own reading, and the second says the mark lifted" "$ERR"
rm -f -- "${STUB_DIR:?}/succeed.check-later"
mark_stands
run TMUX_PANE="$PANE" ORCH_OVERSEER_MARK_REPEAT=5 -- --max-loops 1
assert_eq "marks=$(marks_seen)" "marks=1" \
  "so the same mark reached again is a fresh crossing, its row having been cleared" "$ERR"

# Control 12: the per-pass reset removed, which is the memo scoped to the
# process. Every pass after the first replays the first one's reading, so the
# wall the later passes would confirm is refuted against a reading taken
# before it landed and the fleet is left unattended.
mutate 's/^  overseer_marks_reset$/  :/' "drops the per-pass reset of the mark reading"
overseer_case walled_memo_mutant walled
state_with "$LINE"
check_switch_after_first "$WALL_MARK_LINE"
WATCH_BIN="$MUTANT_DIR/orch/scripts/oversee-watch" run TMUX_PANE="$PANE" -- --max-loops 3
assert_eq "rc=$RC judged=$(succeed_calls --check-marks) launched=$(succeed_calls --walled-pane)" \
  "rc=0 judged=1 launched=0" \
  "control: with the memo kept for the process the later wall is refuted against a stale reading" "$ERR"

# Control 13: the same memo, on the mark the watch already reported. The row
# the lifted mark would clear is instead counted up against a reading taken
# before it lifted, so the next crossing is swallowed by a count it did not
# earn.
overseer_case mark_memo_mutant idle
state_with "$LINE"
mark_stands
WATCH_BIN="$MUTANT_DIR/orch/scripts/oversee-watch" run TMUX_PANE="$PANE" ORCH_OVERSEER_MARK_REPEAT=5 -- --max-loops 1
check_switch_after_first "oversee-succeed: context-below-mark tokens=100000 mark=500000 headroom=80"
WATCH_BIN="$MUTANT_DIR/orch/scripts/oversee-watch" run TMUX_PANE="$PANE" ORCH_OVERSEER_MARK_REPEAT=5 -- --max-loops 2
rm -f -- "${STUB_DIR:?}/succeed.check-later"
mark_stands
WATCH_BIN="$MUTANT_DIR/orch/scripts/oversee-watch" run TMUX_PANE="$PANE" ORCH_OVERSEER_MARK_REPEAT=5 -- --max-loops 1
assert_eq "marks=$(marks_seen)" "marks=0" \
  "control: with the stale reading the lifted mark never clears its row and the next crossing is silent" "$ERR"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
