#!/usr/bin/env bash
# Tests for oversee-watch's overseer contract.
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


# --- the death itself, and the relaunch it ends in -------------------------
# Two passes in one run: the first reading is a poll that caught a live session
# between its harness and its shell, and only the second is news.
overseer_case dead_relaunch exited
state_with "$LINE"
FL_BEFORE="$(date -u +%s)"
run TMUX_PANE="$PANE" -- --max-loops 2
FL_AFTER="$(date -u +%s)"
assert_eq "$RC" "3" "a relaunched overseer ends the watch with its own status" "$ERR"
assert_eq "$(head -n 1 <<<"$OUT")" "EVENT overseer-dead $PANE window=$WINDOW passes=2 succession=on source=pane" \
  "the event names the pane, its window, the passes it took and the setting" "$ERR"
assert_eq "$(succeed_calls --dead-pane)" "1" "the launch path is called once" "$ERR"
# The line reaches the launcher through a file in the watch's own scratch
# directory, whose name is a fresh mktemp -d per run: the launched argv is
# read with that path's leading directories replaced, so the row pins the
# call's shape and the file it names rather than one run's temporary path.
assert_eq "$(sed 's|--line-file .*/|--line-file |' "$STUB_DIR/succeed.launched")" \
  "--dead-pane $PANE --handoff $HANDOFF_DEFAULT --line-file overseer-line" \
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

# A succession's pending successor, written before its window opened, is the
# launch the fleet last chose: a death while it stands replays it, not the
# dead session's own line.
PENDING_LINE="env CLAUDE_CONFIG_DIR='/home/me/.eclaude' claude -n overseer --model fable 'brief'"
pending_state() {
  state_with "$LINE"
  jq --arg line "$PENDING_LINE" '.overseer.pending = {launch_line: $line, account: "/home/me/.eclaude"}' \
    "$STUB_DIR/oversee-state.json" > "$STUB_DIR/oversee-state.json.tmp" \
    && mv -- "$STUB_DIR/oversee-state.json.tmp" "$STUB_DIR/oversee-state.json"
}
overseer_case dead_relaunch_pending exited
pending_state
run TMUX_PANE="$PANE" -- --max-loops 2
assert_eq "rc=$RC line=$(cat "$STUB_DIR/succeed.line-file")" "rc=3 line=$PENDING_LINE" \
  "a death while a pending successor stands relaunches the pending line" "$ERR"
# The control: a relaunch that reads the session's own line alone replays the
# command the succession had already moved off.
PENDING_MUTANT="$(mutant_scripts pending-mutant/orch lib/watch-overseer-record.sh)" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/pending-mutant/github"
mutate_file "$PENDING_MUTANT/lib/watch-overseer-record.sh" \
  'then ($o.pending.launch_line // $o.launch_line // "")' 'then ($o.launch_line // "")'
overseer_case dead_relaunch_pending_mutant exited
pending_state
WATCH_BIN="$PENDING_MUTANT/oversee-watch" run TMUX_PANE="$PANE" -- --max-loops 2
assert_eq "rc=$RC line=$(cat "$STUB_DIR/succeed.line-file")" "rc=3 line=$LINE" \
  "control: a relaunch that ignores the pending line replays the dead session's own" "$ERR"

# --- one pass is not a death ----------------------------------------------
# A note that lands while the pane reads exited is held: the mail pass reads no
# mailbox while a long pass's reading stands, so the note waits for a live
# overseer or a successor rather than a log nobody reads. Three passes to a
# death here, so two exited readings go by without one.
overseer_case dead_one_pass exited
state_with "$LINE"
run TMUX_PANE="$PANE" ORCH_OVERSEER_DEAD_PASSES=3 -- --max-loops 1
assert_eq "rc=$RC first=$(head -n 1 <<<"$OUT")" "rc=0 first=EVENT heartbeat loops=1 interval=0s since=none" \
  "one exited reading is a poll, not news" "$ERR"
assert_eq "$(succeed_calls --dead-pane)" "0" "and nothing is launched on it" "$ERR"
printf 'Retain this event for the next live overseer.\n' > "$TMP_ROOT/held-event.txt"
(cd "$CASE_REPO_ROOT" && "$REPO_ROOT/skills/mailbox/scripts/lane-mail" send \
  --item overseer --directive --file "$TMP_ROOT/held-event.txt" >/dev/null)
HELD_EVENT="$(jq -r .id "$CASE_REPO_ROOT/tmp/lane-mail/overseer/to-lane.jsonl")"
run TMUX_PANE="$PANE" ORCH_OVERSEER_DEAD_PASSES=3 -- --max-loops 1
assert_eq "events=$(grep -c '^EVENT owner-note' <<<"$OUT" || true) cursor=$(mail_cursor_count)" \
  "events=0 cursor=0" "a note sent while the pane reads exited is left unread" "$ERR"
printf 'claude\n' > "$STUB_DIR/cmd-$PANE.txt"
printf '%b\n' '⏺ The overseer is live.' '\xe2\x9d\xaf\xc2\xa0' > "$STUB_DIR/pane-$PANE.txt"
run TMUX_PANE="$PANE" ORCH_OVERSEER_DEAD_PASSES=3 -- --max-loops 1
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
assert_eq "$(head -n 1 <<<"$OUT")" "EVENT overseer-dead $PANE window=$WINDOW passes=2 succession=off source=pane" \
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
  "rc=4 first=EVENT overseer-dead $PANE window=$WINDOW passes=2 succession=on source=pane record=7000:$PANE" \
  "a death with no recorded line is still the event, naming the record it was judged against" "$ERR"
assert_eq "$(succeed_calls --dead-pane)" "0" "and launches nothing" "$ERR"
assert_contains "$(fleet_log_text)" "The fleet state record for this pane holds no launch line, so no successor is launched; start one by hand." \
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
assert_eq "$(grep -c "oversee-watch: overseer-unreadable pane=$PANE field=inspect" "$ERR")" "1" \
  "and the reason is named once" "$ERR"

# A child probe the adapter's `inspect` could not run is named with the
# status the adapter reported, never one this watch's own lane probes left.
probe_case() { # WATCH_BIN
  overseer_case probe_unusable exited
  state_with "$LINE"
  printf '3\n' > "$STUB_DIR/probe-fail-9009"
  WATCH_BIN="${1:-}" run TMUX_PANE="$PANE" -- --max-loops 1
  PROBE_NOTE="$(grep -c "^oversee-watch: child-probe-failed lane=$PANE exit=3\$" "$ERR" || true)"
  PROBE_NOTE="$PROBE_NOTE|$(grep -c "^oversee-watch: child-probe-failed lane=$PANE exit=0\$" "$ERR" || true)"
}
probe_case
assert_eq "$PROBE_NOTE" "1|0" "an overseer child probe that cannot run is named with the adapter's status" "$ERR"
PROBE_MUTANT="$(mutant_scripts probe-mutant/orch oversee-watch)" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/probe-mutant/github"
mutate_file "$PROBE_MUTANT/oversee-watch" 'note_probe_unusable "$pane" "$OL_INSPECT_PROBE"' 'note_probe_unusable "$pane"'
probe_case "$PROBE_MUTANT/oversee-watch"
assert_eq "$PROBE_NOTE" "0|1" "control: a note taking the watch's own probe status misnames the overseer's" "$ERR"

# A pane the adapter answers gone settles nothing either, the reason named:
# the stub's pane listing leaves out a pane with no foreground command.
overseer_case gone_pane exited
state_with "$LINE"
rm -f -- "${STUB_DIR:?}/cmd-$PANE.txt"
run TMUX_PANE="$PANE" -- --max-loops 2
assert_eq "rc=$RC launched=$(succeed_calls --dead-pane) noted=$(grep -c "^oversee-watch: overseer-unreadable pane=$PANE field=session state=gone\$" "$ERR" || true)" \
  "rc=0 launched=0 noted=1" \
  "an overseer pane the adapter answers gone launches nothing and names why once" "$ERR"

# A wall scan the adapter could not run leaves the fallback reading unread.
# The grep failure reaches the combined usage and authentication scan.
LIMIT_BIN="$TMP_ROOT/limit-scan-bin"
mkdir -p "$LIMIT_BIN"
# shellcheck source=../scripts/lib/lane-state.sh
LIMIT_RE="$(source "$REPO_ROOT/skills/orch/scripts/lib/lane-state.sh" && printf '%s' "$USAGE_LIMIT_RE|$AUTH_FAILURE_RE")"
cat > "$LIMIT_BIN/grep" <<STUB
#!/usr/bin/env bash
for arg in "\$@"; do [[ "\$arg" != $(printf '%q' "$LIMIT_RE") ]] || exit 2; done
exec $(command -v grep) "\$@"
STUB
cat > "$LIMIT_BIN/provider" <<STUB
#!/bin/sh
PATH="$LIMIT_BIN:\$PATH" exec "$REPO_ROOT/.agents/skills/orch/scripts/overseer-host-tmux" "\$@"
STUB
chmod +x "$LIMIT_BIN/grep" "$LIMIT_BIN/provider"
overseer_case limit_scan idle
state_with "$LINE"
run ORCH_OVERSEER_HOST="$LIMIT_BIN/provider" TMUX_PANE="$PANE" -- --max-loops 1
assert_eq "rc=$RC noted=$(grep -c "^oversee-watch: overseer-unreadable pane=$PANE scan=usage-limit\$" "$ERR" || true)" \
  "rc=0 noted=1" \
  "an overseer screen whose usage-limit scan could not run is named unreadable, never judged" "$ERR"
# Both scans failing on one read: the probe named with its status, and the
# screen unreadable.
both_case() { # [WATCH_BIN]
  overseer_case both_scans exited
  state_with "$LINE"
  printf '3\n' > "$STUB_DIR/probe-fail-9009"
  WATCH_BIN="${1:-}" run ORCH_OVERSEER_HOST="$LIMIT_BIN/provider" TMUX_PANE="$PANE" -- --max-loops 1
  BOTH_NOTES="$(grep -c "^oversee-watch: child-probe-failed lane=$PANE exit=3\$" "$ERR" || true)"
  BOTH_NOTES="$BOTH_NOTES|$(grep -c "^oversee-watch: overseer-unreadable pane=$PANE scan=usage-limit\$" "$ERR" || true)"
}
both_case
assert_eq "$BOTH_NOTES" "1|1" "an overseer read where both scans fail notes the probe and the unreadable screen" "$ERR"
BOTH_MUTANT="$(mutant_scripts both-mutant/orch oversee-watch)" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/both-mutant/github"
mutate_file "$BOTH_MUTANT/oversee-watch" '[[ ",$OL_INSPECT_CAUSE," != *,process-probe,* ]]' \
  '[[ "$OL_INSPECT_CAUSE" != process-probe ]]'
both_case "$BOTH_MUTANT/oversee-watch"
assert_eq "$BOTH_NOTES" "0|1" "control: a cause matched whole drops the probe note beside the limit scan" "$ERR"

# --- the settings this check reads ----------------------------------------
overseer_case dead_passes_one exited
state_with "$LINE"
run ORCH_OVERSEER_DEAD_PASSES=1 TMUX_PANE="$PANE" -- --max-loops 1
assert_eq "rc=$RC first=$(head -n 1 <<<"$OUT")" \
  "rc=3 first=EVENT overseer-dead $PANE window=$WINDOW passes=1 succession=on source=pane" \
  "a one-pass setting fires on the first reading and says so" "$ERR"

# A repeat count of 0, or one no arithmetic can read, would make the pass
# comparison read 0 and report a standing mark on every pass — the flood the
# count exists to bound.
for row in \
  "ORCH_OVERSEER_DEAD_PASSES=0|dead-passes-invalid ORCH_OVERSEER_DEAD_PASSES=0|a zero pass count refuses" \
  "ORCH_OVERSEER_DEAD_PASSES=two|dead-passes-invalid ORCH_OVERSEER_DEAD_PASSES=two|a non-numeric pass count refuses" \
  "ORCH_OVERSEER_MARK_REPEAT=0|mark-repeat-invalid ORCH_OVERSEER_MARK_REPEAT=0|a zero repeat count refuses" \
  "ORCH_OVERSEER_MARK_REPEAT=five|mark-repeat-invalid ORCH_OVERSEER_MARK_REPEAT=five|a non-numeric repeat count refuses" \
  "ORCH_WATCH_MAIL_INTERVAL=020|mail-interval-invalid value=020|a mail interval with a leading zero refuses" \
  "ORCH_DIRECTIVE_UNREAD_SECS=five|unread-secs-invalid value=five|a non-numeric unread age refuses"; do
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

# --- control --------------------------------------------------------------
# The suite's one must-fail control: the debounce removed. One exited reading
# then fires, which is the poll that caught a live session between its harness
# and its shell relaunching an overseer that never died. The mutant keeps
# orch's place in a skills tree so its libraries resolve the github skill
# beside it.
MUTANT_SCRIPTS="$(mutant_scripts mutant/orch oversee-watch)" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/mutant/github"
mutate_file "$MUTANT_SCRIPTS/oversee-watch" '    if (( count < passes )); then' '    if false; then'
overseer_case debounce_mutant exited
state_with "$LINE"
WATCH_BIN="$MUTANT_SCRIPTS/oversee-watch" run TMUX_PANE="$PANE" -- --max-loops 1
assert_eq "rc=$RC launched=$(succeed_calls --dead-pane)" "rc=3 launched=1" \
  "control: without the debounce a single reading relaunches the overseer" "$ERR"

# The pass-level gate: an event consumer advances no baseline on the first
# exited reading. The long pass's own consumers are what it guards, the merged
# check among them; the mail pass has its own gate.
overseer_case consumer_gated exited
state_with "$LINE"
printf '[{"number":7,"headRefName":"ken-1","mergedAt":"2026-09-14T10:00:00Z"}]\n' > "$STUB_DIR/merged.json"
run TMUX_PANE="$PANE" ORCH_OVERSEER_DEAD_PASSES=3 -- --max-loops 1 --item KEN-1
assert_not_contains "$OUT" "EVENT merged 7 ken-1" \
  "the first exited reading consumes no merged event: the long pass stops at the overseer's pane" "$ERR"

overseer_case dead_custom_handoff exited
state_with "$LINE"
run TMUX_PANE="$PANE" -- --max-loops 2 --handoff tmp/handoffs/CURRENT.md
assert_eq "$(sed 's|--line-file .*/|--line-file |' "$STUB_DIR/succeed.launched")" \
  "--dead-pane $PANE --handoff tmp/handoffs/CURRENT.md --line-file overseer-line" \
  'the recovery checks the handoff path the watch names' "$ERR"
HANDOFF_CTL="$(mutant_scripts handoff-ctl/orch oversee-watch)" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/handoff-ctl/github"
mutate_file "$HANDOFF_CTL/oversee-watch" \
  '--dead-pane "$pane" --handoff "$HANDOFF" --line-file' \
  '--dead-pane "$pane" --line-file'
overseer_case dead_custom_handoff_control exited
state_with "$LINE"
WATCH_BIN="$HANDOFF_CTL/oversee-watch" run TMUX_PANE="$PANE" -- --max-loops 2 --handoff tmp/handoffs/CURRENT.md
assert_eq "$(sed 's|--line-file .*/|--line-file |' "$STUB_DIR/succeed.launched")" \
  "--dead-pane $PANE --line-file overseer-line" \
  'control: removing the forwarded handoff path loses the custom snapshot' "$ERR"


printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
