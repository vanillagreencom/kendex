#!/usr/bin/env bash
# Tests for oversee-watch's overseer wall contract.
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
# A node pane cannot name Codex before its first completed context record.
# Both consumers use the shared account judgement, without launch-only flags.
HARNESS_CONTROL="$(mutant_scripts no-harness/orch oversee-watch)" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/no-harness/github"
mutate_file "$HARNESS_CONTROL/oversee-watch" '"$SUCCEED" "${judge_args[@]}"' '"$SUCCEED" --check-marks'
while IFS='|' read -r name state mode event expected_rc expected_events expected_args; do
  overseer_case "$name" "$state"
  printf 'node\n' > "$STUB_DIR/cmd-$PANE.txt"
  if [[ "$state" == walled ]]; then
    printf '%s\n' 'Usage limit reached. Increase your limits to continue.' > "$STUB_DIR/pane-$PANE.txt"
  else
    cat "$CODEX_PANES/codex-composer-idle.txt" > "$STUB_DIR/pane-$PANE.txt"
  fi
  touch "$STUB_DIR/succeed.require-harness"
  # A live pane's mark sits above zero, where it is reported as the mark; at
  # zero it would be a wall and succeeded.
  if [[ "$state" == walled ]]; then wall_confirmed
  else printf '%s\n' "${WALL_MARK_LINE/value=0/value=5}" > "$STUB_DIR/succeed.check"; fi
  watch_path=.agents/skills/orch/scripts/oversee-watch
  [[ "$mode" != control ]] || watch_path="$HARNESS_CONTROL/oversee-watch"
  WATCH_BIN="$watch_path" run TMUX_PANE="$PANE" -- --max-loops 2 \
    --harness codex --handoff tmp/handoffs/FIRST.md -- --verbose
  context_record=absent
  [[ ! -e "$CASE_REPO_ROOT/tmp/lane-mail/overseer/context.json" ]] || context_record=present
  assert_eq "rc=$RC events=$(grep -c "^EVENT $event " <<<"$OUT" || true) args=$(grep '^--check-marks' "$STUB_DIR/succeed.args" | sort -u) context=$context_record" \
    "rc=$expected_rc events=$expected_events args=$expected_args context=absent" \
    "$name: a Codex node pane receives its account judgement before a context record" "$ERR"
done <<'ROWS'
node_account|idle|source|overseer-mark|0|1|--check-marks --harness codex
node_wall|walled|source|overseer-walled|3|1|--check-marks --harness codex
node_account_control|idle|control|overseer-mark|0|0|--check-marks
node_wall_control|walled|control|overseer-walled|0|0|--check-marks
ROWS

overseer_case walled_relaunch walled
state_with "$LINE"
wall_confirmed
run TMUX_PANE="$PANE" -- --max-loops 2 -- --verbose
assert_eq "$RC" "3" "a relaunched walled overseer ends the watch with the same status a death does" "$ERR"
assert_eq "$(head -n 1 <<<"$OUT")" "EVENT overseer-walled $PANE window=$WINDOW passes=2 succession=on source=pane" \
  "the event names the pane, its window, the passes it took and the setting" "$ERR"
assert_contains "$OUT" "$(printf "%b" "$WALL_BANNER")" \
  "the banner's own window follows the line, as a lane's usage-limit payload does" "$ERR"
assert_eq "$(succeed_calls --walled-pane)" "1" "the re-picking launch path is called once" "$ERR"
assert_eq "$(cat "$STUB_DIR/succeed.launched")" \
  "--walled-pane $PANE --handoff $HANDOFF_DEFAULT -- --verbose" \
  "naming the walled pane, the handoff path and the overseer's own flags" "$ERR"
assert_eq "$(succeed_calls --dead-pane)" "0" \
  "the recorded line is never sent: it names the account that walled" "$ERR"
# Four: each of the two long passes, and the mail pass before each, since the
# interval here is 0 and a mail pass's answer is kept for one interval.
assert_eq "$(succeed_calls --check-marks)" "4" \
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
# than measuring every account of the fleet a second time. Two readings in the
# run: the long pass's one, and the mail pass's own before it.
overseer_case walled_one_judgement walled
state_with "$LINE"
printf '%s\n' "oversee-succeed: mark-reached kind=context value=612000 mark=500000 succession=on headroom=80" \
  > "$STUB_DIR/succeed.check"
run TMUX_PANE="$PANE" -- --max-loops 1
assert_eq "judged=$(succeed_calls --check-marks) marks=$(grep -c '^EVENT overseer-mark' <<<"$OUT" || true)" \
  "judged=2 marks=1" \
  "the refuted wall reports the standing context mark off the one reading it took" "$ERR"

# The usage endpoint answered every account 429 on the control host because
# each watch, each judgement and each pick refreshed the same accounts
# independently. A pass names two of its OWN intervals to the lane reader
# inside the judgement: consecutive judgements are one interval of sleep plus a
# pass's work apart, so the previous reading is served rather than posted for
# again. A larger setting is kept, since this variable outranks the settings
# ladder, and one `lanes` cannot read is passed on for it to refuse. One pass
# per row, so the interval is never slept.
for row in \
  "two intervals, with no setting||90" \
  "a larger setting kept rather than narrowed|1000|1000" \
  "a smaller setting widened to two intervals|60|90" \
  "an unreadable setting passed on for lanes to refuse|4m|4m"; do
  IFS='|' read -r label setting want <<<"$row"
  overseer_case mark_interval walled
  state_with "$LINE"
  printf '%s\n' "oversee-succeed: mark-reached kind=context value=612000 mark=500000 succession=on headroom=80" \
    > "$STUB_DIR/succeed.check"
  if [[ -n "$setting" ]]; then
    run TMUX_PANE="$PANE" ORCH_LANES_USAGE_MAX_AGE="$setting" -- --max-loops 1 --interval 45
  else
    run TMUX_PANE="$PANE" -- --max-loops 1 --interval 45
  fi
  assert_eq "judged=$(succeed_calls --check-marks) age=$(paste -sd, "$STUB_DIR/succeed.max-age") accounts=$(paste -sd, "$STUB_DIR/lanes.max-age")" \
    "judged=2 age=$want,$want accounts=$want" \
    "the usage window of both account reads: $label" "$ERR"
done

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
rm -f -- "${STUB_DIR:?}/succeed.check"
run TMUX_PANE="$PANE" -- --max-loops 1
printf '%b\n' '⏺ Watching the fleet.' "$WALL_BANNER" '\xe2\x9d\xaf\xc2\xa0' > "$STUB_DIR/pane-$PANE.txt"
wall_confirmed
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
assert_eq "$(fleet_log_text)" "$(mailbox text)" \
  "and reaches the fleet log with that same text" "$ERR"
assert_eq "mail=$(mailbox_lines) log=$(jq '[.fleet_log[] | select(.item == "overseer")] | length' "$STUB_DIR/oversee-state.json")" \
  "mail=2 log=2" "the wall and the blocked recovery are the whole of what went out" "$ERR"
assert_contains "$(cat "$ERR")" "oversee-watch: overseer-recovery-blocked pane=$PANE account=$WALL_ACCOUNT resets=$WALL_RESETS" \
  "with the watch's own keyed line naming both" "$ERR"
run TMUX_PANE="$PANE" -- --max-loops 1
assert_eq "launched=$(succeed_calls --walled-pane) mail=$(mailbox_lines)" "launched=1 mail=2" \
  "a later pass neither retries the same accounts nor repeats the notice" "$ERR"

# An account judgement that named neither figure cannot supply measured
# values to the blocked recovery record.
overseer_case walled_no_room_unnamed walled
state_with "$LINE"
printf '%s\n' "oversee-succeed: mark-reached kind=headroom value=0 mark=10 succession=on" \
  > "$STUB_DIR/succeed.check"
printf '3\n' > "$STUB_DIR/succeed.rc"
run TMUX_PANE="$PANE" -- --max-loops 2
assert_contains "$(cat "$ERR")" "oversee-watch: overseer-recovery-blocked pane=$PANE account=unknown resets=none" \
  "a judgement naming neither figure leaves both structured fields unmeasured" "$ERR"

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
  "rc=4 first=EVENT overseer-walled $PANE window=$WINDOW passes=2 succession=off source=pane launched=0" \
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
overseer_case walled_flip walled
state_with "$LINE"
wall_confirmed
run TMUX_PANE="$PANE" -- --max-loops 1
printf 'bash\n' > "$STUB_DIR/cmd-$PANE.txt"
printf 'dev@host ~/kendex $\n' > "$STUB_DIR/pane-$PANE.txt"
run TMUX_PANE="$PANE" -- --max-loops 1
printf 'claude\n' > "$STUB_DIR/cmd-$PANE.txt"
printf '%b\n' '⏺ Watching the fleet.' "$WALL_BANNER" '\xe2\x9d\xaf\xc2\xa0' > "$STUB_DIR/pane-$PANE.txt"
run TMUX_PANE="$PANE" -- --max-loops 1
assert_eq "walled=$(succeed_calls --walled-pane) dead=$(succeed_calls --dead-pane)" \
  "walled=0 dead=0" \
  "a wall, a death and a wall again: each case counts its own readings alone" "$ERR"


# A reserve episode uses the existing row and attempt ceiling, while the
# current coordinator stays live. The pane banner can belong to another lane.
while IFS='|' read -r label pane_state launch_rc setting expected_rc attempts notices; do
  overseer_case "reserve_$label" "$pane_state"
  touch "$STUB_DIR/repeat-child"
  state_with "$LINE"
  printf '%s reserve_only=true\n' "$WALL_MARK_LINE" > "$STUB_DIR/succeed.check"
  printf '%s\n' "$launch_rc" > "$STUB_DIR/succeed.rc"
  reserve_marks=0
  for pass in 1 2 3; do
    run TMUX_PANE="$PANE" ORCH_OVERSEER_SUCCESSION="$setting" ORCH_OVERSEER_MARK_REPEAT=1 -- --max-loops 1
    current_marks="$(marks_seen)" || exit 1
    reserve_marks=$((reserve_marks + current_marks))
    [[ "$RC" != 3 ]] || break
  done
  assert_eq "rc=$RC attempts=$(succeed_calls --walled-pane) mail=$(mailbox_lines) walls=$(grep -c '^EVENT overseer-walled ' <<<"$OUT" || true) manual=$reserve_marks" \
    "rc=$expected_rc attempts=$attempts mail=$notices walls=0 manual=0" "reserve outcome: $label" "$ERR"
done <<'ROWS'
refused|idle|3|on|0|1|2
banner|walled|3|on|0|1|2
exhausted|idle|1|on|0|2|3
off|idle|3|off|0|0|1
success|idle|0|on|3|1|1
ROWS

# A reported reserve must not suppress a later real session failure.
while IFS='|' read -r label cmd screen expected_mode expected_attempts expected_rc; do
  overseer_case "reserve_then_$label" idle
  touch "$STUB_DIR/repeat-child"
  state_with "$LINE"
  printf '%s reserve_only=true\n' "$WALL_MARK_LINE" > "$STUB_DIR/succeed.check"
  printf '3\n' > "$STUB_DIR/succeed.rc"
  run TMUX_PANE="$PANE" -- --max-loops 1
  printf '%s\n' "$cmd" > "$STUB_DIR/cmd-$PANE.txt"
  printf '%b\n' "$screen" > "$STUB_DIR/pane-$PANE.txt"
  [[ "$label" != exit ]] || printf '0\n' > "$STUB_DIR/succeed.rc"
  if [[ "$label" == quota ]]; then wall_confirmed; fi
  run TMUX_PANE="$PANE" -- --max-loops 2
  assert_eq "rc=$RC recovered=$(succeed_calls "$expected_mode")" "rc=$expected_rc recovered=$expected_attempts" \
    "a later $label failure retains its own recovery" "$ERR"
done <<'ROWS'
auth|claude|⏺ Turn\nNot logged in · Please run /login\n❯ |--walled-pane|2|4
quota|claude|⏺ Turn\nYou've hit your usage limit · resets 9:50am (America/Los_Angeles)\n❯ |--walled-pane|2|4
exit|bash|dev@host ~/kendex $|--dead-pane|1|3
ROWS

# A session's own failure row outranks affirmative reserve metadata.
source "$(dirname "${BASH_SOURCE[0]}")/lib/overseer-row-world.sh"
while IFS='|' read -r label harness error message mode launch_rc expected_rc; do
  rows_case "reserve_rows_$label" blank \
    "$(row SessionStart "$harness" source=startup)" \
    "$(row StopFailure "$harness" "error=$error" "message=$message")"
  printf '%s reserve_only=true\n' "$WALL_MARK_LINE" > "$STUB_DIR/succeed.check"
  printf '%s\n' "$launch_rc" > "$STUB_DIR/succeed.rc"
  run TMUX_PANE="$PANE" -- --max-loops 2
  assert_eq "rc=$RC recovered=$(succeed_calls "$mode") reserves=$(grep -c '^EVENT overseer-reserve ' <<<"$OUT" || true)" \
    "rc=$expected_rc recovered=1 reserves=0" "session row $label outranks the launch reserve" "$ERR"
done <<'ROWS'
quota|claude|rate_limit|Usage limit reached|--walled-pane|3|4
auth|claude|authentication_failed|Login failed|--walled-pane|3|4
pi-quota|pi||You've hit your limit · resets 9:50am (America/Los_Angeles)|--walled-pane|3|4
context|claude|invalid_request|Prompt is too long|--dead-pane|0|3
ROWS

# The repeat owner survives an actual no-successor reply. The capacity notice
# acknowledges that refusal before the fixture produces new mail and an ask
# deadline. The same owner then delivers all three events. After those events
# are visible, the fixture changes the pane to exited and permits succession
# to end the test through the normal success path. The outer timeout only
# bounds a broken test; it never keeps the watch alive.
cat > "$TMP_ROOT/bin/reserve-mail.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
"$REAL_LANE_MAIL" "$@"
if [[ "$1" == send && "$*" == *overseer-blocked.txt* && ! -e "$STUB_DIR/injected" ]]; then
  touch "$STUB_DIR/injected"
  printf 'Lane decision\n' > "$STUB_DIR/question.txt"
  "$REAL_LANE_MAIL" ask --item KEN-7 --file "$STUB_DIR/question.txt" --options cut,keep > "$STUB_DIR/lane-id"
  "$REAL_LANE_MAIL" send --item overseer --directive --file "$STUB_DIR/question.txt" >/dev/null
  "$REAL_LANE_MAIL" ask --item overseer --to owner --file "$STUB_DIR/question.txt" \
    --options cut,keep --recommend cut --wait 0 > "$STUB_DIR/deadline-id"
fi
EOF
cat > "$TMP_ROOT/bin/reserve-succeed.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == --check-marks ]] && [[ -f "$STUB_DIR/injected" ]] \
   && grep -q '^EVENT lane-question KEN-7 ' "$STUB_DIR/repeat.out" \
   && grep -q '^EVENT owner-note ' "$STUB_DIR/repeat.out" \
   && grep -q '^EVENT owner-ask-resolved .* by=default ' "$STUB_DIR/repeat.out"; then
  printf 'bash\n' > "$STUB_DIR/cmd-${TMUX_PANE}.txt"
  printf 'dev@host ~/kendex $\n' > "$STUB_DIR/pane-${TMUX_PANE}.txt"
  printf '0\n' > "$STUB_DIR/succeed.rc"
fi
exec "$RESERVE_SUCCEED" "$@"
EOF
cat > "$TMP_ROOT/bin/reserve-bound-watch.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exec timeout 60 "$RESERVE_TARGET" "$@"
EOF
chmod +x "$TMP_ROOT/bin/reserve-mail.sh" "$TMP_ROOT/bin/reserve-succeed.sh" "$TMP_ROOT/bin/reserve-bound-watch.sh"
reserve_repeat() { # TARGET NAME
  overseer_case "$2" idle
  state_with "$LINE"
  printf '%s reserve_only=true\n' "$WALL_MARK_LINE" > "$STUB_DIR/succeed.check"
  printf '3\n' > "$STUB_DIR/succeed.rc"
  printf '{"issue_id":"oversee","triaged":[],"lanes":[]}\n' > "$STUB_DIR/state.json"
  : > "$STUB_DIR/repeat.out"
  REPEAT_RC=0
  WATCH_BIN="$TMP_ROOT/bin/reserve-bound-watch.sh" run_watch TMUX_PANE="$PANE" \
    RESERVE_TARGET="$1" RESERVE_SUCCEED="$TMP_ROOT/bin/succeed-stub.sh" \
    REAL_LANE_MAIL="$REAL_LANE_MAIL" OVERSEE_WATCH_SUCCEED="$TMP_ROOT/bin/reserve-succeed.sh" \
    OVERSEE_WATCH_LANE_MAIL="$TMP_ROOT/bin/reserve-mail.sh" \
    -- --max-loops 1 --repeat 0 --state "$STUB_DIR/state.json" --item KEN-7 \
    > "$STUB_DIR/repeat.out" 2> "$STUB_DIR/repeat.err" </dev/null || REPEAT_RC=$?
  OUT="$(cat "$STUB_DIR/repeat.out")"
  assert_eq "rc=$REPEAT_RC injected=$([[ -e "$STUB_DIR/injected" ]] && echo yes || echo no) attempts=$(succeed_calls --walled-pane)" \
    'rc=0 injected=yes attempts=1' 'reserve refusal reached once through the repeat watch' "$STUB_DIR/repeat.err"
  assert_eq "lane=$(grep -c '^EVENT lane-question KEN-7 ' <<<"$OUT" || true) owner=$(grep -c '^EVENT owner-note ' <<<"$OUT" || true) deadline=$(grep -c '^EVENT owner-ask-resolved .* by=default ' <<<"$OUT" || true)" \
    'lane=1 owner=3 deadline=1' 'same repeat owner delivers lane mail, owner mail and the ask deadline after refusal' "$STUB_DIR/repeat.err"
  assert_eq "capacity=$(grep -c '^oversee-watch: overseer-capacity-blocked ' "$STUB_DIR/repeat.err" || true) handover=$(succeed_calls --dead-pane)" \
    'capacity=1 handover=1' 'reserve capacity notice is bounded and later exit recovery succeeds' "$STUB_DIR/repeat.err"
  assert_eq "$(marks_seen)" 0 'automatic reserve recovery sends no parallel manual succession event' "$STUB_DIR/repeat.err"
}
reserve_repeat .agents/skills/orch/scripts/oversee-watch reserve_repeat
MARK_CTL="$(mutant_scripts reserve-mark-ctl/orch oversee-watch)" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/reserve-mark-ctl/github"
mutate_file "$MARK_CTL/oversee-watch" \
  '    if [[ "$ov_case" == reserve ]]; then
      # Automatic reserve recovery owns succession, including its retry.' \
  '    if [[ "$ov_case" == reserve ]] && false; then
      # Automatic reserve recovery owns succession, including its retry.'
CONTROL_RC=0
( PASS=0 FAIL=0; reserve_repeat "$MARK_CTL/oversee-watch" reserve_mark_control; [[ "$FAIL" == 0 ]] ) \
  > "$TMP_ROOT/reserve-mark-control.log" || CONTROL_RC=$?
assert_eq "$CONTROL_RC" 1 'control: restoring ordinary marks during reserve recovery fails the single-owner assertion'
assert_eq "$(grep -c '^EVENT overseer-mark ' "$TMP_ROOT/cases/reserve_mark_control/repeat.out" || true)" 1 \
  'control reaches automatic reserve recovery and emits the conflicting manual event'
RESERVE_CTL="$(mutant_scripts reserve-ctl/orch oversee-watch)" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/reserve-ctl/github"
mutate_file "$RESERVE_CTL/oversee-watch" \
  '&& "$OVERSEER_MARK_VALUE" == 0 && "$OVERSEER_MARK_RESERVE_ONLY" != true ]]; then' \
  '&& "$OVERSEER_MARK_VALUE" == 0 && ( "$OVERSEER_MARK_RESERVE_ONLY" != true || true ) ]]; then'
CONTROL_RC=0
( PASS=0 FAIL=0; reserve_repeat "$RESERVE_CTL/oversee-watch" reserve_repeat_control; [[ "$FAIL" == 0 ]] ) \
  > "$TMP_ROOT/reserve-control.log" || CONTROL_RC=$?
assert_eq "$CONTROL_RC" 1 'control: treating reserve as a wall loses the post-refusal mail events'
CONTROL_CASE="$TMP_ROOT/cases/reserve_repeat_control"
assert_eq "refused=$(grep -c '^oversee-watch: overseer-recovery-blocked ' "$CONTROL_CASE/repeat.err" || true) injected=$([[ -e "$CONTROL_CASE/injected" ]] && echo yes || echo no) delivered=$(grep -c '^EVENT lane-question KEN-7 ' "$CONTROL_CASE/repeat.out" || true)" \
  'refused=1 injected=yes delivered=0' 'control reaches refusal and then loses the new lane question'

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
