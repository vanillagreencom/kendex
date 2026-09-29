# shellcheck shell=bash
# The overseer world the watch suites about the OVERSEER's own session share:
# its pane %9 and window @7, the oversee-succeed stub the watch calls, a case
# builder whose pane reads one state, and the run wrapper. Sourced after
# lib/oversee-watch-harness.sh, whose TMP_ROOT, STUB_DIR, new_case and
# run_watch it uses; defines no assertion.
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
      || { echo "oversee-succeed: harness-unnamed pane=$2" >&2; exit 1; }
    if [[ -f "$STUB_DIR/succeed.then-dead" ]]; then
      printf 'bash\n' > "$STUB_DIR/cmd-${TMUX_PANE}.txt"
      printf 'dev@host ~/kendex $\n' > "$STUB_DIR/pane-${TMUX_PANE}.txt"
      rm -- "$STUB_DIR/succeed.then-dead"
    fi
    if [[ -f "$STUB_DIR/succeed.line" ]]; then cat "$STUB_DIR/succeed.line"
    else echo "claude -n overseer 'brief'"; fi
    [[ ! -f "$STUB_DIR/succeed.print-notice" ]] || echo "oversee-succeed: record-unread pane=${TMUX_PANE:-none}" >&2
    exit 0 ;;
  --check-marks)
    # oversee-succeed needs explicit identity for a node pane with no context
    # record. The fixture also rejects launch-only arguments on this call.
    if [[ -f "$STUB_DIR/succeed.require-harness" && "$*" != '--check-marks --harness codex' ]]; then
      echo "oversee-succeed: harness-unnamed pane=${TMUX_PANE:-none}" >&2
      exit 1
    fi
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
    else echo "oversee-succeed: account-below-mark headroom=80"; fi
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
    # The same wall on a codex overseer: its banner below the last turn, its
    # composer under it.
    walled_codex) printf 'codex\n' > "$STUB_DIR/cmd-$PANE.txt"
            printf '%b\n' '\xe2\x80\xba pick the round back up' '\xe2\x80\xa2 Ran 3 commands' "$CODEX_WALL_BANNER" "$CODEX_COMPOSER" > "$STUB_DIR/pane-$PANE.txt"
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

# wall_confirmed — the account judgement that confirms a wall on this pane:
# the screen alone cannot tell the overseer's own wall from a banner it
# relayed about a lane, so every walled case that expects a recovery sets it.
wall_confirmed() { printf '%s\n' "$WALL_MARK_LINE" > "$STUB_DIR/succeed.check"; }
# recorded FIELD — the overseer record the fleet state now holds.
recorded() { jq -r ".overseer.$1 // \"none\"" "$STUB_DIR/oversee-state.json"; }
# state_with LINE — a fleet state already naming this pane, its window and LINE,
# bound to the start of the stub's server, 1790000000, as every tmux record a
# launch, a watch start or `oversee register` writes is.
state_with() { # LINE
  jq -n --arg server "7000" --arg pane "$PANE" --arg window "$WINDOW" --arg line "$1" \
    '{triaged: [], overseer: {server: $server, pane: $pane, window: $window, launch_line: $line,
      server_start: 1790000000}}' \
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
  local f="$CASE_REPO_ROOT/tmp/lane-mail/overseer/to-lane.cursor"
  [[ -s "$f" ]] && cat -- "$f" || echo 0
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

# The real lane-mail, which the stubs below hand every call to.
REAL_LANE_MAIL="$REPO_ROOT/skills/orch/scripts/lane-mail"
# A lane-mail that lands a notice in KEN-5's mailbox on its NOTE_AT-th drain,
# so a run under an unchanging overseer screen ends on that lane's news.
cat > "$TMP_ROOT/bin/lane-mail-note-at.sh" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == drain ]]; then
  printf 'drain\n' >> "$STUB_DIR/drains.log"
  if [[ "$(grep -c . "$STUB_DIR/drains.log")" -eq "${NOTE_AT:-0}" ]]; then
    printf 'Rebased.\n' > "$STUB_DIR/note-at.txt"
    "$REAL_LANE_MAIL" notice --item KEN-5 --file "$STUB_DIR/note-at.txt" >/dev/null
  fi
fi
exec "$REAL_LANE_MAIL" "$@"
EOF
chmod +x "$TMP_ROOT/bin/lane-mail-note-at.sh"
