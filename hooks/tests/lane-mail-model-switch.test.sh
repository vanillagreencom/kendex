#!/usr/bin/env bash
# Surface: lane-mail-model-switch delivery and lane-mail-check handoff_check.
# Inputs: hooks/lane-mail-check.sh hooks/lane-mail-model-switch.sh skills/orch/scripts/** skills/mailbox/scripts/** skills/github/scripts/lib/** hooks/tests/lib/lane-mail-world.sh hooks/tests/lib/first-line.sh
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/lane-mail-world.sh"
. "$REPO_ROOT/skills/orch/scripts/lib/lane-state.sh"
COMPANION="${COMPANION_UNDER_TEST:-$REPO_ROOT/hooks/lane-mail-model-switch.sh}"
OWNED_CHILD=""
OWNED_SOCKET=""
cleanup_model_world() {
  if [[ -n "$OWNED_CHILD" ]]; then kill "$OWNED_CHILD" 2>/dev/null || :; wait "$OWNED_CHILD" 2>/dev/null || :; fi
  [[ -z "$OWNED_SOCKET" ]] || tmux -S "$OWNED_SOCKET" kill-server 2>/dev/null || :
  rm -rf -- "${TMP_ROOT:?}"
}
trap cleanup_model_world EXIT

# Recursive mutant runs use the original detecting assertions, without
# repeating unrelated worlds. An ordinary run still exercises every case.
if [[ -n "${MODEL_CONTROL:-}" ]]; then
  case "${MODEL_CONTROL_CASE:-}" in
    matching|family-alias|no-fleet-record|gui-session|adapter|fresh-shell|complete|extended|conflicting-selector|retired-callback|replaced-before-write|stale-launch|missing-judge|optional-account) ;;
    *) printf 'lane-mail-model-switch.test: control-case=unknown value=%s\n' "${MODEL_CONTROL_CASE:-}" >&2; exit 1 ;;
  esac
fi
model_case() { # NAME
  [[ -z "${MODEL_CONTROL:-}" || "${MODEL_CONTROL_CASE:-}" == "$1" ]]
}

model_world() { # NAME LAUNCHED [broken] [RECORDED FLAGS]
  new_lane "$1" KEN-3916
  install_hook "$COMPANION" "${CASE_HOOK%/*}/lane-mail-model-switch.sh"
  mkdir -p "$LANE/tmp/lane-mail/KEN-3916"
  rm -- "$LANE/.agents/skills/orch/scripts"
  cp -R -- "$REPO_ROOT/skills/orch/scripts" "$LANE/.agents/skills/orch/scripts"
  mkdir -p "$LANE/.agents/skills/github/scripts/lib"
  cp -- "$REPO_ROOT"/skills/github/scripts/lib/*.sh "$LANE/.agents/skills/github/scripts/lib/"
  S="$LANE/.agents/skills/orch/scripts"
  [[ -z "${MODEL_RELAUNCH_UNDER_TEST:-}" ]] || cp -- "$MODEL_RELAUNCH_UNDER_TEST" "$S/lib/lane-relaunch.sh"
  # Capture only the launch dependency. Recovery itself, process identity,
  # stop and workflow writes remain production operations.
  cat >"$S/open-terminal" <<'LAUNCH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "$MODEL_ARGV"
printf '%s\n' done > "$MODEL_DONE"
LAUNCH
  chmod +x "$S/open-terminal"
  mkdir -p "$TMP_ROOT/bin"
  cp -- "$(command -v sleep)" "$TMP_ROOT/bin/claude"
  "$TMP_ROOT/bin/claude" 90 &
  OWNED_CHILD=$!
  START=$(lane_process_start "$OWNED_CHILD")
  "$S/workflow-state" --state-dir "$LANE/tmp" init oversee >/dev/null
  record=$(jq -nc --arg item KEN-3916 --arg model "$2" --arg cwd "$LANE" \
    --arg pid "$OWNED_CHILD" --arg start "$START" --arg account "$OFFLINE_HOME" \
    --arg broken "${3:-}" --arg flags "${4:---dangerously-skip-permissions --model claude-opus-4-8 --effort high}" \
    --argjson server "$OVERSEER_SERVER" '{item:$item,harness:"claude",session_id:"s1",model:$model,
      effort:"high",account:$account,status:"running",tracker:"linear",launched_at:"launch-a",
      launch:{pid:$pid,start:$start,pane:"%1",server:$server},recovery:(if $broken == "broken" then null else
      {cwd:$cwd,flags:$flags,refresh:false,session:"model-test"} end)}')
  "$S/workflow-state" --state-dir "$LANE/tmp" update oversee '.lanes=[$r]' --argjson r "$record" >/dev/null
  CALL_ENV=("MODEL_ARGV=$LANE/tmp/argv" "MODEL_DONE=$LANE/tmp/done" ANTHROPIC_BASE_URL= \
    ANTHROPIC_DEFAULT_FABLE_MODEL= ANTHROPIC_DEFAULT_OPUS_MODEL= ANTHROPIC_DEFAULT_SONNET_MODEL= ANTHROPIC_DEFAULT_HAIKU_MODEL= \
    CLAUDE_CODE_USE_BEDROCK= CLAUDE_CODE_USE_VERTEX= CLAUDE_CODE_USE_FOUNDRY= CLAUDE_CODE_USE_MANTLE= \
    CLAUDE_CODE_USE_ANTHROPIC_AWS= CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST= \
    "PATH=$TMUX_BIN:$PATH" TMUX=fake TMUX_PANE=%1 "TMUX_SERVER_ID=$OVERSEER_SERVER")
}
event() { # MODEL [EXTRA JSON]
  run_payload "$(jq -nc --arg m "$1" --argjson extra "${2:-null}" \
    '{hook_event_name:"PostModelSwitch",session_id:"s1",to_model:$m} + ($extra // {})')"
}
switch_count() { jq '[.fleet_log[]? | select(.kind=="model-switched")] | length' "$LANE/tmp/workflow-state-oversee.json"; }
await_recovery() {
  local until_second=$((SECONDS + 15))
  while [[ ! -f "$LANE/tmp/done" ]]; do
    [[ "$SECONDS" -lt "$until_second" ]] || return 1
    sleep 0.05
  done
}

echo '=== model outcomes ==='
while IFS='|' read -r name launched observed outcome cause override; do
  model_case "$name" || continue
  model_world "$name" "$launched"
  CALL_ENV+=("ANTHROPIC_DEFAULT_SONNET_MODEL=$override")
  before=$(cat "$LANE/tmp/workflow-state-oversee.json")
  event "$observed"
  if [[ "$outcome" == matching ]]; then
    assert_eq "$(cat "$LANE/tmp/workflow-state-oversee.json")" "$before" "$name leaves fleet state unchanged"
    assert_eq "$(lane_process_start "$OWNED_CHILD")" "$START" "$name keeps predecessor running"
  else
    assert_eq "$(jq -r '.lanes[0].model_check.outcome' "$LANE/tmp/workflow-state-oversee.json")" unavailable "$name records unavailable"
    assert_eq "$(jq -r '.lanes[0].model_check.cause' "$LANE/tmp/workflow-state-oversee.json")" "$cause" "$name records its cause"
    assert_eq "$(jq -r '.hookSpecificOutput.hookEventName' "$TMP_ROOT/stdout")" PostModelSwitch "$name reaches model context"
    event "$observed"
    assert_eq "$(jq '[.fleet_log[]?|select(.kind=="model-unavailable")]|length' "$LANE/tmp/workflow-state-oversee.json")" 1 "$name reports once"
    assert_eq "$(cat "$TMP_ROOT/stdout")" '' "$name duplicate has no context notice"
  fi
  kill "$OWNED_CHILD" 2>/dev/null || :
  wait "$OWNED_CHILD" 2>/dev/null || :
  OWNED_CHILD=""
done <<'ROWS'
matching|claude-fable-5-1|claude-fable-5-1|matching|
equivalent|fable-5-1|claude-fable-5-1|matching|
family-alias|fable|claude-fable-5-1|matching|
sonnet-alias|sonnet|claude-sonnet-4-6|matching||claude-sonnet-5-5
opus-alias|opus[1m]|claude-opus-4-8|matching|
haiku-alias|haiku|claude-haiku-5-5|matching|
launch-missing||claude-opus-4-8|unavailable|launch-missing
launch-alias|best|claude-opus-4-8|unavailable|launch-unresolved
observed-missing|claude-fable-5-1||unavailable|observed-unread
ROWS

if model_case no-fleet-record; then
echo '=== unavailable fleet launch record ==='
model_world no-fleet-record claude-fable-5-1
rm -- "$LANE/tmp/workflow-state-oversee.json"
event claude-opus-4-8
assert_eq "$(jq -r '.model_checks.s1.outcome' "$LANE/tmp/workflow-state-KEN-3916.json")" unavailable 'an absent fleet record stays unavailable'
assert_eq "$(jq -r '.model_checks.s1.cause' "$LANE/tmp/workflow-state-KEN-3916.json")" launch-unread 'an absent fleet record names its failed read'
assert_eq "$(jq -r '.hookSpecificOutput.hookEventName' "$TMP_ROOT/stdout")" PostModelSwitch 'missing launch evidence reaches model context'
event claude-opus-4-8
assert_eq "$(cat "$TMP_ROOT/stdout")" '' 'missing fleet record reports once'
assert_eq "$(lane_process_start "$OWNED_CHILD")" "$START" 'unavailable launch evidence changes no process'
kill "$OWNED_CHILD" 2>/dev/null || :; wait "$OWNED_CHILD" 2>/dev/null || :; OWNED_CHILD=""

fi

echo '=== unavailable dependency and association evidence ==='
# The GUI producer records no launch process or native session on first open.
# A missing adapter is an installed dependency failure, not a model match.
for fault in gui gui-session adapter; do
  model_case "$fault" || continue
  model_world "unavailable-$fault" claude-fable-5-1
  if [[ "$fault" == gui || "$fault" == gui-session ]]; then
    "$S/workflow-state" --state-dir "$LANE/tmp" update oversee \
      '.lanes[0].session_id=(if $fault=="gui" then null else "s1" end)
       | .lanes[0].launch=null | .lanes[0].surface="gui"' --arg fault "$fault" >/dev/null
    cause=launch-unbound
  else
    rm -- "$S/lib/adapters/claude.sh"
    cause=adapter-unread
  fi
  "$S/workflow-state" --state-dir "$LANE/tmp" init KEN-3916 >/dev/null
  before=$(jq -c . "$LANE/tmp/workflow-state-oversee.json")
  event claude-opus-4-8
  assert_eq "$(jq -r '.model_checks.s1.cause' "$LANE/tmp/workflow-state-KEN-3916.json")" "$cause" "$fault persists unavailable evidence"
  assert_eq "$(jq -r '.hookSpecificOutput.additionalContext|split("\n")[0]' "$TMP_ROOT/stdout")" "lane-mail-check: model-unavailable=$cause" "$fault delivers the notice to the model"
  if [[ "$fault" == adapter ]]; then
    assert_eq "$(jq -r '.hookSpecificOutput.additionalContext|contains("adapters/claude.sh")' "$TMP_ROOT/stdout")" true 'adapter failure keeps its dependency cause below the key'
  fi
  event claude-opus-4-8
  assert_eq "$(cat "$TMP_ROOT/stdout")" '' "$fault delivers its notice once"
  assert_eq "$(jq -c . "$LANE/tmp/workflow-state-oversee.json")" "$before" "$fault leaves launch evidence unknown"
  assert_eq "$(lane_process_start "$OWNED_CHILD")" "$START" "$fault takes no unverified stop"
  kill "$OWNED_CHILD" 2>/dev/null || :; wait "$OWNED_CHILD" 2>/dev/null || :; OWNED_CHILD=""
done

if [[ -z "${MODEL_CONTROL:-}" ]]; then
  model_world fleet-lock claude-fable-5-1
  mkfifo "$LANE/tmp/release-lock"
  "$BASH" -euo pipefail -c '
    . "$1/lib/file-lock.sh"
    orch_take_lock 200 "$2.lock" 10
    printf held > "$3"
    read -r release < "$4"
  ' _ "$S" "$LANE/tmp/workflow-state-oversee.json" "$LANE/tmp/lock-held" "$LANE/tmp/release-lock" \
    200>"$LANE/tmp/workflow-state-oversee.json.lock" &
  locker=$!
  while [[ ! -f "$LANE/tmp/lock-held" ]]; do sleep 0.05; done
  for delivery in first duplicate; do
    event claude-opus-4-8
    if [[ "$delivery" == first ]]; then
      assert_eq "$(jq -r '.model_checks.s1.cause' "$LANE/tmp/workflow-state-KEN-3916.json")" record-unwritten 'a held fleet lock persists unavailable in item state'
      assert_eq "$(jq -r '.hookSpecificOutput.additionalContext|split("\n")[0]' "$TMP_ROOT/stdout")" 'lane-mail-check: model-unavailable=record-unwritten' 'a held fleet lock delivers model context'
      assert_eq "$(jq -r '.hookSpecificOutput.additionalContext|contains("workflow-state: lock-failed")' "$TMP_ROOT/stdout")" true 'fleet write failure keeps its dependency cause below the key'
    else
      assert_eq "$(cat "$TMP_ROOT/stdout")" '' 'a held fleet lock reports once'
    fi
  done
  printf 'release\n' > "$LANE/tmp/release-lock"
  wait "$locker"
  assert_eq "$(switch_count)" 0 'an unwritten fleet record takes no recovery action'
  assert_eq "$(lane_process_start "$OWNED_CHILD")" "$START" 'an unwritten record keeps the unclaimed process'
  kill "$OWNED_CHILD" 2>/dev/null || :; wait "$OWNED_CHILD" 2>/dev/null || :; OWNED_CHILD=""
fi

if model_case fresh-shell; then
echo '=== detached recovery loads its dependencies ==='
model_world fresh-shell claude-fable-5-1
"$S/workflow-state" --state-dir "$LANE/tmp" update oversee \
  '.lanes[0].model_check={session_id:"s1",outcome:"switched"}' >/dev/null
status=0
env -i "PATH=$TMUX_BIN:$PATH" "HOME=$OFFLINE_HOME" \
  "MODEL_ARGV=$LANE/tmp/argv" "MODEL_DONE=$LANE/tmp/done" \
  "$BASH" "$S/lib/lane-relaunch.sh" model-recovery "$record" "$LANE/tmp" s1 \
  >"$TMP_ROOT/recovery.out" 2>"$ERR_FILE" || status=$?
assert_eq "$status" 0 'fresh-shell recovery completes through its own dependencies'
assert_eq "$(awk '/^--launch-flags$/{getline;print}' "$LANE/tmp/argv" 2>/dev/null || :)" \
  '--dangerously-skip-permissions --model claude-fable-5-1 --effort high' \
  'fresh-shell recovery launches the recorded model, permissions and effort'
state=$(lane_process_state "$OWNED_CHILD")
case "$state" in '' | Z) state=gone ;; esac
assert_eq "$state" gone 'fresh-shell recovery stops its verified predecessor'
assert_eq "$(jq -r '.lanes[0].status' "$LANE/tmp/workflow-state-oversee.json")" stopped \
  'fresh-shell recovery records the predecessor stop'
[[ "$state" == gone ]] || kill "$OWNED_CHILD" 2>/dev/null || :
wait "$OWNED_CHILD" 2>/dev/null || :
OWNED_CHILD=""

fi

if model_case optional-account; then
  echo '=== recovery preserves optional accounts ==='
  while IFS='|' read -r account_case account_mode observed; do
    model_world "$account_case" claude-fable-5-1
    account="$OFFLINE_HOME"
    if [[ "$account_mode" == omitted ]]; then
      account=""
      record=$(jq '.account=null' <<<"$record")
      "$S/workflow-state" --state-dir "$LANE/tmp" update oversee '.lanes=[$r]' --argjson r "$record" >/dev/null
    fi
    before=$(jq -c . "$LANE/tmp/workflow-state-oversee.json")
    if [[ "$observed" == claude-fable-5-1 ]]; then
      event "$observed"
      assert_eq "$(jq -c . "$LANE/tmp/workflow-state-oversee.json")" "$before" "$account_case leaves fleet state unchanged"
      assert_eq "$(lane_process_start "$OWNED_CHILD")" "$START" "$account_case keeps predecessor running"
    else
      # Exercise the installed argument owner and the actual initial parser.
      # Help is last so it cannot conceal an earlier invalid account option.
      SCRIPT_DIR="$S"
      . "$S/lib/lane-launch.sh"
      . "$S/lib/lane-capabilities.sh"
      . "$S/lib/lane-relaunch.sh"
      status=0
      lane_recovery_args "$record" "$account" "$LANE/tmp" "$REPO_ROOT/skills/orch/scripts/open-terminal" model-switched || status=$?
      assert_eq "$status" 0 "$account_case constructs recovery arguments"
      if [[ "$status" == 0 ]]; then
        expected_args=("$REPO_ROOT/skills/orch/scripts/open-terminal" --tmux --relaunch --continue-resume --harness claude
          --launch-flags '--dangerously-skip-permissions --model claude-fable-5-1 --effort high'
          --state-dir "$LANE/tmp" --host local --tracker linear)
        if [[ "$account_mode" == named ]]; then expected_args+=(--lane "$OFFLINE_HOME"); fi
        expected_args+=(KEN-3916)
        assert_eq "$(printf '%s\n' "${LANE_RECOVERY_ARGS[@]}")" "$(printf '%s\n' "${expected_args[@]}")" \
          "$account_case recovery arguments preserve its account option"
        status=0
        "$BASH" "${LANE_RECOVERY_ARGS[@]}" --help >"$TMP_ROOT/parser.out" 2>"$ERR_FILE" || status=$?
        assert_eq "$status" 0 "$account_case passes the real parser before stop"
        assert_eq "$(lane_process_start "$OWNED_CHILD")" "$START" "$account_case parser leaves predecessor running"
        if [[ "$status" == 0 ]]; then
          event "$observed"
          await_recovery || FAIL=$((FAIL + 1))
          assert_eq "$(cat "$LANE/tmp/done")" done "$account_case replacement acknowledges completion"
          assert_eq "$(cat "$LANE/tmp/argv")" "$(printf '%s\n' "${expected_args[@]:1}")" \
            "$account_case replacement keeps account, recorded model, permissions and effort"
          state=$(lane_process_state "$OWNED_CHILD")
          case "$state" in '' | Z) state=gone ;; esac
          assert_eq "$state" gone "$account_case recovery stops its verified predecessor"
          assert_eq "$(jq -r '.lanes[0].status' "$LANE/tmp/workflow-state-oversee.json")" stopped "$account_case records stopped state"
          assert_eq "$(switch_count)" 1 "$account_case records one model switch"
          event "$observed"
          assert_eq "$(switch_count)" 1 "$account_case repeated delivery writes no second switch"
        fi
      fi
    fi
    kill "$OWNED_CHILD" 2>/dev/null || :; wait "$OWNED_CHILD" 2>/dev/null || :; OWNED_CHILD=""
  done <<'ACCOUNTS'
omitted-mismatch|omitted|claude-opus-4-8
named-mismatch|named|claude-opus-4-8
matching-omitted|omitted|claude-fable-5-1
ACCOUNTS
fi

echo '=== recovery validates before stopping ==='
while IFS='|' read -r preparation launched original override expected_model observed; do
  model_case "$preparation" || continue
  model_world "$preparation" "$launched" "$preparation" "--dangerously-skip-permissions $original --effort high"
  CALL_ENV+=("ANTHROPIC_DEFAULT_OPUS_MODEL=$override" "ANTHROPIC_DEFAULT_SONNET_MODEL=$override"
    "ANTHROPIC_DEFAULT_FABLE_MODEL=$override" "ANTHROPIC_DEFAULT_HAIKU_MODEL=$override")
  observed=${observed:-claude-opus-4-8}
  # Existing emergency state must survive an unpushed round.
  "$S/workflow-state" --state-dir "$LANE/tmp" init KEN-3916 >/dev/null
  "$S/workflow-state" --state-dir "$LANE/tmp" update KEN-3916 '.dev_round="unfinished"' >/dev/null
  "$S/workflow-state" --state-dir "$LANE/tmp" update KEN-3916 \
    '.child_sessions={runtime:{status:"active",agent_id:"a1"},retired:{status:"closed",agent_id:"a2"}}' >/dev/null
  "$S/workflow-state" --state-dir "$LANE/tmp" set KEN-3916 handoff \
    '{"remaining":["old"],"merged":["landed"],"open_pr":42,"traps":["standing trap"]}' >/dev/null
  transcript="$LANE/tmp/parent.jsonl"
  mkdir -p "$LANE/tmp/parent/subagents"
  : > "$transcript"
  : > "$LANE/tmp/parent/subagents/agent-a1.jsonl"
  extra=$(jq -nc --arg t "$transcript" --arg p "$preparation" \
    '{stop_hook_active:true,transcript_path:$t} + (if $p == "complete" then
      {background_tasks:[{type:"subagent",id:"a1",status:"running"}]} else {} end)')
  event "$observed" "$extra"
  assert_eq "$(switch_count)" 1 "$preparation switch is recorded"
  if [[ "$(switch_count)" == 1 ]]; then
    if [[ "$preparation" != broken ]]; then
      await_recovery || FAIL=$((FAIL + 1))
      assert_eq "$(awk '/^--launch-flags$/{getline;print}' "$LANE/tmp/argv")" \
        "--dangerously-skip-permissions --model $expected_model --effort high" "$preparation replacement keeps model selectors, permissions and effort"
    else
      deadline=$((SECONDS + 15))
      while ! [[ -f "$LANE/tmp/model-recovery-KEN-3916.log" ]] || \
        ! grep -q '^lane-relaunch: model-recovery=prepare-failed ' "$LANE/tmp/model-recovery-KEN-3916.log"; do
        [[ "$SECONDS" -lt "$deadline" ]] || break
        sleep 0.05
      done
    fi
    state=$(lane_process_state "$OWNED_CHILD")
    case "$state" in '' | Z) state=gone ;; esac
    expected_status=stopped
    if [[ "$preparation" == broken ]]; then
      expected_status=running
      assert_eq "$(lane_process_start "$OWNED_CHILD")" "$START" "$preparation preparation failure keeps predecessor running"
    else
      assert_eq "$state" gone "$preparation predecessor has stopped"
    fi
    [[ "$state" == gone ]] || kill "$OWNED_CHILD" 2>/dev/null || :
    wait "$OWNED_CHILD" 2>/dev/null || :
    OWNED_CHILD=""
    event "$observed"
    assert_eq "$(switch_count)" 1 "$preparation repeated delivery writes no second record"
    assert_eq "$(jq -r '.fleet_log[]|select(.kind=="model-switched")|[.session_id,.launched,.observed,(.at|type)]|join("|")' "$LANE/tmp/workflow-state-oversee.json")" \
      "s1|$launched|$observed|string" "$preparation switch has launch, observation and writer time"
    assert_eq "$(jq -r '.dev_round' "$LANE/tmp/workflow-state-KEN-3916.json")" unfinished "$preparation keeps unfinished round"
    assert_eq "$(jq -c '.handoff | [.remaining,.merged,.open_pr,(.traps|index("standing trap")!=null)]' "$LANE/tmp/workflow-state-KEN-3916.json")" \
      '[["old"],["landed"],42,true]' "$preparation retains standing handoff work"
    assert_eq "$(jq -r '.handoff.traps|any(contains("attached-agent=a1"))' "$LANE/tmp/workflow-state-KEN-3916.json")" true "$preparation records unfinished agent"
    assert_eq "$(jq -r --arg p "$LANE/tmp/parent/subagents/agent-a1.jsonl" '.handoff.traps|any(contains("output="+$p))' "$LANE/tmp/workflow-state-KEN-3916.json")" true "$preparation keeps known agent output"
    assert_eq "$(jq -r '.handoff.traps|any(contains("attached-agent=a2"))' "$LANE/tmp/workflow-state-KEN-3916.json")" false "$preparation omits retired agent"
    assert_eq "$(jq -r '.lanes[0].status' "$LANE/tmp/workflow-state-oversee.json")" "$expected_status" "$preparation remains recoverable"
    if [[ "$preparation" == complete ]]; then
      # Native resume can retain s1. A later process must get its own action
      # and evidence, while a duplicate of launch-a remains suppressed.
      "$TMP_ROOT/bin/claude" 90 &
      OWNED_CHILD=$!
      START=$(lane_process_start "$OWNED_CHILD")
      "$S/workflow-state" --state-dir "$LANE/tmp" update oversee '
        .lanes[0].launch={pid:$pid,start:$start}
        | .lanes[0].launched_at="launch-b" | .lanes[0].status="running"' \
        --arg pid "$OWNED_CHILD" --arg start "$START" >/dev/null
      rm -- "$LANE/tmp/done"
      event claude-opus-4-8
      await_recovery || FAIL=$((FAIL + 1))
      assert_eq "$(switch_count)" 2 'a later launch of the same native session records its switch'
      assert_eq "$(jq -c '[.fleet_log[]|select(.kind=="model-switched")|.launch_identity.launched_at]' "$LANE/tmp/workflow-state-oversee.json")" \
        '["launch-a","launch-b"]' 'each affected launch retains its own evidence'
      state=$(lane_process_state "$OWNED_CHILD")
      case "$state" in '' | Z) state=gone ;; esac
      assert_eq "$state" gone 'a later mismatch stops the resumed predecessor'
      [[ "$state" == gone ]] || kill "$OWNED_CHILD" 2>/dev/null || :
      wait "$OWNED_CHILD" 2>/dev/null || :
      OWNED_CHILD=""
      event claude-opus-4-8
      assert_eq "$(switch_count)" 2 'repeated delivery for the resumed launch acts once'
      # Prune archives old fleet log rows while retaining this lane record.
      "$S/workflow-state" --state-dir "$LANE/tmp" update oversee '.fleet_log=[]' >/dev/null
      before=$(jq -c . "$LANE/tmp/workflow-state-oversee.json")
      event claude-opus-4-8
      assert_eq "$(jq -c . "$LANE/tmp/workflow-state-oversee.json")" "$before" 'archived switch history cannot re-arm the current launch'
    fi
  fi
  if [[ -n "$OWNED_CHILD" ]]; then kill "$OWNED_CHILD" 2>/dev/null || :; wait "$OWNED_CHILD" 2>/dev/null || :; OWNED_CHILD=""; fi
done <<'ROWS'
complete|claude-fable-5-1|--model claude-opus-4-8||claude-fable-5-1
native-sonnet|sonnet|--model sonnet|claude-sonnet-5-5|sonnet
native-fable|fable|--model fable|claude-fable-5-5|fable
native-haiku|haiku|--model haiku|claude-haiku-5-5|haiku
native-opus|opus|--model opus[1m]|claude-opus-5-5|opus[1m]|claude-fable-5-1
extended|claude-opus-4-6|--model claude-opus-4-6[1m]||claude-opus-4-6[1m]
uppercase-selector|claude-opus-4-6|--model CLAUDE-OPUS-4-6[1M]||claude-opus-4-6[1m]
version-selector|claude-opus-4-6|--model=opus-4-6[1m]|claude-opus-5-5|claude-opus-4-6[1m]
record-version|opus-4-6|--model opus-4-6[1m]||claude-opus-4-6[1m]
changed-family|claude-opus-4-6|--model opus[1m]|claude-opus-5-5|claude-opus-4-6[1m]
changed-default|claude-opus-4-6|--model opus|claude-opus-5-5|claude-opus-4-6
conflicting-selector|claude-opus-4-6|--model claude-opus-5-5[1m]||claude-opus-4-6
broken|claude-fable-5-1|--model claude-opus-4-8||claude-fable-5-1
ROWS

if model_case retired-callback; then
echo '=== delayed recovery keeps replacements ==='
for retired in pane server; do
  model_world "retired-$retired" claude-fable-5-1
  "$S/workflow-state" --state-dir "$LANE/tmp" update oversee \
    'if $retired == "pane" then .lanes[0].launch.pane="%replacement"
     else .lanes[0].launch.server=7001 end' --arg retired "$retired" >/dev/null
  before=$(jq -c . "$LANE/tmp/workflow-state-oversee.json")
  event claude-opus-4-8
  assert_eq "$(jq -c . "$LANE/tmp/workflow-state-oversee.json")" "$before" "a retired $retired callback cannot borrow a resumed session ID"
  assert_eq "$(lane_process_start "$OWNED_CHILD")" "$START" "a retired $retired callback leaves the replacement running"
  kill "$OWNED_CHILD" 2>/dev/null || :; wait "$OWNED_CHILD" 2>/dev/null || :; OWNED_CHILD=""
done

fi

if model_case replaced-before-write; then
model_world replaced-before-write claude-fable-5-1
mv -- "$S/workflow-state" "$S/workflow-state.real"
cat > "$S/workflow-state" <<'STATE'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == --state-dir && "$3" == update-report ]]; then
  "$0.real" --state-dir "$2" update oversee '.lanes[0].launched_at="launch-b"' >/dev/null
fi
exec "$0.real" "$@"
STATE
chmod +x "$S/workflow-state"
event claude-opus-4-8
assert_eq "$(switch_count)" 0 'a launch replacement before the locked write records no stale switch'
assert_eq "$(lane_process_start "$OWNED_CHILD")" "$START" 'a stale write cannot dispatch recovery'
kill "$OWNED_CHILD" 2>/dev/null || :; wait "$OWNED_CHILD" 2>/dev/null || :; OWNED_CHILD=""

fi

for changed in launch session claimed; do
  model_case "stale-$changed" || continue
  model_world "stale-$changed" claude-fable-5-1
  "$S/workflow-state" --state-dir "$LANE/tmp" update oversee '
    .lanes[0].model_check={session_id:"s1",outcome:"switched"}
    | if $changed=="launch" then .lanes[0].launched_at="launch-b"
      elif $changed=="session" then .lanes[0].model_check.session_id="s2"
      else .lanes[0].model_check.recovery_started=true end' --arg changed "$changed" >/dev/null
  before=$(jq -c . "$LANE/tmp/workflow-state-oversee.json")
  status=0
  env "MODEL_ARGV=$LANE/tmp/argv" "MODEL_DONE=$LANE/tmp/done" \
    "$BASH" "$S/lib/lane-relaunch.sh" model-recovery "$record" "$LANE/tmp" s1 >"$TMP_ROOT/recovery.out" 2>"$ERR_FILE" || status=$?
  assert_eq "$status" 0 "$changed stale recovery passes without action"
  assert_eq "$(jq -c . "$LANE/tmp/workflow-state-oversee.json")" "$before" "$changed stale recovery leaves replacement state"
  assert_eq "$(lane_process_start "$OWNED_CHILD")" "$START" "$changed stale recovery keeps replacement running"
  kill "$OWNED_CHILD" 2>/dev/null || :; wait "$OWNED_CHILD" 2>/dev/null || :; OWNED_CHILD=""
done

if model_case missing-judge; then
echo '=== missing companion judge ==='
model_world missing-judge claude-fable-5-1
rm -- "${CASE_HOOK%/*}/lane-mail-check.sh"
event claude-opus-4-8
assert_eq "$RC" 0 'an unavailable companion judge keeps the event advisory'
assert_eq "$(first_line)" - 'an unavailable judge emits no stderr refusal'
assert_eq "$(sed -n 's/^lane-mail-model-switch: judge=//p' "$TMP_ROOT/stdout")" \
  "${CASE_HOOK%/*}/lane-mail-check.sh" 'the companion reports its missing judge'
kill "$OWNED_CHILD" 2>/dev/null || :; wait "$OWNED_CHILD" 2>/dev/null || :; OWNED_CHILD=""

fi

if [[ -z "${MODEL_CONTROL:-}" ]]; then
  echo '=== must-fail controls ==='
  while IFS='|' read -r rule control_case; do
    control="$TMP_ROOT/control-$rule.sh"
    if [[ "$rule" == baseline ]]; then
      git -C "$REPO_ROOT" show b510440e4273d1cd168f381eb3d5b8d8a6aa693e:hooks/lane-mail-check.sh > "$control"
    else
      python3 - "$HOOK" "$control" "$rule" <<'CONTROL'
from pathlib import Path
import sys
source, target, rule = sys.argv[1:]
text = Path(source).read_text()
old, new = {
    "comparison": ('elif [ "$launch_id" = "$observed_id" ]; then return 0', 'elif false; then return 0'),
    "family": ('observed_id=$(launch_choice_model_id claude "$observed" resolved "$launched")', 'observed_id=$(launch_choice_model_id claude "$observed" resolved)'),
    "duplicate": ('elif $current.model_check.session_id == $session', 'elif false and $current.model_check.session_id == $session'),
    "history": ('and $current.model_check.launch_identity == $identity', 'and true'),
    "callback": ('.launch.pane == $pane and (.launch.server | tostring) == $server', 'true'),
    "server": ('(.launch.server | tostring) == $server', '.launch.server == $server'),
    "standing": ('$prior // {merged:', '{merged:'),
    "unbound": ('unbound) model_unavailable_notice launch-unbound "$observed"; return 0 ;;', 'unbound) return 0 ;;'),
    "notice": ('model_unavailable_notice adapter-unread "$observed" "$(cat -- "$WORK_DIR/model.err")"; return 0', 'message model-unavailable adapter-unread; return 0'),
    "claim": ('or $current.launch != $record.launch or $current.launched_at != $record.launched_at', 'or $current.launch != $record.launch or false'),
    "roster": ('(.child_sessions // {}) as $children', '{} as $children'),
    "unavailable": ('if .model_checks[$session] != null then', 'if false then'),
}[rule]
assert text.count(old) == 1
changed = text.replace(old, new)
assert changed != text
Path(target).write_text(changed)
CONTROL
    fi
    status=0
    MODEL_CONTROL=1 MODEL_CONTROL_CASE="$control_case" HOOK_UNDER_TEST="$control" "$BASH" "${BASH_SOURCE[0]}" >"$TMP_ROOT/control-$rule.log" 2>&1 || status=$?
    if [[ "$status" != 0 ]] && grep -q '^  FAIL ' "$TMP_ROOT/control-$rule.log"; then
      assert_eq red red "$rule production control rejects the defect"
    else
      assert_eq "$status" red "$rule production control must fail"
    fi
  done <<'CONTROLS'
baseline|complete
comparison|matching
family|family-alias
duplicate|complete
history|complete
callback|retired-callback
claim|replaced-before-write
roster|extended
unavailable|no-fleet-record
server|complete
standing|complete
unbound|gui-session
notice|adapter
CONTROLS
  while IFS='|' read -r rule control_case; do
    control="$TMP_ROOT/relaunch-$rule.sh"
    python3 - "$REPO_ROOT/skills/orch/scripts/lib/lane-relaunch.sh" "$control" "$rule" <<'CONTROL'
from pathlib import Path
import sys
source, target, rule = sys.argv[1:]
text = Path(source).read_text()
old, new = {
    "stop": ('lane_stop_local "" "$pid" "$start" "$wake_pid" "$wake_start" "$harness" || {', 'true || {'),
    "pin": ('if [[ "${5:-}" == model-switched ]]; then', 'if false; then'),
    "binding": ('[[ "$claim" == true ]] || return 0', ':'),
    "selector": ('model="${model}[1m]"', 'model="$model"'),
    "selector-id": ('&& "$launch_id" == "$selector_id"', '&& true'),
    "words": ('eval "choice_words=($choice)" || return 1', 'choice_words=("$choice")'),
    "account": ('[[ -z "$2" ]] || LANE_RECOVERY_ARGS+=(--lane "$2")', 'LANE_RECOVERY_ARGS+=(--lane "$2")'),
}[rule]
assert text.count(old) == 1
changed = text.replace(old, new)
assert changed != text
Path(target).write_text(changed)
CONTROL
    status=0
    MODEL_CONTROL=1 MODEL_CONTROL_CASE="$control_case" MODEL_RELAUNCH_UNDER_TEST="$control" "$BASH" "${BASH_SOURCE[0]}" >"$TMP_ROOT/relaunch-$rule.log" 2>&1 || status=$?
    failure='^  FAIL '
    [[ "$rule" != account ]] || failure='^  FAIL  omitted-mismatch recovery arguments preserve its account option$'
    if [[ "$status" != 0 ]] && grep -q "$failure" "$TMP_ROOT/relaunch-$rule.log"; then
      assert_eq red red "$rule recovery control rejects the defect"
    else
      assert_eq "$status" red "$rule recovery control must fail"
    fi
  done <<'CONTROLS'
stop|fresh-shell
pin|fresh-shell
binding|stale-launch
selector|extended
selector-id|conflicting-selector
words|extended
account|optional-account
CONTROLS
  control="$TMP_ROOT/companion-control.sh"
  python3 - "$COMPANION" "$control" <<'CONTROL'
from pathlib import Path
import sys
source,target=sys.argv[1:]
text=Path(source).read_text()
old='if [[ ! -x "$JUDGE" ]]; then'
assert text.count(old)==1
changed=text.replace(old,'if false; then')
assert changed != text
Path(target).write_text(changed)
CONTROL
  status=0
  MODEL_CONTROL=1 MODEL_CONTROL_CASE=missing-judge COMPANION_UNDER_TEST="$control" "$BASH" "${BASH_SOURCE[0]}" > "$TMP_ROOT/companion-control.log" 2>&1 || status=$?
  if [[ "$status" != 0 ]] && grep -q '^  FAIL ' "$TMP_ROOT/companion-control.log"; then
    assert_eq red red 'missing judge production control rejects the defect'
  else
    assert_eq "$status" red 'missing judge production control must fail'
  fi
fi
if [[ -n "${MODEL_CONTROL:-}" && "$((PASS + FAIL))" -eq 0 ]]; then
  printf 'lane-mail-model-switch.test: control-case=no-assertions value=%s\n' "$MODEL_CONTROL_CASE" >&2
  exit 1
fi
printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
