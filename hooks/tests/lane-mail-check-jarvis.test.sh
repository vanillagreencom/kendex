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
for package in jarvis orch mailbox; do
  ln -s "$REPO_ROOT/skills/$package" "$LANE/.agents/skills/$package"
done
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
CALL_ENV=("HOME=$OFFLINE_HOME" "XDG_STATE_HOME=$STATE" "CLAUDE_CONFIG_DIR=$ACCOUNT"
  "JARVIS_RECORD=$RECORD" JARVIS_GENERATION=3 "TMUX=$JARVIS_SOCKET,$JARVIS_SERVER,0" "TMUX_PANE=$JARVIS_PANE")
CONTEXT_PCT_ENV=ORCH_HANDOFF_CONTEXT_PCT=90

jarvis_mark() { # TOKENS ACTIVE [SESSION] [AGENT]
  usage_line sonnet "$1" > "$TRANSCRIPT"
  run_payload "$(jq -nc --arg p "$TRANSCRIPT" --arg s "${3:-s1}" --arg agent "${4:-}" --argjson active "$2" \
    '{session_id:$s,stop_hook_active:$active,transcript_path:$p}
      + (if $agent == "" then {} else {agent_id:$agent} end)')"
}

while IFS='|' read -r label tokens active session agent expected; do
  jarvis_mark "$tokens" "$active" "$session" "$agent"
  expect "$expected" "$([ "$expected" = 2 ] && printf 'lane-mail-check: context=%s' "$tokens" || printf -- '-')" "$label"
done <<'ROWS'
below the context mark|100000|false|s1||0
at the percentage mark|180000|false|s1||0
past the percentage mark|180001|false|s1||2
at the absolute context mark|400000|false|s1||2
a continued turn retains its succession mark|400000|true|s1||2
another native session gets no Jarvis mark|400000|false|s2||0
a subagent gets no Jarvis mark|400000|false|s1|child|0
ROWS

# The same session and payload lose the mark when its record is removed.
mv "$RECORD" "$RECORD.saved"
jarvis_mark 400000 false
assert_eq "RC=$RC marks=$(grep -c '^lane-mail-check: context=' "$ERR_FILE" || :)" 'RC=0 marks=0' \
  'the same session with no record gets no mark'
mv "$RECORD.saved" "$RECORD"

# The unchanged assertions reject main's hook through HOOK_UNDER_TEST. The
# paired record-absent row stays green, isolating the missing role lookup.
jarvis_mark 400000 false
expect 2 'lane-mail-check: context=400000' 'the restored record restores the Jarvis succession mark'
assert_eq "$([ -e "$LANE/tmp" ] && echo written || echo absent)" absent \
  'the Jarvis role creates no mailbox, fleet or context state in its home'

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
