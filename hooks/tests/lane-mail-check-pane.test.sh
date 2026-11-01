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
  if [ -n "${SESSION_ROWS_LIB_VARIANT:-}" ]; then
    hole_install lib/session-rows.sh "$LANE/.claude/skills/orch/scripts"
    cp -- "$SESSION_ROWS_LIB_VARIANT" "$LANE/.claude/skills/orch/scripts/lib/session-rows.sh"
  fi
  mkdir -p "$LANE/tmp/lane-mail/overseer"
  bind_overseer claude "$OVERSEER_HOME_DIR" s1
  overseer_transcript
  wake_row_process_table
  CALL_ENV=("HOME=$LANE/user-home" "PATH=$TMUX_BIN:$PATH" TMUX=fake
    "TMUX_PANE_PID=$OVERSEER_SERVER"
    "TMUX_SERVER_ID=$OVERSEER_SERVER" "TMUX_SERVER_START=$OVERSEER_SERVER_START"
    "CLAUDE_CONFIG_DIR=$OVERSEER_HOME_DIR")
  case "$shape" in
    codex-*)
      install_hook "$HOOK" "$LANE/.codex/hooks/lane-mail-check.sh"
      bind_overseer codex "$OVERSEER_HOME_DIR" other
      CALL_ENV+=("CODEX_HOME=$OVERSEER_HOME_DIR")
      ;;
    copilot-*)
      install_hook "$HOOK" "$LANE/.github/hooks/lane-mail-check.sh"
      bind_overseer copilot "$OVERSEER_HOME_DIR" s1
      CALL_ENV+=("COPILOT_HOME=$OVERSEER_HOME_DIR")
      ARM_ARGS=(start)
      run_payload '{"sessionId":"s1","timestamp":1}'
      ;;
  esac
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
    private-env)
      bind_overseer claude "$OVERSEER_HOME_DIR" other
      printf '[env]\nKENDEX_ENV_FILE = "marker.sh"\n' > "$LANE/kendex.settings.toml"
      printf 'printf executed > "%s"\n' "$LANE/env-executed" > "$LANE/marker.sh"
      git -C "$LANE" add kendex.settings.toml marker.sh
      install_hook "$TEST_DIR/../session-start-row.sh" "$LANE/.claude/hooks/session-start-row.sh"
      ;;
  esac
  ARM_ARGS=(row SessionStart)
  [ "$shape" != stop-first ] || ARM_ARGS=()
  case "$shape" in
    codex-stop) ARM_ARGS=() ;;
    codex-halt) ARM_ARGS=(halt) ;;
    codex-deliver) ARM_ARGS=(deliver) ;;
    private-env) ARM_ARGS=() ;;
    copilot-*)
      consumer=usage
      case "$shape" in *compact*) consumer=compact ;; esac
      case "$shape" in *foreign) bind_overseer copilot "$OVERSEER_HOME_DIR" other ;; esac
      ARM_ARGS=("$consumer")
      payload=$(jq -nc --arg cwd "$LANE" '{session_id:"s1",cwd:$cwd,current_tokens:199000,token_limit:272000,trigger:"auto"}')
      run_payload "$payload"
      if [[ "$shape" = *foreign ]]; then
        expect 2 lane-mail-check:\ session-unjudged=missing-pane "$shape: missing identity reports the gap"
        assert_eq "$(cat "$TMP_ROOT/stdout")" '' "$shape: the notification has no stdout"
        assert_eq "$([ -e "$LANE/user-home/.cache/lane-mail/unjudged/copilot-s1" ] && echo cached || echo absent)" absent \
          "$shape: a discarded SDK notification is never cached"
        run_payload "$payload"
        expect 2 lane-mail-check:\ session-unjudged=missing-pane "$shape: the next reading still reports the gap"
        bind_overseer copilot "$OVERSEER_HOME_DIR" s1
        run_payload "$payload"
      fi
      expect 0 - "$shape: recovered identity records the notification"
      file=context.json
      expected='s1:7000 %9:199000'
      [ "$consumer" != compact ] || { file=compaction.json; expected='s1:7000 %9:auto'; }
      assert_eq "$(cat "$TMP_ROOT/stdout")" '' "$shape: successful notification has no stdout"
      assert_eq "$(jq -r '[.session_id,.pane_key,(.tokens // .trigger | tostring)] | join(":")' "$LANE/tmp/lane-mail/overseer/$file" 2>/dev/null || echo absent)" \
        "$expected" "$shape: notification uses the controller pane and native id"
      continue
      ;;
  esac
  run_payload "$(jq -nc --arg p "$TRANSCRIPT" '{session_id:"s1",hook_event_name:"SessionStart",transcript_path:$p}')"
  if [ "$shape" = private-env ]; then
    assert_eq "$([ -e "$LANE/env-executed" ] && echo executed || echo absent)" absent \
      'private-env: missing-pane SessionStart never sources checkout shell'
    continue
  fi
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
      # The common warning field must contain visible content; its wording
      # is for the person and stays unpinned.
      notice=$(jq -r '.systemMessage | if type == "string" then test("\\S") else false end' "$TMP_ROOT/stdout" 2>/dev/null || echo absent)
      assert_eq "RC=$RC key=$(first_line) notice=$notice" 'RC=0 key=- notice=true' \
        "$shape: first row visibly reports unjudged identity"
      ARM_ARGS=()
      stop_at "$TRANSCRIPT" false
      assert_eq "RC=$RC stdout=$(cat "$TMP_ROOT/stdout") rows=$([ -f "$ROWS" ] && echo present || echo absent)" \
        'RC=0 stdout= rows=absent' "$shape: Stop does not repeat the row notice or write another session"
      case "$shape" in codex-*) continue ;; esac
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
private-env
codex-row
codex-stop
codex-halt
codex-deliver
copilot-usage
copilot-usage-foreign
copilot-compact
copilot-compact-foreign
ROWS

# One mutation per unit: the hook, and the session-rows library it sources.
if [ -z "${HOOK_UNDER_TEST:-}" ] && [ -z "${SESSION_ROWS_LIB_VARIANT:-}" ] &&
    { [ -z "${1:-}" ] || [ "${1:-}" = --controls ]; }; then
  while IFS='|' read -r kind shape label; do
    [ -z "${2:-}" ] || [ "$kind" = "$2" ] || continue
    case "$kind" in
      carrier)
        assert_eq "$(grep -Fc 'if [ "$HARNESS" = claude ] || [ "$HARNESS" = codex ]; then' "$HOOK")" 1 \
          'carrier: mutation matches once'
        mutant pane-carrier -e 's@ || \[ "\$HARNESS" = codex \]@@'
        ;;
      private-env)
        assert_eq "$(grep -Fc ' --no-private-env get oversee ' "$REPO_ROOT/skills/orch/scripts/lib/session-rows.sh")" 1 \
          'private-env: mutation matches once'
        MUTANT_SOURCE="$REPO_ROOT/skills/orch/scripts/lib/session-rows.sh" mutant pane-private-env \
          -e 's@ --no-private-env get oversee @ get oversee @'
        ;;
    esac
    control_rc=0
    if [ "$kind" = private-env ]; then
      SESSION_ROWS_LIB_VARIANT="$MUTANT_PATH" "$BASH" "${BASH_SOURCE[0]}" "$shape" > "$TMP_ROOT/control.log" 2>&1 || control_rc=$?
    else
      HOOK_UNDER_TEST="$MUTANT_PATH" "$BASH" "${BASH_SOURCE[0]}" "$shape" > "$TMP_ROOT/control.log" 2>&1 || control_rc=$?
    fi
    assert_eq "$control_rc" 1 "$kind: control rejects the planted defect"
    assert_eq "$(grep -Fxc "  FAIL  $label" "$TMP_ROOT/control.log" || :)" 1 \
      "$kind: control reaches its contract assertion"
  done <<'CONTROLS'
carrier|codex-row|codex-row: first row visibly reports unjudged identity
private-env|private-env|private-env: missing-pane SessionStart never sources checkout shell
CONTROLS
fi

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
