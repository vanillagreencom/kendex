#!/usr/bin/env bash
# Surface: session-rows controller identity when TMUX_PANE is absent.
# Inputs: hooks/lane-mail-check.sh, hooks/session-start-row.sh,
# hooks/tests/lib/lane-mail-world.sh, hooks/tests/lib/first-line.sh,
# skills/orch/tests/lib/tier-model-path.sh, skills/orch/scripts/,
# skills/mailbox/scripts/.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/lane-mail-world.sh"

# Hand-launched Claude processes can inherit TMUX without TMUX_PANE. The
# registered controller supplies the missing pane, never tmux's active pane.
while IFS='|' read -r shape; do
  [ -z "${1:-}" ] || [ "$shape" = "$1" ] || continue
  if [ "$shape" = lane ]; then
    new_lane missing-pane-lane ken-pane1
    CALL_ENV=("HOME=$LANE/user-home" "PATH=$TMUX_BIN:$PATH" TMUX=fake
      "TMUX_SERVER_ID=$OVERSEER_SERVER" "TMUX_SERVER_START=$OVERSEER_SERVER_START")
    send KEN-PANE1 'a directive for the existing lane' >/dev/null
    ARM_ARGS=()
    stop
    expect 2 lane-mail-check:\ unread=1 'a launched lane without TMUX_PANE still receives its mail'
    continue
  fi
  new_overseer "pane-$shape"
  mkdir -p "$LANE/tmp/lane-mail/overseer"
  bind_overseer claude "$OVERSEER_HOME_DIR" s1
  overseer_transcript
  wake_row_process_table
  CALL_ENV=("HOME=$LANE/user-home" "PATH=$TMUX_BIN:$PATH" TMUX=fake
    "TMUX_PANE_PID=$OVERSEER_SERVER"
    "TMUX_SERVER_ID=$OVERSEER_SERVER" "TMUX_SERVER_START=$OVERSEER_SERVER_START"
    "CLAUDE_CONFIG_DIR=$OVERSEER_HOME_DIR")
  [ "$shape" != present ] || CALL_ENV+=("TMUX_PANE=$OVERSEER_PANE")
  case "$shape" in
    foreign) bind_overseer claude "$OVERSEER_HOME_DIR" other ;;
    restarted) CALL_ENV+=(TMUX_SERVER_START=1790000001) ;;
    absent) (cd "$LANE" && "$REPO_ROOT/skills/orch/scripts/workflow-state" set oversee overseer null >/dev/null) ;;
    stop-first) (cd "$LANE" && "$REPO_ROOT/skills/orch/scripts/workflow-state" set oversee overseer null >/dev/null) ;;
    nonrepo)
      (cd "$LANE" && "$REPO_ROOT/skills/orch/scripts/workflow-state" set oversee overseer null >/dev/null)
      mv "$LANE/.git" "$LANE/git.saved"
      mv "$LANE/tmp/lane-mail" "$LANE/mail.saved"
      ;;
  esac
  ARM_ARGS=(row SessionStart)
  [ "$shape" != stop-first ] || ARM_ARGS=()
  run_payload "$(jq -nc --arg p "$TRANSCRIPT" '{session_id:"s1",hook_event_name:"SessionStart",transcript_path:$p}')"
  ROWS="$LANE/tmp/lane-mail/overseer/session-$OVERSEER_SERVER-${OVERSEER_PANE#%}.jsonl"
  case "$shape" in
    present | recorded)
      got=absent
      [ ! -f "$ROWS" ] || got=$(jq -r '[.event,.session_id] | join(":")' "$ROWS")
      assert_eq "$got" SessionStart:s1 "$shape: row uses the controller pane"
      ARM_ARGS=()
      judge_says "$CONTEXT_MARK_LINE"
      stop_at "$TRANSCRIPT" false
      expect 2 lane-mail-check:\ context=612000 "$shape: Stop judges the mark"
      before=$(judge_calls)
      stop_at "$TRANSCRIPT" true
      expect 2 lane-mail-check:\ context=612000 "$shape: next Stop still judges the mark"
      assert_eq "$(judge_calls)" "$((before + 1))" "$shape: judgement repeats every turn"
      ARM_ARGS=(deliver)
      stop_at "$TRANSCRIPT" false
      assert_eq "$(context_line)" 'PostToolUse lane-mail-check: context=600000' \
        "$shape: tool judgement uses the same recovered pane"
      ;;
    *)
      # Claude consumes systemMessage on every event, including Stop; the
      # machine envelope, rather than its person-facing wording, is pinned.
      notice=$(jq -r 'has("systemMessage")' "$TMP_ROOT/stdout" 2>/dev/null || echo absent)
      assert_eq "RC=$RC key=$(first_line) notice=$notice" 'RC=0 key=- notice=true' \
        "$shape: first row visibly reports unjudged identity"
      ARM_ARGS=()
      stop_at "$TRANSCRIPT" false
      assert_eq "RC=$RC stdout=$(cat "$TMP_ROOT/stdout") rows=$([ -f "$ROWS" ] && echo present || echo absent)" \
        'RC=0 stdout= rows=absent' "$shape: Stop does not repeat the row notice or write another session"
      # A failed first resolution must not suppress a later controller bind.
      if [ "$shape" = nonrepo ]; then
        mv "$LANE/git.saved" "$LANE/.git"
        mv "$LANE/mail.saved" "$LANE/tmp/lane-mail"
      fi
      record_overseer "$OVERSEER_PANE" "$OVERSEER_SERVER"
      bind_overseer claude "$OVERSEER_HOME_DIR" s1
      CALL_ENV+=("TMUX_SERVER_START=$OVERSEER_SERVER_START")
      judge_says "$CONTEXT_MARK_LINE"
      stop_at "$TRANSCRIPT" false
      expect 2 lane-mail-check:\ context=612000 "$shape: later identity recovery restores judgement"
      ;;
  esac
done <<'ROWS'
recorded
lane
foreign
restarted
absent
stop-first
nonrepo
present
ROWS

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
