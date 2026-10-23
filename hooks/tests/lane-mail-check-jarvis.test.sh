#!/usr/bin/env bash
# Surface: lane-mail-check's managed Jarvis succession role.
# Inputs: hooks/lane-mail-check.sh, hooks/tests/lib/lane-mail-world.sh,
# hooks/tests/lib/first-line.sh, skills/orch/tests/lib/tier-model-path.sh,
# skills/jarvis/scripts/, skills/orch/scripts/, skills/mailbox/scripts/.
set -euo pipefail
case "$(uname -s)" in MINGW*|MSYS*) export MSYS=winsymlinks:nativestrict ;; esac

# shellcheck source=lib/lane-mail-world.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/lane-mail-world.sh"

JARVIS_SOCKET="$TMP_ROOT/jarvis.sock"
cleanup() {
  tmux -S "$JARVIS_SOCKET" kill-server 2>/dev/null || :
  stop_wake_processes
  chmod -R u+rwx -- "${TMP_ROOT:?}" 2>/dev/null || :
  rm -rf -- "${TMP_ROOT:?}"
}
trap cleanup EXIT

# A private terminal runs only an owned sleep. No harness, fleet or account
# pool runs in this fixture. The controller's production reader proves live
# terminal identity against it.
tmux -S "$JARVIS_SOCKET" -f /dev/null new-session -d -s jarvis 'sleep 600'
JARVIS_PANE=$(tmux -S "$JARVIS_SOCKET" display-message -p -t jarvis '#{pane_id}')
JARVIS_SERVER=$(tmux -S "$JARVIS_SOCKET" display-message -p -t jarvis '#{pid}')
JARVIS_START=$(tmux -S "$JARVIS_SOCKET" display-message -p -t jarvis '#{start_time}')
JARVIS_WINDOW=$(tmux -S "$JARVIS_SOCKET" display-message -p -t jarvis '#{window_id}')
tmux -S "$JARVIS_SOCKET" set-option -p -t "$JARVIS_PANE" @jarvis-generation 3

LANE="$TMP_ROOT/jarvis-home"
mkdir -p "$LANE/.agents/skills" "$LANE/.claude/hooks"
for package in jarvis mailbox; do
  ln -s "$REPO_ROOT/skills/$package" "$LANE/.agents/skills/$package"
done
mkdir -p "$LANE/.agents/skills/orch"
ln -s "$REPO_ROOT/skills/orch/scripts" "$LANE/.agents/skills/orch/scripts"
install_hook "$HOOK" "$LANE/.claude/hooks/lane-mail-check.sh"
ACCOUNT="$TMP_ROOT/account"
TRANSCRIPT="$ACCOUNT/projects/jarvis/s1.jsonl"
mkdir -p "${TRANSCRIPT%/*}"
STATE="$TMP_ROOT/state"
RECORD=$(env JARVIS_BASH="$BASH" XDG_STATE_HOME="$STATE" python3 - "$REPO_ROOT/skills/jarvis/scripts/lib/session.py" "$LANE" <<'PY'
import runpy
import sys
print(runpy.run_path(sys.argv[1])["Session"](sys.argv[2]).path)
PY
)
mkdir -p "${RECORD%/*}"
jq -nc --arg home "$LANE" --arg account "$ACCOUNT" --arg socket "$JARVIS_SOCKET" \
  --arg pane "$JARVIS_PANE" --arg window "$JARVIS_WINDOW" --argjson server "$JARVIS_SERVER" --argjson start "$JARVIS_START" \
  '{v:1,home:$home,harness:"claude",account:$account,effective_home:$account,
    state:"running",reason:"new-requested",generation:3,server_pid:$server,server_started_at:$start,
    terminal:{server:$socket,session:"jarvis",window:$window,pane:$pane},
    pending:{generation:3,native_session_id:"s1",started_at:1}}' > "$RECORD"

# Read the environment Claude supplies to hooks from the actual managed
# launch, with neither compaction setting inherited from the test runner.
mkdir -p "$TMP_ROOT/managed-bin"
cat > "$TMP_ROOT/managed-bin/claude" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
for word in "$@"; do
  case "$word" in
    --settings=*)
      while IFS= read -r assignment; do export "$assignment"; done \
        < <(jq -r '.env // {} | to_entries[] | "\(.key)=\(.value)"' <<<"${word#--settings=}") ;;
  esac
done
jq -cn '{auto:(env.DISABLE_AUTO_COMPACT // ""),manual:(env.DISABLE_COMPACT // "")}'
STUB
chmod +x "$TMP_ROOT/managed-bin/claude"
MANAGED_ENV=$(env -u DISABLE_AUTO_COMPACT -u DISABLE_COMPACT PATH="$TMP_ROOT/managed-bin:$PATH" \
  "$BASH" -c 'source "$1"
    lane_session_command claude s1 "" || exit
    line=$(lane_launch_line "$LANE_SESSION_CMD" claude "$LANE_SESSION_ACCOUNT_VAR" "$2" prefix) || exit
    "$BASH" -c "$line"' _ "$REPO_ROOT/skills/orch/scripts/lib/lane-launch.sh" "$ACCOUNT")
BASE_CALL_ENV=("HOME=$OFFLINE_HOME" "XDG_STATE_HOME=$STATE" "CLAUDE_CONFIG_DIR=$ACCOUNT"
  "DISABLE_AUTO_COMPACT=$(jq -r .auto <<<"$MANAGED_ENV")" "DISABLE_COMPACT=$(jq -r .manual <<<"$MANAGED_ENV")"
  "JARVIS_RECORD=$RECORD" JARVIS_GENERATION=3 "TMUX=$JARVIS_SOCKET,$JARVIS_SERVER,0")
CALL_ENV=("${BASE_CALL_ENV[@]}" "TMUX_PANE=$JARVIS_PANE")
CONTEXT_PCT_ENV=ORCH_HANDOFF_CONTEXT_PCT=90
TAB=$'\t'

jarvis_mark() { # TOKENS ACTIVE [SESSION] [AGENT]
  usage_line sonnet "$1" > "$TRANSCRIPT"
  run_payload "$(jq -nc --arg p "$TRANSCRIPT" --arg s "${3:-s1}" --arg agent "${4:-}" --argjson active "$2" \
    '{session_id:$s,stop_hook_active:$active,transcript_path:$p}
      + (if $agent == "" then {} else {agent_id:$agent} end)')"
}

cp "$RECORD" "$RECORD.seed"

# The gate's cases share the same live controller identity. SDK usage comes
# from session.usage_info. Jarvis Control-host events registers the same
# native session as overseer, so that overlap must retain the overseer path.
while IFS='|' read -r shape label tokens active session agent expected key; do
  if [ "${1:-}" = --missing-pane ]; then
    case "$shape" in missing-pane*) ;; *) continue ;; esac
  elif [ -n "${1:-}" ]; then
    [ "$shape" = "$1" ] || continue
  fi
  cp "$RECORD.seed" "$RECORD"
  CONTEXT_PCT_ENV=ORCH_HANDOFF_CONTEXT_PCT=90
  TRANSCRIPT="$ACCOUNT/projects/jarvis/s1.jsonl"
  install_hook "$HOOK" "$LANE/.claude/hooks/lane-mail-check.sh"
  CALL_ENV=("${BASE_CALL_ENV[@]}" "TMUX_PANE=$JARVIS_PANE")
  case "$shape" in
    missing-pane-default)
      CALL_ENV=()
      for assignment in "${BASE_CALL_ENV[@]}"; do
        case "$assignment" in JARVIS_RECORD=* | JARVIS_GENERATION=*) ;; *) CALL_ENV+=("$assignment") ;; esac
      done
      ;;
    missing-pane*) CALL_ENV=("${BASE_CALL_ENV[@]}") ;;
    absent) mv "$RECORD" "$RECORD.saved" ;;
    setting-range) CONTEXT_PCT_ENV=ORCH_HANDOFF_CONTEXT_PCT=101 ;;
    script | setting)
      hole_install orch-env
      if [ "$shape" = setting ]; then
        printf '#!/usr/bin/env bash\nexit 1\n' > "$LANE/.agents/skills/orch/scripts/orch-env"
        chmod +x "$LANE/.agents/skills/orch/scripts/orch-env"
      fi
      ;;
    transcript) TRANSCRIPT="$ACCOUNT/projects/missing/s1.jsonl" ;;
    copilot*)
      [ "$shape" != copilot-missing-pane ] || CALL_ENV=("${BASE_CALL_ENV[@]}")
      jq '.harness="copilot"' "$RECORD.seed" > "$RECORD"
      install_hook "$HOOK" "$LANE/.github/hooks/lane-mail-check.sh"
      TRANSCRIPT="$ACCOUNT/session-state/s1/events.jsonl"
      mkdir -p "${TRANSCRIPT%/*}"
      : > "$TRANSCRIPT"
      ARM_ARGS=(start)
      run_payload '{"sessionId":"s1","timestamp":1}' "COPILOT_HOME=$ACCOUNT"
      expect 0 - "$label: lead start"
      if [ "$shape" != copilot-empty ]; then
        ARM_ARGS=(usage)
        run_payload "$(jq -nc --arg cwd "$LANE" --argjson tokens "$tokens" \
          '{session_id:"s1",cwd:$cwd,current_tokens:$tokens,token_limit:1000000}')" "COPILOT_HOME=$ACCOUNT"
        expect 0 - "$label: SDK reading"
        assert_eq "$(jq -r '[.session_id,.tokens] | @tsv' "$OFFLINE_HOME/.cache/lane-mail/copilot-leads/s1")" \
          "s1$TAB$tokens" "$label: existing lead record holds the reading"
        # A resume touches identity and must preserve its SDK reading.
        ARM_ARGS=(start)
        run_payload '{"sessionId":"s1","timestamp":1}' "COPILOT_HOME=$ACCOUNT"
      fi
      ARM_ARGS=()
      [ "$shape" != copilot-absent ] || mv "$RECORD" "$RECORD.saved"
      run_payload "$(jq -nc --arg p "$TRANSCRIPT" '{sessionId:"s1",timestamp:1,transcriptPath:$p}')" "COPILOT_HOME=$ACCOUNT"
      ;;
    registered)
      assert_eq "$([ -e "$LANE/tmp" ] && echo written || echo absent)" absent \
        'the plain Jarvis role creates no mailbox, fleet or context state in its home'
      git -C "$LANE" init -q
      git -C "$LANE" config gc.auto 0
      git -C "$LANE" config maintenance.auto false
      git -C "$LANE" checkout -q -b main
      git -C "$LANE" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m base
      hole_install oversee-succeed
      plant_judge "$LANE/.agents/skills/orch/scripts"
      judge_says "$BELOW_MARK_LINE"
      (cd "$LANE" && "$REPO_ROOT/skills/orch/scripts/workflow-state" init oversee >/dev/null)
      record_overseer "$JARVIS_PANE" "$JARVIS_SERVER" "$ACCOUNT" "$JARVIS_START"
      bind_overseer claude "$ACCOUNT" s1
      CALL_ENV+=("ORCH_WAKE_PROCESS=^jarvis-fixture-wake$" "ORCH_WAKE_START=fixture-wake")
      ;;
  esac
  case "$key" in
    SCRIPT_KEY) key="lane-mail-check: script=$LANE/.agents/skills/orch/scripts/orch-env" ;;
    READING_KEY) key=lane-mail-check:\ reading-unrecorded ;;
  esac
  case "$shape" in
    missing-pane-foreign)
      TRANSCRIPT="$ACCOUNT/projects/jarvis/$session.jsonl"
      jarvis_mark "$tokens" "$active" "$session"
      assert_eq "RC=$RC visible=$(jq -r '.systemMessage | if type == "string" then test("\\S") else false end' "$TMP_ROOT/stdout")" \
        'RC=0 visible=true' "$label: a new native id is visibly unjudged"
      jarvis_mark "$tokens" "$active" "$session"
      assert_eq "RC=$RC stdout=$(cat "$TMP_ROOT/stdout")" 'RC=0 stdout=' \
        "$label: the native id gap is told once"
      jq --arg session "$session" '.pending.native_session_id=$session' "$RECORD" > "$RECORD.next"
      mv "$RECORD.next" "$RECORD"
      jarvis_mark "$tokens" "$active" "$session"
      expect 2 "lane-mail-check: context=$tokens" "$label: controller recovery restores judgement"
      ;;
    copilot*)
      # Copilot consumes this machine-readable Stop decision at exit zero.
      decision=allow
      [ ! -s "$TMP_ROOT/stdout" ] || decision=$(jq -r '.decision // "allow"' "$TMP_ROOT/stdout")
      first=$(first_line)
      [ "$shape" != copilot-empty ] || first=${first%%=*}
      if [ "$key" = NO_MARK ]; then
        assert_eq "$(grep -c '^lane-mail-check: context=' "$ERR_FILE" || :)" 0 "$label: no succession mark"
        first=NO_MARK
      fi
      assert_eq "RC=$RC decision=$decision first=$first" \
        "RC=0 decision=$expected first=${key//@TOKENS@/$tokens}" "$label"
      ;;
    transcript)
      run_payload "$(jq -nc --arg p "$TRANSCRIPT" '{session_id:"s1",transcript_path:$p}')"
      expect "$expected" "$key" "$label"
      ;;
    *)
      jarvis_mark "$tokens" "$active" "$session" "$agent"
      if [ "$key" = NO_MARK ]; then
        assert_eq "RC=$RC marks=$(grep -c '^lane-mail-check: context=' "$ERR_FILE" || :)" \
          "RC=$expected marks=0" "$label"
      else
        expect "$expected" "${key//@TOKENS@/$tokens}" "$label"
      fi
      ;;
  esac
  case "$shape" in
    absent | copilot-absent) mv "$RECORD.saved" "$RECORD" ;;
    script | setting)
      rm -f -- "${LANE:?}/.agents/skills/orch/scripts/orch-env"
      ln -s "$REPO_ROOT/skills/orch/scripts/orch-env" "$LANE/.agents/skills/orch/scripts/orch-env"
      ;;
  esac
done <<'ROWS'
plain|below the context mark|100000|false|s1||0|-
plain|at the percentage mark|180000|false|s1||0|-
plain|past the percentage mark|180001|false|s1||2|lane-mail-check: context=@TOKENS@
plain|at the absolute context mark|400000|false|s1||2|lane-mail-check: context=@TOKENS@
plain|a continued turn retains its succession mark|400000|true|s1||2|lane-mail-check: context=@TOKENS@
missing-pane|a managed Jarvis without TMUX_PANE receives its mark|400000|false|s1||2|lane-mail-check: context=@TOKENS@
missing-pane|a managed Jarvis without TMUX_PANE is judged again|400000|true|s1||2|lane-mail-check: context=@TOKENS@
missing-pane-default|the runtime default identifies Jarvis without launch bindings|400000|false|s1||2|lane-mail-check: context=@TOKENS@
missing-pane-default|the runtime default identifies Jarvis at its next Stop|400000|true|s1||2|lane-mail-check: context=@TOKENS@
missing-pane-foreign|a missing-pane Jarvis native id must match its controller|400000|false|s2||0|NO_MARK
plain|another native session gets no Jarvis mark|400000|false|s2||0|-
plain|a subagent gets no Jarvis mark|400000|false|s1|child|0|-
absent|the same session with no record gets no mark|400000|false|s1||0|NO_MARK
plain|the restored record restores the Jarvis succession mark|400000|false|s1||2|lane-mail-check: context=@TOKENS@
setting-range|an invalid setting passes as a named gap|400000|false|s1||0|lane-mail-check: setting-range=ORCH_HANDOFF_CONTEXT_PCT=101
setting|an unreadable setting passes as a named gap|400000|false|s1||0|lane-mail-check: setting=ORCH_HANDOFF_CONTEXT_PCT
script|an absent context command passes as a named gap|400000|false|s1||0|SCRIPT_KEY
transcript|a missing native transcript passes as a named gap|400000|false|s1||0|lane-mail-check: transcript=unreadable
copilot-empty|an empty Copilot lead marker leaves context unmeasured|100000|false|s1||allow|READING_KEY
copilot-sdk|an SDK reading below the mark passes|100000|false|s1||allow|-
copilot-sdk|an SDK-only managed Copilot session receives succession|400000|false|s1||block|lane-mail-check: context=@TOKENS@
copilot-missing-pane|an SDK-only Jarvis without TMUX_PANE receives succession|400000|false|s1||block|lane-mail-check: context=@TOKENS@
copilot-absent|the same SDK session with no controller record gets no mark|400000|false|s1||allow|NO_MARK
registered|a managed registered overseer retains its wake refusal|100000|false|s1||2|lane-mail-check: wake=unarmed
ROWS

# Keep the matched implementation text while removing its behavior. The
# shared helper proves that the disposable source copy changed.
if [ -z "${HOOK_UNDER_TEST:-}" ] && [ -z "${1:-}" ]; then
  assert_eq "$(grep -c '^jarvis_identified() {$' "$HOOK")" 1 'control matches the role-identification owner once'
  mutant jarvis-unidentified -e '/^jarvis_identified() {$/a\
  return 1'
  control_rc=0
  HOOK_UNDER_TEST="$MUTANT_PATH" "$BASH" "${BASH_SOURCE[0]}" > "$TMP_ROOT/control.log" 2>&1 || control_rc=$?
  assert_eq "$control_rc" 1 'control rejects the missing Jarvis identification'
  assert_eq "$(grep -Fxc '  FAIL  past the percentage mark' "$TMP_ROOT/control.log" || :)" 1 \
    'control reaches the succession assertion'
fi

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
