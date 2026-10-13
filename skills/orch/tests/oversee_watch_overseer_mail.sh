#!/usr/bin/env bash
# Tests for oversee-watch's overseer mail contract.
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


# --- the mail pass reads the overseer's pane afresh ------------------------
# A lane-mail that logs each drain with the pr-watch calls made so far, so a
# case can tell a mail pass that ran before the first long pass from one that
# waited for it.
cat > "$TMP_ROOT/bin/lane-mail-order.sh" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == drain ]]; then
  printf 'drain long=%s\n' "$(cat "$STUB_DIR/prwatch.calls.owner_repo" 2>/dev/null || echo 0)" >> "$STUB_DIR/order.log"
fi
exec "$REAL_LANE_MAIL" "$@"
EOF
chmod +x "$TMP_ROOT/bin/lane-mail-order.sh"

# The pane exits after one long pass read it live and before the next: no row
# says so yet, and the note sent then is still left for the successor.
exited_between() {
  overseer_case dead_between_passes exited
  state_with "$LINE"
  printf 'Sent after the overseer exited.\n' > "$TMP_ROOT/between-note.txt"
  (cd "$CASE_REPO_ROOT" && "$REAL_LANE_MAIL" send --item overseer --directive --file "$TMP_ROOT/between-note.txt" >/dev/null)
  run TMUX_PANE="$PANE" ORCH_OVERSEER_DEAD_PASSES=3 -- --max-loops 1
  BETWEEN="events=$(grep -c '^EVENT owner-note' <<<"$OUT" || true) cursor=$(mail_cursor_count)"
}
exited_between
assert_eq "$BETWEEN" "events=0 cursor=0" \
  "a note sent after the pane exited, before any long pass read it, is left unread" "$ERR"

# A wall row another pane left, the pane that held this fleet before: this
# pane's screen carries a relayed banner and its own account measures room,
# so the first mail pass reads the lane's notice rather than waiting for a
# long pass to prune that row.
other_pane_wall() {
  overseer_case walled_other_pane walled
  state_with "$LINE"
  mkdir -p "$STATE_DIR"
  printf 'overseer-walled\t7000 %%1\tpending:0\n' > "$STATE_DIR/owner_repo__none"
  rm -rf -- "${CASE_REPO_ROOT:?}/tmp/lane-mail"
  mkdir -p "$CASE_REPO_ROOT/tmp/lane-mail/KEN-5"
  printf 'Rebased.\n' > "$TMP_ROOT/other-notice.txt"
  (cd "$CASE_REPO_ROOT" && "$REAL_LANE_MAIL" notice --item KEN-5 --file "$TMP_ROOT/other-notice.txt" >/dev/null)
  run TMUX_PANE="$PANE" OVERSEE_WATCH_LANE_MAIL="$TMP_ROOT/bin/lane-mail-order.sh" \
    REAL_LANE_MAIL="$REAL_LANE_MAIL" -- --max-loops 1 --item KEN-5
  FIRST_DRAIN="$(head -n 1 "$STUB_DIR/order.log" 2>/dev/null || echo none)"
}
other_pane_wall
assert_eq "first=$FIRST_DRAIN notice=$(grep -c '^EVENT lane-notice KEN-5 ' <<<"$OUT" || true)" "first=drain long=0 notice=1" \
  "another pane's wall row holds no mail pass: the first one reads the lane's notice" "$ERR"

# The account walls between two long passes: the pane reads walled, the
# account judgement confirms it, and no long pass has committed a row yet. The
# mail pass asks that judgement itself, so the note waits for a live overseer.
walled_between() {
  overseer_case walled_between_passes walled
  state_with "$LINE"
  printf '%s\n' "$WALL_MARK_LINE" > "$STUB_DIR/succeed.check"
  printf 'Sent after the account walled.\n' > "$TMP_ROOT/walled-note.txt"
  (cd "$CASE_REPO_ROOT" && "$REAL_LANE_MAIL" send --item overseer --directive --file "$TMP_ROOT/walled-note.txt" >/dev/null)
  run TMUX_PANE="$PANE" ORCH_OVERSEER_DEAD_PASSES=3 -- --max-loops 1
  WALLED="events=$(grep -c '^EVENT owner-note' <<<"$OUT" || true) cursor=$(mail_cursor_count)"
}
walled_between
assert_eq "$WALLED" "events=0 cursor=0" \
  "a note sent once the account walls, before any long pass commits the wall, is left unread" "$ERR"

# The watch itself dies while its long pass settles the overseer: the exit
# still says what that pass decided, 3 for a successor holding the window and
# 4 for a repeat pass stopping on a notice-only recovery, so repeat mode stops
# rather than start a second watch. The boundary is staged: the notice's send
# to the overseer mailbox takes the fleet state away and waits for the watch
# to die on it before the long pass goes on.
cat > "$TMP_ROOT/bin/lane-mail-vanish.sh" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-} ${2:-} ${3:-}" == "send --item overseer" ]]; then
  unlink "$VANISH"
  n=0
  until grep -q '^oversee-watch: state-unreadable ' "$VANISH_AWAIT" 2>/dev/null || [[ "$n" -ge 200 ]]; do
    n=$((n + 1)); sleep 0.1
  done
fi
exec "$REAL_LANE_MAIL" "$@"
EOF
chmod +x "$TMP_ROOT/bin/lane-mail-vanish.sh"
parent_dies() { # on|off
  overseer_case "dead_parent_dies_$1" exited
  state_with "$LINE"
  cp "$STUB_DIR/oversee-state.json" "$STUB_DIR/fleet.json"
  run TMUX_PANE="$PANE" ORCH_OVERSEER_DEAD_PASSES=1 ORCH_WATCH_MAIL_INTERVAL=1 \
    ORCH_OVERSEER_SUCCESSION="$1" OVERSEE_WATCH_LANE_MAIL="$TMP_ROOT/bin/lane-mail-vanish.sh" \
    REAL_LANE_MAIL="$REAL_LANE_MAIL" VANISH="$STUB_DIR/fleet.json" VANISH_AWAIT="$TMP_ROOT/run-$((RUN_SEQ + 1)).err" \
    -- --max-loops 2 --state "$STUB_DIR/fleet.json"
  DIES="rc=$RC launched=$(succeed_calls --dead-pane) unreadable=$(grep -c '^oversee-watch: state-unreadable ' "$ERR" || true)"
}
parent_dies on
assert_eq "$DIES" "rc=3 launched=1 unreadable=1" \
  "a watch that dies while its long pass launches the successor still exits 3" "$ERR"
parent_dies off
assert_eq "$DIES" "rc=4 launched=0 unreadable=1" \
  "a repeat pass that dies while its long pass stops on a notice-only recovery still exits 4" "$ERR"


# --- one verdict, judged once a wall ---------------------------------------
relayed_banner_case() { # NAME
  overseer_case "$1" walled
  state_with "$LINE"
  rm -rf -- "${CASE_REPO_ROOT:?}/tmp/lane-mail"
  mkdir -p "$CASE_REPO_ROOT/tmp/lane-mail/KEN-5"
}

# A relayed banner on the overseer's screen and an account judgement that
# keeps failing: the long pass acts on nothing, so the mail pass holds
# nothing either, and the lane's notice is reported.
unjudged_wall() {
  relayed_banner_case walled_unjudged_mail
  printf '2\n' > "$STUB_DIR/succeed.check-rc"
  printf 'Rebased.\n' > "$TMP_ROOT/unjudged-notice.txt"
  (cd "$CASE_REPO_ROOT" && "$REAL_LANE_MAIL" notice --item KEN-5 --file "$TMP_ROOT/unjudged-notice.txt" >/dev/null)
  run TMUX_PANE="$PANE" ORCH_OVERSEER_DEAD_PASSES=3 -- --max-loops 1 --item KEN-5
  UNJUDGED="notice=$(grep -c '^EVENT lane-notice KEN-5 ' <<<"$OUT" || true)"
}
unjudged_wall
assert_eq "$UNJUDGED" "notice=1" "a wall no judgement could be made on holds no mail, as it starts no successor" "$ERR"

# A mail pass judges the relayed wall below its mark; the long pass forked
# after it judges afresh, and reports the context mark its own reading finds.
memo_after_mail() {
  relayed_banner_case walled_memo_after_mail
  check_switch_after_first "$MARK_LINE"
  run TMUX_PANE="$PANE" ORCH_OVERSEER_DEAD_PASSES=3 -- --max-loops 1
}
memo_after_mail
assert_eq "marks=$(marks_seen)" "marks=1" \
  "a long pass after a mail pass's judgement takes its own reading and reports the mark it finds" "$ERR"

# One unchanged banner over three mail passes and one long pass in a run whose
# next long pass is an hour away: the mail pass judges it once, the long pass
# once, and every mail pass after reuses the mail pass's answer. On the
# machine's own clock, since the mail passes need time to pass: the pinned
# clock the walled fixture sets is for a recovery's reset, which a relayed
# banner never reaches.
banner_judged() {
  relayed_banner_case walled_judged_once
  rm -f -- "${STUB_DIR:?}/now.epoch"
  run TMUX_PANE="$PANE" ORCH_OVERSEER_DEAD_PASSES=3 ORCH_WATCH_MAIL_INTERVAL=1 NOTE_AT=3 \
    OVERSEE_WATCH_LANE_MAIL="$TMP_ROOT/bin/lane-mail-note-at.sh" REAL_LANE_MAIL="$REAL_LANE_MAIL" \
    -- --max-loops 2 --interval 3600 --item KEN-5
  JUDGED="$(succeed_calls --check-marks)"
}
banner_judged
assert_eq "judged=$JUDGED" "judged=2" \
  "a standing banner is judged once by the mail passes and once by the long pass" "$ERR"


# A relayed banner refuted, then the overseer's own account walls under a
# different banner inside the same interval: the new banner is judged afresh
# rather than taken for the refuted one, so the note sent between the two is
# left for a live overseer. The first capture carries the relayed banner and
# every later one the new wall; the judgement answers room once, then the
# mark. The note lands right after the first mail pass reads the mailbox.
cat > "$TMP_ROOT/bin/lane-mail-note-after.sh" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-} ${2:-} ${3:-}" == "inbox --item overseer" && ! -e "$STUB_DIR/noted" ]]; then
  rc=0
  "$REAL_LANE_MAIL" "$@" || rc=$?
  touch "$STUB_DIR/noted"
  printf 'Sent between the two banners.\n' > "$STUB_DIR/between.txt"
  "$REAL_LANE_MAIL" send --item overseer --directive --file "$STUB_DIR/between.txt" >/dev/null
  exit "$rc"
fi
exec "$REAL_LANE_MAIL" "$@"
EOF
chmod +x "$TMP_ROOT/bin/lane-mail-note-after.sh"
banner_changes() {
  relayed_banner_case walled_banner_changes
  printf '%b\n' '⏺ Watching the fleet.' "$WALL_BANNER" '\xe2\x9d\xaf\xc2\xa0' > "$STUB_DIR/pane-$PANE.1.txt"
  printf '%b\n' '⏺ Watching the fleet.' "${WALL_BANNER/9:50am/11:50am}" '\xe2\x9d\xaf\xc2\xa0' > "$STUB_DIR/pane-$PANE.txt"
  check_switch_after_first "$WALL_MARK_LINE"
  run TMUX_PANE="$PANE" ORCH_OVERSEER_DEAD_PASSES=3 \
    OVERSEE_WATCH_LANE_MAIL="$TMP_ROOT/bin/lane-mail-note-after.sh" REAL_LANE_MAIL="$REAL_LANE_MAIL" \
    -- --max-loops 1 --interval 3600
  CHANGED="events=$(grep -c '^EVENT owner-note' <<<"$OUT" || true) cursor=$(mail_cursor_count) judged=$(succeed_calls --check-marks)"
}
banner_changes
assert_eq "$CHANGED" "events=0 cursor=0 judged=3" \
  "a new banner within the interval is judged afresh, and the note it walls is left unread" "$ERR"


# The overseer's pane cannot be read while a long pass is in flight, as when
# that pass's succession has just closed it: the mail waits for the pass to
# end. The long pass holds its pr-watch open until a mail pass drains under
# it, or three seconds pass, so a mail pass that ran is seen and one held is
# not waited on forever.
cat > "$TMP_ROOT/bin/pr-watch-hold.sh" <<'EOF'
#!/usr/bin/env bash
printf 'long start\n' >> "$STUB_DIR/order.log"
waited=0
until awk '$0 == "long start" { on = 1; next } on && /^drain/ { found = 1 } END { exit !found }' "$STUB_DIR/order.log" \
  || [[ "$waited" -ge 30 ]]; do
  waited=$((waited + 1)); sleep 0.1
done
printf 'long end\n' >> "$STUB_DIR/order.log"
EOF
chmod +x "$TMP_ROOT/bin/pr-watch-hold.sh"
pane_gone_in_flight() {
  overseer_case pane_gone_in_flight idle
  state_with "$LINE"
  # A repeat pass, which records no launch line, so the window read that fails
  # is the pane reading's own.
  touch "$STUB_DIR/window-id-fail-$PANE" "$STUB_DIR/repeat-child"
  rm -rf -- "${CASE_REPO_ROOT:?}/tmp/lane-mail"
  mkdir -p "$CASE_REPO_ROOT/tmp/lane-mail/KEN-5"
  : > "$STUB_DIR/order.log"
  run TMUX_PANE="$PANE" ORCH_WATCH_MAIL_INTERVAL=1 \
    OVERSEE_WATCH_PR_WATCH="$TMP_ROOT/bin/pr-watch-hold.sh" \
    OVERSEE_WATCH_LANE_MAIL="$TMP_ROOT/bin/lane-mail-order.sh" REAL_LANE_MAIL="$REAL_LANE_MAIL" \
    -- --max-loops 1 --item KEN-5
  IN_FLIGHT="$(awk '$0 == "long start" { on = 1; next } $0 == "long end" { on = 0 } on && /^drain/ { n++ } END { print n + 0 }' "$STUB_DIR/order.log")"
  LONGS="$(grep -c '^long end$' "$STUB_DIR/order.log" || :)"
}
pane_gone_in_flight
assert_eq "longs=$LONGS drains-in-flight=$IN_FLIGHT" "longs=1 drains-in-flight=0" \
  "an unreadable overseer pane holds the mail while a long pass is in flight" "$ERR"


# Rejudge an unchanged banner to prove the existing count assertion rejects it.
BANNER_CTL="$(mutant_scripts banner-ctl/orch oversee-watch)" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/banner-ctl/github"
mutate_file "$BANNER_CTL/oversee-watch" '    OV_WALL_BANNER="$banner"' '    OV_WALL_BANNER=""'
CONTROL_RC=0
( PASS=0 FAIL=0; WATCH_BIN="$BANNER_CTL/oversee-watch" banner_judged
  assert_eq "judged=$JUDGED" "judged=2" 'standing banner judgement oracle' "$ERR"
  [[ "$FAIL" == 0 ]] ) > "$TMP_ROOT/banner-control.log" || CONTROL_RC=$?
assert_eq "$CONTROL_RC" 1 'control: repeated banner judgements turn the count assertion red'

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
