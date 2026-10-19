#!/usr/bin/env bash
# Tests for oversee-watch's overseer gap contract.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

# shellcheck source=lib/oversee-watch-harness.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/oversee-watch-harness.sh"
# mutant_scripts and mutate_file, the two halves of the control below.
# shellcheck source=lib/growth-state.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/growth-state.sh"
# The pane, the oversee-succeed stub, overseer_case and run.
# shellcheck source=lib/overseer-watch-case.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/overseer-watch-case.sh"

source "$(dirname "${BASH_SOURCE[0]}")/lib/overseer-row-world.sh"

# --- a gap the overseer does not close goes to the owner --------------------
# The first long pass a gap stands on tells the overseer; the next, it goes to
# the owner once, as a notice and a fleet-log row, and neither repeats while
# that gap stands. A notice the owner did not get is sent again the next
# pass, and a reading between two passes of the same gap starts it again.
# The owner notices the overseer mailbox holds naming the gap alert.
owner_alerts() {
  local file="$CASE_REPO_ROOT/tmp/lane-mail/overseer/to-overseer.jsonl"
  [[ -f "$file" ]] || { echo 0; return; }
  jq -r 'select(.to == "owner") | .text' "$file" | grep -c 'overseer-context-unmeasured: the overseer in pane' || true
}
# The fleet-log rows naming the gap alert.
fleet_alerts() {
  jq '(.fleet_log // []) | map(select(.item == "overseer" and (.text // "" | contains("has recorded no context reading on two consecutive watch passes")))) | length' \
    "$STUB_DIR/oversee-state.json"
}
# A lane-mail whose `notice --to owner` fails while STUB_DIR/owner-fails
# stands, as it does where the overseer mailbox cannot be written, and which
# hands every other call to the real one.
cat > "$TMP_ROOT/bin/lane-mail-owner-fails.sh" <<'STUB'
#!/usr/bin/env bash
if [[ -e "$STUB_DIR/owner-fails" && " $* " == *" --to owner "* ]]; then
  echo "lane-mail: mailbox-unwritable item=overseer" >&2
  exit 1
fi
exec "$REAL_LANE_MAIL" "$@"
STUB
chmod +x "$TMP_ROOT/bin/lane-mail-owner-fails.sh"
# gap_seq NAME STEP... [WATCH_BIN via env] — the home-unnamed gap on the first
# long pass, then one long pass per STEP over the record it writes: `gap` the
# same gap, `failing` the same gap with the owner's notice failing, `reading`
# a reading below the mark, `aged` the same gap with every owner notice
# restamped 210 seconds before its own stamp, on whatever clock the watch
# reads: past lane-mail's minute rule and inside its 24-hour text rule, as a
# gap reopened later in the day finds it. GAP_SEQ is
# one word per pass: `event` for the
# overseer-context-unmeasured event, `alerted` for the owner's alert,
# `failed` for an owner's notice that failed, `none` for none of them; then
# the owner's notices and the fleet log's alert rows.
gap_seq() { # NAME STEP...
  local name="$1" step words="" word mailbox
  shift
  CTX_KEY="7000 $PANE" context_case "$name" blank -60 0 home-unnamed "$START"
  for step in first "$@"; do
    if [[ "$step" != first ]]; then
      rm -f -- "${STUB_DIR:?}/owner-fails"
      case "$step" in
        gap) ctx_record "$(iso "$((ROW_AT - 60))")" home-unnamed ;;
        failing) ctx_record "$(iso "$((ROW_AT - 60))")" home-unnamed; : > "$STUB_DIR/owner-fails" ;;
        reading) ctx_record "$(iso "$((ROW_AT - 60))")" - ;;
        aged)
          ctx_record "$(iso "$((ROW_AT - 60))")" home-unnamed
          mailbox="$CASE_REPO_ROOT/tmp/lane-mail/overseer/to-overseer.jsonl"
          jq -c 'if .to == "owner" then .at = ((.at | fromdateiso8601) - 210 | todate) else . end' "$mailbox" > "$mailbox.aged"
          mv -- "$mailbox.aged" "$mailbox" ;;
        *) echo "gap_seq: unknown step $step" >&2; exit 1 ;;
      esac
      run TMUX_PANE="$PANE" OVERSEE_WATCH_LANE_MAIL="$TMP_ROOT/bin/lane-mail-owner-fails.sh" \
        REAL_LANE_MAIL="$REAL_LANE_MAIL" -- --max-loops 1
    fi
    word=""
    ! grep -q "^EVENT overseer-context-unmeasured $PANE gap=home-unnamed$" <<<"$OUT" || word+="event"
    ! grep -q "^oversee-watch: overseer-context-alerted pane=$PANE gap=home-unnamed" "$ERR" || word+="alerted"
    ! grep -q '^oversee-watch: overseer-notice-failed channel=owner' "$ERR" || word+="failed"
    words+="${word:-none} "
  done
  GAP_SEQ="${words}owner=$(owner_alerts) fleet=$(fleet_alerts)"
}
gap_seq context_gap_alert gap gap
assert_eq "$GAP_SEQ" "event alerted none owner=1 fleet=1" \
  "a gap still standing on the second long pass goes to the owner once, and neither repeats" "$ERR"
gap_seq context_gap_owner_fails failing gap gap
assert_eq "$GAP_SEQ" "event failed alerted none owner=1 fleet=1" \
  "an owner's notice that failed is sent again the next pass, with one fleet-log row" "$ERR"
gap_seq context_gap_reopened gap reading gap
assert_eq "$GAP_SEQ" "event alerted none event owner=1 fleet=1" \
  "a reading between two passes of the same gap tells the overseer again" "$ERR"
# The reopened gap's alert repeats words the owner holds: lane-mail refuses
# it, the alert stands as sent and the fleet log records it, never a failure
# noted on every pass.
GAP_HELD_WANT="event alerted none event alerted owner=1 fleet=2"
gap_seq context_gap_held gap reading gap aged
assert_eq "$GAP_SEQ" "$GAP_HELD_WANT" \
  "a reopened gap's alert the owner already holds stands as sent, with its fleet-log row" "$ERR"

# --- control ----------------------------------------------------------------
# The held alert read as any failed notice: the reopened gap's row turns red.
HELD_SCRIPTS="$(mutant_scripts mutant-held/orch oversee-watch)" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/mutant-held/github"
mutate_file "$HELD_SCRIPTS/oversee-watch" '    "lane-mail: owner-notice-repeated="*) return 0 ;;' '    "lane-mail: owner-notice-repeated="*) overseer_note overseer-notice-failed "channel=owner"; return 1 ;;'
WATCH_BIN="$HELD_SCRIPTS/oversee-watch" gap_seq context_gap_held_mutant gap reading gap aged
assert_eq "$([[ "$GAP_SEQ" != "$GAP_HELD_WANT" ]] && echo red)" "red" \
  "control: reading the held alert as a failure turns the reopened gap's row red" "$ERR"
# The told arm dropped: a standing gap is the event on every pass and the
# owner is never told.
GAPTOLD_CTL="$(mutant_scripts gaptold-ctl/orch oversee-watch)" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/gaptold-ctl/github"
mutate_file "$GAPTOLD_CTL/oversee-watch" '    "$gap|told")' '    "$gap|never")'
WATCH_BIN="$GAPTOLD_CTL/oversee-watch" gap_seq context_gap_alert_mutant gap gap
assert_eq "$GAP_SEQ" "event event event owner=0 fleet=0" \
  "control: without the told arm the gap repeats as an event every pass and never reaches the owner" "$ERR"
# The failed alert's hold on the row dropped: an owner's notice that failed
# is taken as sent and never tried again.
GAPRETRY_CTL="$(mutant_scripts gapretry-ctl/orch oversee-watch)" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/gapretry-ctl/github"
mutate_file "$GAPRETRY_CTL/oversee-watch" '      overseer_gap_alert "$pane" "$gap" || return 0' '      overseer_gap_alert "$pane" "$gap" || :'
WATCH_BIN="$GAPRETRY_CTL/oversee-watch" gap_seq context_gap_owner_fails_mutant failing gap gap
assert_eq "$GAP_SEQ" "event failed none none owner=0 fleet=0" \
  "control: without the hold a failed owner's notice is never sent again" "$ERR"
# The reading's clear dropped: a gap back after a reading stays alerted and
# the overseer is never told again.
GAPCLEAR_CTL="$(mutant_scripts gapclear-ctl/orch oversee-watch)" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/gapclear-ctl/github"
mutate_file "$GAPCLEAR_CTL/oversee-watch" \
  '  OVERSEER_MARK_ROWS="$(lane_row_clear overseer-context-gap "$OVERSEER_MARK_ROWS" "$identity")"' '  :'
WATCH_BIN="$GAPCLEAR_CTL/oversee-watch" gap_seq context_gap_reopened_mutant gap reading gap
assert_eq "$GAP_SEQ" "event alerted none none owner=1 fleet=1" \
  "control: without the reading's clear a gap back after a reading is never told again" "$ERR"


printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
