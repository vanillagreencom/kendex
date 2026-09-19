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

PANE=%9
WINDOW=@7
# The line a live overseer's `--print-launch-line` would hand back, carrying a
# permission flag and a quoted brief: it crosses the fleet state and a file on
# its way to the relaunch, and a row below reads it back byte for byte.
LINE="env CLAUDE_CONFIG_DIR='/home/me/.claude' claude -n overseer --model fable --verbose 'Read .agents/skills/orch/SKILL.md'"
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
    [[ ! -f "$STUB_DIR/succeed.print-fail" ]] \
      || { echo "oversee-succeed: no-status-line pane=$2" >&2; exit 1; }
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
  printf '9009\n' > "$STUB_DIR/panepid-$PANE.txt"
  case "$2" in
    exited) printf 'bash\n' > "$STUB_DIR/cmd-$PANE.txt"
            printf 'dev@host ~/kendex $\n' > "$STUB_DIR/pane-$PANE.txt" ;;
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
  jq -n --arg pane "$PANE" --arg window "$WINDOW" --arg line "$1" \
    '{triaged: [], overseer: {pane: $pane, window: $window, launch_line: $line}}' \
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
mailbox() { # FIELD
  local f="$CASE_REPO_ROOT/tmp/lane-mail/overseer/to-lane.jsonl"
  [[ -f "$f" ]] || { echo none; return 0; }
  tail -n 1 "$f" | jq -r ".$1 // \"none\""
}

RUN_SEQ=0
run() { # ENV=VAL... -- ARGS...
  ERR="$TMP_ROOT/run-$((++RUN_SEQ)).err"
  OUT="$(run_watch OVERSEE_WATCH_SUCCEED="$TMP_ROOT/bin/succeed-stub.sh" "$@" 2>"$ERR" </dev/null)" \
    && RC=0 || RC=$?
}

# --- the death itself, and the relaunch it ends in -------------------------
# Two passes in one run: the first reading is a poll that caught a live session
# between its harness and its shell, and only the second is news.
overseer_case dead_relaunch exited
state_with "$LINE"
run TMUX_PANE="$PANE" -- --max-loops 2
assert_eq "$RC" "3" "a relaunched overseer ends the watch with its own status" "$ERR"
assert_eq "$(head -n 1 <<<"$OUT")" "EVENT overseer-dead $PANE window=$WINDOW passes=2 succession=on" \
  "the event names the pane, its window, the passes it took and the setting" "$ERR"
assert_eq "$(succeed_calls --dead-pane)" "1" "the launch path is called once" "$ERR"
assert_eq "$(succeed_calls --print-launch-line)" "0" \
  "a state already holding a line for this pane re-derives none" "$ERR"
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

# --- one pass is not a death ----------------------------------------------
overseer_case dead_one_pass exited
state_with "$LINE"
run TMUX_PANE="$PANE" -- --max-loops 1
assert_eq "rc=$RC first=$(head -n 1 <<<"$OUT")" "rc=0 first=EVENT heartbeat loops=1 interval=0s since=none" \
  "one exited reading is a poll, not news" "$ERR"
assert_eq "$(succeed_calls --dead-pane)" "0" "and nothing is launched on it" "$ERR"

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
assert_eq "$RC" "0" "with succession off the watch keeps its own status" "$ERR"
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
touch "$STUB_DIR/succeed.print-fail"
run TMUX_PANE="$PANE" -- --max-loops 2
assert_eq "rc=$RC first=$(head -n 1 <<<"$OUT")" \
  "rc=0 first=EVENT overseer-dead $PANE window=$WINDOW passes=2 succession=on" \
  "a death with no recorded line is still the event" "$ERR"
assert_eq "$(succeed_calls --dead-pane)" "0" "and launches nothing" "$ERR"
assert_contains "$(fleet_log_text)" "The fleet state records no overseer launch line, so no successor is launched; start one by hand." \
  "the notice names the missing line as the reason" "$ERR"
assert_eq "$(grep -c 'oversee-watch: overseer-line-missing' "$ERR")" "1" \
  "and the note about it is said once for the run, not once per pass" "$ERR"

# A launcher that refuses leaves this watch running: the fleet still has no
# overseer, and a watch that exited would take the last reader with it.
overseer_case relaunch_refused exited
state_with "$LINE"
printf '4\n' > "$STUB_DIR/succeed.rc"
run TMUX_PANE="$PANE" -- --max-loops 2
assert_eq "rc=$RC launched=$(succeed_calls --dead-pane)" "rc=0 launched=1" \
  "a refused relaunch neither ends the watch nor is retried in the same pass" "$ERR"
assert_contains "$(cat "$ERR")" "oversee-watch: overseer-relaunch-failed pane=$PANE" \
  "the refusal is named" "$ERR"
assert_contains "$(cat "$ERR")" "oversee-succeed: pane-unreadable pane=$PANE" \
  "with the launcher's own keyed line under it" "$ERR"
# The death is reported once: the row is marked before the launch, so the pass
# after a refusal does not deliver the same notice again.
run TMUX_PANE="$PANE" -- --max-loops 1
assert_eq "events=$(grep -c '^EVENT overseer-dead' <<<"$OUT" || true) launched=$(succeed_calls --dead-pane)" \
  "events=0 launched=1" "a later pass over the same dead pane reports it no more" "$ERR"

# --- recording the line while the overseer is alive ------------------------
# The first watch of a fleet: no record, so the pane, its window and the line
# `oversee-succeed --print-launch-line` builds are written before anything
# needs them.
overseer_case record_first_start idle
printf '{"triaged":[]}\n' > "$STUB_DIR/oversee-state.json"
printf '%s\n' "$LINE" > "$STUB_DIR/succeed.line"
run TMUX_PANE="$PANE" -- --max-loops 1 --handoff tmp/handoffs/FLEET.md -- --verbose --model fable
assert_eq "pane=$(recorded pane) window=$(recorded window)" "pane=$PANE window=$WINDOW" \
  "the first start records the pane it was given and the window it sits in" "$ERR"
assert_eq "$(recorded launch_line)" "$LINE" "and the line a successor of it would run" "$ERR"
assert_eq "$(grep -- '^--print-launch-line' "$STUB_DIR/succeed.args")" \
  "--print-launch-line --handoff tmp/handoffs/FLEET.md -- --verbose --model fable" \
  "the handoff path and the overseer's own flags reach the builder" "$ERR"
assert_eq "$(succeed_calls --print-launch-line)" "1" \
  "and the line is built once, not once per pass" "$ERR"

# A record naming another pane is a different overseer — the successor of the
# one that died, whose own line oversee-succeed wrote at the moment it was
# chosen. The pane and window move to the session now running; the line does
# not, because re-deriving it would overwrite a chosen account with whatever
# this pane happens to read.
overseer_case record_successor idle
jq -n --arg window "$WINDOW" '{triaged: [], overseer: {pane: "%2", window: "@2", launch_line: "claude -n overseer --model fable"}}' \
  > "$STUB_DIR/oversee-state.json"
printf '%s\n' "$LINE" > "$STUB_DIR/succeed.line"
run TMUX_PANE="$PANE" -- --max-loops 1
assert_eq "pane=$(recorded pane) window=$(recorded window) line=$(recorded launch_line)" \
  "pane=$PANE window=$WINDOW line=claude -n overseer --model fable" \
  "a successor takes over the record and keeps the line it was chosen with" "$ERR"
assert_eq "$(succeed_calls --print-launch-line)" "0" \
  "so nothing re-derives the account that choice already named" "$ERR"

# The same record with no line — a start that could not read one — is the case
# where the line IS derived.
overseer_case record_other_pane_no_line idle
jq -n '{triaged: [], overseer: {pane: "%2", window: "@2", launch_line: null}}' \
  > "$STUB_DIR/oversee-state.json"
printf '%s\n' "$LINE" > "$STUB_DIR/succeed.line"
run TMUX_PANE="$PANE" -- --max-loops 1
assert_eq "pane=$(recorded pane) line=$(recorded launch_line)" "pane=$PANE line=$LINE" \
  "a record holding no line is filled from the pane now running" "$ERR"

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
overseer_case repeat_stops exited
printf '{"triaged":[]}\n' > "$STUB_DIR/oversee-state.json"
printf '%s\n' "$LINE" > "$STUB_DIR/succeed.line"
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
mutate 's/^  if (( count < DEAD_PASSES )); then$/  if false; then/' "removes the consecutive-pass debounce"
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

# Control 3: the row committed AFTER the launch instead of before. The relaunch
# ends the watch, so that write never runs and the next watch over the same pane
# delivers a death already handled.
mutate 's|^  lane_row_commit "$(lane_row_set overseer-dead "$rows" "$pane" reported)"$|  :|' \
  "drops the reported mark"
overseer_case reported_mutant exited
state_with "$LINE"
printf '4\n' > "$STUB_DIR/succeed.rc"
WATCH_BIN="$MUTANT_DIR/orch/scripts/oversee-watch" run TMUX_PANE="$PANE" -- --max-loops 2
assert_eq "$(grep -c '^EVENT overseer-dead' <<<"$OUT")" "1" \
  "control: the mutant still reports the refused death once" "$ERR"
WATCH_BIN="$MUTANT_DIR/orch/scripts/oversee-watch" run TMUX_PANE="$PANE" -- --max-loops 1
assert_eq "$(grep -c '^EVENT overseer-dead' <<<"$OUT")" "1" \
  "control: without the mark the next pass reports the same death again" "$ERR"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
