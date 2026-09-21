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

# oversee-succeed stub. `--print-launch-line` answers with succeed.line (or the
# default below) and `--dead-pane PANE --line-file PATH` records the relaunch
# and the file's contents. Both append their argv to succeed.args, so a case
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
  --dead-pane)
    printf '%s\n' "$*" >> "$STUB_DIR/succeed.launched"
    [[ "${3:-}" != --line-file ]] || cat -- "$4" >> "$STUB_DIR/succeed.line-file"
    rc=0; [[ ! -f "$STUB_DIR/succeed.rc" ]] || rc="$(cat "$STUB_DIR/succeed.rc")"
    [[ "$rc" -eq 0 ]] || echo "oversee-succeed: pane-unreadable pane=$2" >&2
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

for row in \
  "ORCH_OVERSEER_DEAD_PASSES=0|dead-passes-invalid ORCH_OVERSEER_DEAD_PASSES=0|a zero pass count refuses" \
  "ORCH_OVERSEER_DEAD_PASSES=two|dead-passes-invalid ORCH_OVERSEER_DEAD_PASSES=two|a non-numeric pass count refuses"; do
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
mutate 's/^    rows="$(lane_row_set overseer-dead "$rows" "$identity" "pending:$attempt")"$/    rows="$(lane_row_set overseer-dead "$rows" "$identity" reported)"/' \
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

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
