#!/usr/bin/env bash
# Tests for oversee-watch's overseer marks contract.
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


# --- the overseer's own marks ---------------------------------------------
# The event reaches an overseer BETWEEN turn ends, where its own turn-end hook
# cannot. The judgement is oversee-succeed's, so what is asserted here is which
# of its answers becomes an event, what that event carries, how often a
# standing mark comes back, and which answers leave a standing mark where it is.
# A fleet whose settings name no preference is told the default ladder the
# succession will walk, not that the preference is empty. A case of its own,
# so the mark is news.
overseer_case mark_default idle
state_with "$LINE"
mark_stands
# The watch inherits this suite's environment, so the setting is dropped from
# it; every row that reads the preference names its own.
unset ORCH_OVERSEER_PREFERENCE
run TMUX_PANE="$PANE" ORCH_OVERSEER_MARK_REPEAT=3 -- --max-loops 1
assert_contains "$OUT" "-- [FLAGS] at the next safe point, with ORCH_OVERSEER_PREFERENCE=$OL_DEFAULT_PREFERENCE choosing the successor lane." \
  "an unset preference names the default ladder the succession walks" "$ERR"

overseer_case mark_reported idle
state_with "$LINE"
mark_stands
run TMUX_PANE="$PANE" ORCH_OVERSEER_MARK_REPEAT=3 ORCH_OVERSEER_PREFERENCE=claude:fable:high -- --max-loops 1
assert_eq "rc=$RC first=$(head -n 1 <<<"$OUT")" \
  "rc=0 first=EVENT overseer-mark $PANE kind=context value=612000 mark=500000 succession=on" \
  "a reached mark becomes the event, carrying its kind, the value read and the mark crossed" "$ERR"
assert_contains "$OUT" "-- [FLAGS] at the next safe point, with ORCH_OVERSEER_PREFERENCE=claude:fable:high choosing the successor lane." \
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
  shortened_ceiling_watch
  overseer_case mark_ceiling idle
  state_with "$LINE"
  mark_stands
  touch "$STUB_DIR/succeed.check-hang"
  WATCH_BIN="$CEILING_WATCH" run TMUX_PANE="$PANE" -- --max-loops 1
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
printf '%s\n' "oversee-succeed: mark-reached kind=headroom value=20 mark=20 succession=off account=claude resets=2099-07-27T06:00:00Z" \
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

# A reserve episode clears only on a measured below-mark result. Failed or
# unmeasured readings keep the bounded refusal, and the next real crossing
# starts a new episode. The shared parser must clear an omitted reserve field.
overseer_case reserve_lifts idle
touch "$STUB_DIR/repeat-child"
state_with "$LINE"
printf '%s reserve_only=true\n' "$WALL_MARK_LINE" > "$STUB_DIR/succeed.check"
printf '3\n' > "$STUB_DIR/succeed.rc"
run TMUX_PANE="$PANE" -- --max-loops 1
reserve_lifted=no
for reading in unmeasured unread reserve below reserve wall; do
  rm -f -- "${STUB_DIR:?}/succeed.check-rc"
  case "$reading" in
    unmeasured) printf '%s\n' 'oversee-succeed: mark-unmeasured kind=headroom reason=headroom-none succession=on' > "$STUB_DIR/succeed.check" ;;
    unread) printf '2\n' > "$STUB_DIR/succeed.check-rc" ;;
    reserve) printf '%s reserve_only=true\n' "$WALL_MARK_LINE" > "$STUB_DIR/succeed.check" ;;
    below) mark_lifts ;;
    wall) wall_confirmed ;;
  esac
  run TMUX_PANE="$PANE" -- --max-loops 1
  case "$reading" in
    unmeasured|unread) expected=1 ;;
    below) expected=1 ;;
    wall) expected=3 ;;
    reserve) expected=1; [[ "$reserve_lifted" != yes ]] || expected=2 ;;
  esac
  assert_eq "$(succeed_calls --walled-pane)" "$expected" "reserve episode after $reading" "$ERR"
  [[ "$reading" != below ]] || reserve_lifted=yes
done

# --- one reading per PASS, not per process -------------------------------
# A single invocation runs up to --max-loops passes an --interval apart, so a
# judgement memoised for the process would answer every later pass with the
# first one's reading. The rows below are the two ways that goes wrong, each
# inside ONE process.
#
# check_switch_after_first LINE — the stub answers LINE from the second
# reading of the next process on, its counter cleared here.
# A wall that lands after the first pass. Pass 1 measures room, so the wall is
# refuted and its row cleared; passes 2 and 3 measure the account at its
# trigger, which is the threshold met on a reading taken after the wall
# landed. A reading memoised for the process never sees it. Four readings:
# the mail pass takes its own before each long pass, the first of them the
# one that measures room.
overseer_case walled_confirmed_later walled
state_with "$LINE"
check_switch_after_first "$WALL_MARK_LINE"
run TMUX_PANE="$PANE" -- --max-loops 3 -- --verbose
assert_eq "rc=$RC judged=$(succeed_calls --check-marks) launched=$(succeed_calls --walled-pane)" \
  "rc=3 judged=4 launched=1" \
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
check_switch_after_first "oversee-succeed: account-below-mark headroom=80"
run TMUX_PANE="$PANE" ORCH_OVERSEER_MARK_REPEAT=5 -- --max-loops 2
assert_eq "rc=$RC judged=$(checks_since_switch) marks=$(marks_seen)" \
  "rc=0 judged=2 marks=0" \
  "each pass of that run takes its own reading, and the second says the mark lifted" "$ERR"
rm -f -- "${STUB_DIR:?}/succeed.check-later"
mark_stands
run TMUX_PANE="$PANE" ORCH_OVERSEER_MARK_REPEAT=5 -- --max-loops 1
assert_eq "marks=$(marks_seen)" "marks=1" \
  "so the same mark reached again is a fresh crossing, its row having been cleared" "$ERR"



# A standing mark is suppressed until the repeat count comes back around.
repeat_control_row() {
  overseer_case mark_repeat_oracle idle
  state_with "$LINE"
  mark_stands
  run TMUX_PANE="$PANE" ORCH_OVERSEER_MARK_REPEAT=3 -- --max-loops 1
  run TMUX_PANE="$PANE" ORCH_OVERSEER_MARK_REPEAT=3 -- --max-loops 1
  assert_eq "rc=$RC marks=$(marks_seen)" "rc=0 marks=0" 'standing mark repeat oracle' "$ERR"
}
repeat_control_row
REPEAT_CTL="$(mutant_scripts repeat-ctl/orch oversee-watch)" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/repeat-ctl/github"
mutate_file "$REPEAT_CTL/oversee-watch" '    passes=$(( ${prior#*|} + 1 ))' '    passes=0'
CONTROL_RC=0
( PASS=0 FAIL=0; WATCH_BIN="$REPEAT_CTL/oversee-watch" repeat_control_row; [[ "$FAIL" == 0 ]] ) > "$TMP_ROOT/repeat-control.log" || CONTROL_RC=$?
assert_eq "$CONTROL_RC" 1 'control: a repeated mark turns the suppression assertion red'

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
