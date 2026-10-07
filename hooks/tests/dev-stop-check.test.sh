#!/usr/bin/env bash
# Tests for the dev-stop-check hook.
#
# The hook blocks a subagent's stop once while a validation run it started is
# still going: the worktree comes from a `dev-validate-run ... --worktree`
# command in the subagent's own transcript, and whether a run there is still
# going comes from orch's `dev-validate-run --live`, run from the hook's own
# install. Each row installs the hook beside the orch scripts the way a
# project install lays them out under `.claude/`, hands it a SubagentStop
# payload, and pins the exit status, the keyed first line and, for a refusal
# naming a run, the exact `--wait` command under it.
#
# The worktrees are fixtures: one whose run directory names a pid still
# running with a run child's argv, one whose run has its verdict, one whose
# pid has exited, one with no run at all. Transcripts carry the command the
# way Claude Code records a Bash call that outlasted its timeout (the call,
# then a result naming only the background output file) and the way a Codex
# rollout records an exec_command call (the arguments as one JSON string).
#
# HOOK_UNDER_TEST overrides the script under test so the must-fail controls
# (a planted copy per rule) run against these same rows.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${HOOK_UNDER_TEST:-$(cd "$TEST_DIR/.." && pwd)/dev-stop-check.sh}"
ORCH="$(cd "$TEST_DIR/../../skills/orch" && pwd)"

PASS=0
FAIL=0
TMP_ROOT="$(mktemp -d)" || { echo "dev-stop-check: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "dev-stop-check: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "dev-stop-check: scratch=resolve-failed" >&2; exit 1; }
PLANTED=""
trap '[ -z "$PLANTED" ] || kill -KILL "$PLANTED" 2>/dev/null || :; rm -rf -- "${TMP_ROOT:?}"' EXIT
ERR_FILE="$TMP_ROOT/stderr"
BASH_BIN="$(command -v bash)"
# shellcheck source=lib/assert.sh
. "$TEST_DIR/lib/assert.sh"
# shellcheck source=lib/first-line.sh
. "$TEST_DIR/lib/first-line.sh"

# The session's directory, outside any repository, as a lead session started
# elsewhere would be: the worktree comes from the transcript alone.
RUN_DIR="$TMP_ROOT/cwd"
mkdir -p "$RUN_DIR" "$TMP_ROOT/home"

# --- The worktrees ----------------------------------------------------------
plant_run() { # WORKTREE -> the run directory
  mkdir -p "$1/tmp/dev-validate-planted"
  printf '%s' "$1/tmp/dev-validate-planted"
}
WT_LIVE="$TMP_ROOT/wt.live"
RUN_LIVE="$(plant_run "$WT_LIVE")"
# One process carrying a run child's argv tail, which dev-validate-run checks
# before it counts a pid as its run's.
perl -e 'sleep 300' -- planted --child --run-dir "$RUN_LIVE" </dev/null >/dev/null 2>&1 &
PLANTED=$!
disown "$PLANTED"
printf '%s\n' "$PLANTED" >"$RUN_LIVE/pid"
WT_DONE="$TMP_ROOT/wt.done"
RUN_DONE="$(plant_run "$WT_DONE")"
printf '%s\n' "$PLANTED" >"$RUN_DONE/pid"
printf 'guard-exit=0 at=2026-10-06T15:02:00Z\n' >"$RUN_DONE/exit"
WT_GONE="$TMP_ROOT/wt.gone"
RUN_GONE="$(plant_run "$WT_GONE")"
sleep 0 &
GONE_PID=$!
wait "$GONE_PID"
printf '%s\n' "$GONE_PID" >"$RUN_GONE/pid"
WT_EMPTY="$TMP_ROOT/wt.empty"
mkdir -p "$WT_EMPTY/tmp"
WT_REMOVED="$TMP_ROOT/wt.removed"

# --- The transcripts ---------------------------------------------------------
claude_call() { # WORKTREE — a Bash call that outlasted its timeout
  printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":".agents/skills/orch/scripts/dev-validate-run --worktree %s","timeout":600000}}]}}\n' "$1"
  printf '{"type":"user","message":{"content":[{"type":"tool_result","content":"Command did not complete within its 600s timeout and was moved to the background (ID: b1). Output is being written to: %s/task.output. You will be notified when it completes."}]}}\n' "$TMP_ROOT"
}
codex_call() { # WORKTREE — an exec_command call in a rollout
  printf '{"type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\\"cmd\\":\\".agents/skills/orch/scripts/dev-validate-run --validate-mode range --base abc123 --worktree %s\\",\\"workdir\\":\\"%s\\"}"}}\n' "$1" "$1"
}
transcript() { # NAME CONTENT
  printf '%s' "$2" >"$TMP_ROOT/transcript.$1.jsonl"
}
transcript live-claude "$(claude_call "$WT_LIVE")"
transcript live-codex "$(codex_call "$WT_LIVE")"
transcript done "$(claude_call "$WT_DONE")"
transcript gone "$(claude_call "$WT_GONE")"
transcript empty "$(claude_call "$WT_EMPTY")"
transcript removed "$(claude_call "$WT_REMOVED")"
transcript live-then-done "$(claude_call "$WT_LIVE"; claude_call "$WT_DONE")"
# The skill text a subagent loads names the command with a placeholder, never
# a path.
transcript none '{"type":"user","message":{"content":[{"type":"tool_result","content":"Run the BARE command .agents/skills/orch/scripts/dev-validate-run --worktree [WORKTREE_PATH] in the foreground"}]}}'

# --- The installs ------------------------------------------------------------
# `orch` lays the hook beside the real orch skill, `bare` installs the hook
# alone, and `failing` beside a dev-validate-run that cannot answer.
install_world() { # NAME
  local world="$TMP_ROOT/world.$1"
  mkdir -p "$world/.claude/hooks" "$world/.claude/skills"
  case "$1" in
    orch) ln -s "$ORCH" "$world/.claude/skills/orch" ;;
    failing)
      mkdir -p "$world/.claude/skills/orch/scripts"
      printf '#!/usr/bin/env bash\necho "dev-validate-run: stub cannot read" >&2\nexit 2\n' \
        >"$world/.claude/skills/orch/scripts/dev-validate-run"
      chmod +x "$world/.claude/skills/orch/scripts/dev-validate-run"
      ;;
  esac
}
install_world orch
install_world bare
install_world failing
READER="$TMP_ROOT/world.orch/.claude/skills/orch/scripts/dev-validate-run"

# A PATH holding only the named tools, for the rows that take one away.
farm() { # NAME TOOL...
  local dir="$TMP_ROOT/farm.$1" tool
  shift
  mkdir -p "$dir"
  for tool in "$@"; do
    ln -s "$(command -v "$tool")" "$dir/$tool"
  done
  printf '%s' "$dir"
}
FARM_NO_JQ="$(farm no-jq git cat grep awk)"
FARM_NONE="$(farm none)"

payload() { # AGENT-TRANSCRIPT PARENT-TRANSCRIPT ACTIVE
  jq -cn --arg a "$1" --arg p "$2" --argjson active "$3" \
    '{session_id: "s1", hook_event_name: "SubagentStop", agent_type: "runtime", agent_id: "a1",
      transcript_path: $p, agent_transcript_path: $a, stop_hook_active: $active}'
}

run_hook() { # WORLD PAYLOAD [PATH]
  local hook="$TMP_ROOT/world.$1/.claude/hooks/dev-stop-check.sh"
  cp "$HOOK" "$hook"
  set +e
  if [ -n "${3:-}" ]; then
    (cd "$RUN_DIR" && printf '%s' "$2" | env -i HOME="$TMP_ROOT/home" PWD="$RUN_DIR" PATH="$3" \
      GIT_CEILING_DIRECTORIES="$TMP_ROOT" "$BASH_BIN" "$hook") >/dev/null 2>"$ERR_FILE"
  else
    (cd "$RUN_DIR" && printf '%s' "$2" | env HOME="$TMP_ROOT/home" GIT_CEILING_DIRECTORIES="$TMP_ROOT" \
      "$BASH_BIN" "$hook") >/dev/null 2>"$ERR_FILE"
  fi
  rc=$?
  set -e
}

# The payload a row names: `agent:<transcript>` sends that transcript as the
# subagent's with a parent transcript naming no command, `parent:<transcript>`
# the reverse, `bare:<transcript>` that transcript as transcript_path with no
# agent_transcript_path key, `active:<transcript>` the subagent's with
# stop_hook_active true, and `raw:<json>` the text itself.
payload_of() { # SPEC
  local name="${1#*:}" none="$TMP_ROOT/transcript.none.jsonl"
  case "$1" in
    agent:*) payload "$TMP_ROOT/transcript.$name.jsonl" "$none" false ;;
    parent:*) payload "$none" "$TMP_ROOT/transcript.$name.jsonl" false ;;
    bare:*) jq -cn --arg t "$TMP_ROOT/transcript.$name.jsonl" \
      '{hook_event_name: "SubagentStop", transcript_path: $t, stop_hook_active: false}' ;;
    active:*) payload "$TMP_ROOT/transcript.$name.jsonl" "$none" true ;;
    raw:*) printf '%s' "$name" ;;
  esac
}

# A row: label|world|path|payload|rc|first|under
#   path   `-` this host's PATH, `no-jq` or `none` a farm of tools
#   first  the whole first line of stderr, `-` for silence
#   under  `wait` where the exact --wait command for the live run stands on
#          a line of its own, `cause` where the reader's own words stand under
#          the first line, `-` where neither is asserted
stop_rows() {
  local row label world path spec rc_want first_want under got extra
  while IFS='|' read -r label world path spec rc_want first_want under; do
    [ -n "$label" ] || continue
    case "$path" in
      -) run_hook "$world" "$(payload_of "$spec")" ;;
      no-jq) run_hook "$world" "$(payload_of "$spec")" "$FARM_NO_JQ" ;;
      none) run_hook "$world" "$(payload_of "$spec")" "$FARM_NONE" ;;
    esac
    extra=""
    case "$under" in
      wait) grep -Fxq -- "$READER --wait --run-dir $RUN_LIVE" "$ERR_FILE" && extra=" under=wait" || extra=" under=none" ;;
      cause) grep -Fxq -- "dev-validate-run: stub cannot read" "$ERR_FILE" && extra=" under=cause" || extra=" under=none" ;;
    esac
    got="rc=$rc first=$(first_line)$extra"
    want="rc=$rc_want first=$first_want"
    [ "$under" = - ] || want="$want under=$under"
    assert_eq "$got" "$want" "$label"
  done <<ROWS
a live run named by a Claude Code call that outlasted its timeout is refused|orch|-|agent:live-claude|2|dev-stop-check: running=$RUN_LIVE|wait
a live run named by a Codex exec_command call is refused|orch|-|agent:live-codex|2|dev-stop-check: running=$RUN_LIVE|wait
a live run is found past a newer worktree whose run has finished|orch|-|agent:live-then-done|2|dev-stop-check: running=$RUN_LIVE|wait
a payload without agent_transcript_path reads transcript_path|orch|-|bare:live-claude|2|dev-stop-check: running=$RUN_LIVE|wait
the parent's transcript is not the subagent's|orch|-|parent:live-claude|0|-|-
the harness's continued stop passes|orch|-|active:live-claude|0|-|-
a run with its verdict passes|orch|-|agent:done|0|-|-
a run whose child is gone passes|orch|-|agent:gone|0|-|-
a worktree with no run passes|orch|-|agent:empty|0|-|-
a worktree since removed passes|orch|-|agent:removed|0|-|-
a transcript naming no worktree passes|orch|-|agent:none|0|-|-
a reader that cannot answer is refused with its words|failing|-|agent:live-claude|2|dev-stop-check: unread=$WT_LIVE|cause
no reader beside the hook is reported, not held|bare|-|agent:live-claude|0|dev-stop-check: reader=$TMP_ROOT/world.bare/.claude/hooks|-
a transcript that cannot be read is reported, not held|orch|-|agent:missing|0|dev-stop-check: transcript=unreadable|-
a payload that is not JSON is refused|orch|-|raw:{not json|2|dev-stop-check: payload=invalid-json|-
a transcript path that is not a string is refused|orch|-|raw:{"agent_transcript_path":7}|2|dev-stop-check: payload=invalid-json|-
a missing jq is reported, not held|orch|no-jq|agent:live-claude|0|dev-stop-check: missing-tools=jq|-
every missing tool is named|orch|none|agent:live-claude|0|dev-stop-check: missing-tools=jq,git,cat,grep,awk|-
ROWS
}

echo "=== dev-stop-check ==="
stop_rows

# --- Must-fail controls, one per rule ----------------------------------------
skill_load_control running "$HOOK" 'RUN_DIR=${RUN_DIR% pid=*}' 'continue' HOOK stop_rows \
  'a live run named by a Claude Code call that outlasted its timeout is refused'
skill_load_control continued-stop "$HOOK" 'ACTIVE=${REST#*"$TAB"}' 'ACTIVE=false' HOOK stop_rows \
  'the harness'"'"'s continued stop passes'
skill_load_control no-run "$HOOK" 'LIVE=$("$READER" --live --worktree "$WORKTREE" 2>&1) || rc=$?' \
  '[ "$rc" != 1 ] || rc=0' HOOK stop_rows 'a worktree with no run passes'
skill_load_control removed "$HOOK" 'while IFS= read -r WORKTREE; do' \
  '[ -d "$WORKTREE" ] || refuse unread "$WORKTREE"' HOOK stop_rows 'a worktree since removed passes'
skill_load_control subagent-transcript "$HOOK" 'refuse payload invalid-json' \
  'FIELDS=$(printf '"'"'%s'"'"' "$INPUT" | jq -r '"'"'["transcript_path", .transcript_path, "false"] | @tsv'"'"')' \
  HOOK stop_rows 'the parent'"'"'s transcript is not the subagent'"'"'s'
skill_load_control escaped-arguments "$HOOK" 'GREP_RC=$?' \
  'MENTIONS=$(grep -oE '"'"'dev-validate-run[^"]* --worktree /[^"[:space:]]+'"'"' -- "$TRANSCRIPT")' \
  HOOK stop_rows 'a live run named by a Codex exec_command call is refused'
skill_load_control unread "$HOOK" 'refuse() { # KEY VALUE [DETAIL]' '[ "$1" != unread ] || exit 0' \
  HOOK stop_rows 'a reader that cannot answer is refused with its words'
skill_load_control payload "$HOOK" 'refuse() { # KEY VALUE [DETAIL]' '[ "$1" != payload ] || exit 0' \
  HOOK stop_rows 'a payload that is not JSON is refused'
skill_load_control reported-gaps "$HOOK" 'notice() { # KEY VALUE [DETAIL]' 'exit 0' HOOK stop_rows \
  'no reader beside the hook is reported, not held' 'a missing jq is reported, not held'

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
