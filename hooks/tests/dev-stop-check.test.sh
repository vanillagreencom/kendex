#!/usr/bin/env bash
# Tests for the dev-stop-check hook.
#
# The hook blocks a subagent's stop while a validation run it started is still
# going: the worktree comes from a `dev-validate-run ... --worktree` command in
# the subagent's own transcript, and whether a run there is still going comes
# from orch's `dev-validate-run --live`, run from the hook's own install. A
# continued stop lets a live run go only where the hook held that run and no
# `--wait` call on it came after.
# Each row installs the hook beside the orch scripts in one of the layouts a
# project or global install takes, hands it a SubagentStop payload, and pins
# the exit status, the keyed first line and, for a refusal naming a run, the
# exact `--wait` command under it.
#
# The worktrees are fixtures: one whose run directory names a pid still
# running with a run child's argv, one whose run has its verdict, one whose
# pid has exited, one with no run at all. Transcripts carry the command the
# way Claude Code records a Bash call that outlasted its timeout (the call,
# then a result naming only the background output file), the way a Codex
# rollout records an exec_command call (the arguments as one JSON string), and
# the way each harness records a stop this hook held (its stderr as a user
# message).
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
claude_call() { # WORKTREE-ARGUMENT — a Bash call that outlasted its timeout
  printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":".agents/skills/orch/scripts/dev-validate-run --worktree %s","timeout":600000}}]}}\n' "$1"
  printf '{"type":"user","message":{"content":[{"type":"tool_result","content":"Command did not complete within its 600s timeout and was moved to the background (ID: b1). Output is being written to: %s/task.output. You will be notified when it completes."}]}}\n' "$TMP_ROOT"
}
codex_call() { # WORKTREE WORKTREE-ARGUMENT — an exec_command call in a rollout
  printf '{"type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\\"cmd\\":\\".agents/skills/orch/scripts/dev-validate-run --validate-mode range --base abc123 --worktree %s\\",\\"workdir\\":\\"%s\\"}"}}\n' "${2:-$1}" "$1"
}
claude_wait() { # RUN-DIR [RUN-DIR-ARGUMENT] — the --wait call a hold names
  printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":".agents/skills/orch/scripts/dev-validate-run --wait --run-dir %s","timeout":600000}}]}}\n' "${2:-$1}"
  printf '{"type":"user","message":{"content":[{"type":"tool_result","content":"state=running elapsed-secs=540 cap-secs=3660 run-dir=%s"}]}}\n' "$1"
}
codex_wait() { # RUN-DIR-ARGUMENT
  printf '{"type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\\"cmd\\":\\".agents/skills/orch/scripts/dev-validate-run --wait --run-dir %s\\"}"}}\n' "$1"
}
claude_hold() { # RUN-DIR — a stop this hook held, its text naming the --wait call
  printf '{"type":"user","message":{"role":"user","content":"Stop hook feedback:\\n[bash .claude/hooks/dev-stop-check.sh]: dev-stop-check: running=%s\\nthe validation run you started is still going.\\n%s/.claude/skills/orch/scripts/dev-validate-run --wait --run-dir %s\\nthen finish the round from the verdict it prints.\\n"},"isMeta":true}\n' "$1" "$TMP_ROOT" "$1"
}
codex_hold() { # RUN-DIR
  printf '{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"dev-stop-check: running=%s\\nthe validation run you started is still going.\\n%s/.codex/skills/orch/scripts/dev-validate-run --wait --run-dir %s\\nthen finish the round from the verdict it prints.\\n"}]}}\n' "$1" "$TMP_ROOT" "$1"
}
transcript() { # NAME CONTENT
  printf '%s' "$2" >"$TMP_ROOT/transcript.$1.jsonl"
}
transcript live-claude "$(claude_call "$WT_LIVE")"
transcript live-codex "$(codex_call "$WT_LIVE")"
# A double quote is escaped once in Claude Code's JSON and twice in the
# arguments string a Codex rollout nests in its own.
transcript live-claude-double "$(claude_call '\"'"$WT_LIVE"'\"')"
transcript live-claude-single "$(claude_call "'$WT_LIVE'")"
transcript live-codex-double "$(codex_call "$WT_LIVE" '\\\"'"$WT_LIVE"'\\\"')"
transcript held "$(claude_call "$WT_LIVE"; claude_hold "$RUN_LIVE")"
transcript held-waited "$(claude_call "$WT_LIVE"; claude_hold "$RUN_LIVE"; claude_wait "$RUN_LIVE")"
transcript held-waited-single "$(claude_call "$WT_LIVE"; claude_hold "$RUN_LIVE"; claude_wait "$RUN_LIVE" "'$RUN_LIVE'")"
transcript held-waited-double "$(claude_call "$WT_LIVE"; claude_hold "$RUN_LIVE"; claude_wait "$RUN_LIVE" '\"'"$RUN_LIVE"'\"')"
transcript codex-held-waited-single "$(codex_call "$WT_LIVE"; codex_hold "$RUN_LIVE"; codex_wait "'$RUN_LIVE'")"
transcript codex-held-waited-double "$(codex_call "$WT_LIVE"; codex_hold "$RUN_LIVE"; codex_wait '\\\"'"$RUN_LIVE"'\\\"')"
# A rerun: the first run was held and waited for, and the second, started
# after a fix, has never been held.
transcript rerun "$(claude_call "$WT_LIVE"; claude_hold "$WT_LIVE/tmp/dev-validate-first"
  claude_wait "$WT_LIVE/tmp/dev-validate-first"; claude_call "$WT_LIVE")"
transcript waited-held "$(claude_call "$WT_LIVE"; claude_wait "$RUN_LIVE"; claude_hold "$RUN_LIVE")"
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
# alone, and `failing` beside a dev-validate-run that cannot answer, each
# under `.claude/`. `shared` installs it under `.codex/` beside the shared
# `.agents/skills` tree, run from outside the repository. `codex` is that
# install in a repository the session runs in, whose root `skills/` holds a
# dev-validate-run that cannot answer, as a catalog checkout holds orch's
# source, which the walk stops short of. `global` installs it under a harness
# root moved out of the home (CODEX_HOME elsewhere), beside the home's shared
# tree.
world_hook() { # WORLD -> the hook's path
  case "$1" in
    shared | codex) printf '%s' "$TMP_ROOT/world.$1/.codex/hooks/dev-stop-check.sh" ;;
    global) printf '%s' "$TMP_ROOT/harness.global/hooks/dev-stop-check.sh" ;;
    *) printf '%s' "$TMP_ROOT/world.$1/.claude/hooks/dev-stop-check.sh" ;;
  esac
}
world_reader() { # WORLD -> the dev-validate-run the hook should name
  case "$1" in
    shared | codex) printf '%s' "$TMP_ROOT/world.$1/.agents/skills/orch/scripts/dev-validate-run" ;;
    global) printf '%s' "$TMP_ROOT/home.global/.agents/skills/orch/scripts/dev-validate-run" ;;
    *) printf '%s' "$TMP_ROOT/world.$1/.claude/skills/orch/scripts/dev-validate-run" ;;
  esac
}
world_home() { # WORLD
  case "$1" in
    global) printf '%s' "$TMP_ROOT/home.global" ;;
    *) printf '%s' "$TMP_ROOT/home" ;;
  esac
}
world_cwd() { # WORLD
  case "$1" in
    codex) printf '%s' "$TMP_ROOT/world.codex" ;;
    *) printf '%s' "$RUN_DIR" ;;
  esac
}
stub_reader() { # PATH — a dev-validate-run that cannot answer
  mkdir -p "${1%/*}"
  printf '#!/usr/bin/env bash\necho "dev-validate-run: stub cannot read" >&2\nexit 2\n' >"$1"
  chmod +x "$1"
}
install_world() { # NAME
  local world="$TMP_ROOT/world.$1" hook reader
  hook="$(world_hook "$1")"
  reader="$(world_reader "$1")"
  mkdir -p "${hook%/*}"
  case "$1" in
    orch | shared | global)
      mkdir -p "${reader%/orch/scripts/dev-validate-run}"
      ln -s "$ORCH" "${reader%/scripts/dev-validate-run}"
      ;;
    failing) stub_reader "$reader" ;;
    codex)
      git init -q "$world"
      mkdir -p "$world/.agents/skills"
      ln -s "$ORCH" "$world/.agents/skills/orch"
      stub_reader "$world/skills/orch/scripts/dev-validate-run"
      ;;
  esac
}
for world in orch bare failing shared codex global; do
  install_world "$world"
done

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
  local hook home cwd
  hook="$(world_hook "$1")"
  home="$(world_home "$1")"
  cwd="$(world_cwd "$1")"
  cp "$HOOK" "$hook"
  set +e
  if [ -n "${3:-}" ]; then
    (cd "$cwd" && printf '%s' "$2" | env -i HOME="$home" PWD="$cwd" PATH="$3" \
      GIT_CEILING_DIRECTORIES="$TMP_ROOT" "$BASH_BIN" "$hook") >/dev/null 2>"$ERR_FILE"
  else
    (cd "$cwd" && printf '%s' "$2" | env HOME="$home" GIT_CEILING_DIRECTORIES="$TMP_ROOT" \
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
      wait) grep -Fxq -- "$(world_reader "$world") --wait --run-dir $RUN_LIVE" "$ERR_FILE" && extra=" under=wait" || extra=" under=none" ;;
      cause) grep -Fxq -- "dev-validate-run: stub cannot read" "$ERR_FILE" && extra=" under=cause" || extra=" under=none" ;;
    esac
    got="rc=$rc first=$(first_line)$extra"
    want="rc=$rc_want first=$first_want"
    [ "$under" = - ] || want="$want under=$under"
    assert_eq "$got" "$want" "$label"
  done <<ROWS
a live run named by a Claude Code call that outlasted its timeout is refused|orch|-|agent:live-claude|2|dev-stop-check: running=$RUN_LIVE|wait
a live run named by a Codex exec_command call is refused|orch|-|agent:live-codex|2|dev-stop-check: running=$RUN_LIVE|wait
a double-quoted worktree in a Claude Code call is read|orch|-|agent:live-claude-double|2|dev-stop-check: running=$RUN_LIVE|wait
a single-quoted worktree in a Claude Code call is read|orch|-|agent:live-claude-single|2|dev-stop-check: running=$RUN_LIVE|wait
a double-quoted worktree in a Codex exec_command call is read|orch|-|agent:live-codex-double|2|dev-stop-check: running=$RUN_LIVE|wait
a live run is found past a newer worktree whose run has finished|orch|-|agent:live-then-done|2|dev-stop-check: running=$RUN_LIVE|wait
a payload without agent_transcript_path reads transcript_path|orch|-|bare:live-claude|2|dev-stop-check: running=$RUN_LIVE|wait
the parent's transcript is not the subagent's|orch|-|parent:live-claude|0|-|-
a continued stop with no wait since the hold lets the live run go|orch|-|active:held|0|dev-stop-check: abandoned=$RUN_LIVE|-
a continued stop on a run this hook never held is held|orch|-|active:rerun|2|dev-stop-check: running=$RUN_LIVE|wait
a continued stop after a wait since the hold is held again|orch|-|active:held-waited|2|dev-stop-check: running=$RUN_LIVE|wait
a single-quoted run dir in a Claude Code wait is read|orch|-|active:held-waited-single|2|dev-stop-check: running=$RUN_LIVE|wait
a double-quoted run dir in a Claude Code wait is read|orch|-|active:held-waited-double|2|dev-stop-check: running=$RUN_LIVE|wait
a single-quoted run dir in a Codex wait is read|orch|-|active:codex-held-waited-single|2|dev-stop-check: running=$RUN_LIVE|wait
a double-quoted run dir in a Codex wait is read|orch|-|active:codex-held-waited-double|2|dev-stop-check: running=$RUN_LIVE|wait
a wait before the last hold does not hold again|orch|-|active:waited-held|0|dev-stop-check: abandoned=$RUN_LIVE|-
a continued stop with no run going passes|orch|-|active:done|0|-|-
a run with its verdict passes|orch|-|agent:done|0|-|-
a run whose child is gone passes|orch|-|agent:gone|0|-|-
a worktree with no run passes|orch|-|agent:empty|0|-|-
a worktree since removed passes|orch|-|agent:removed|0|-|-
a transcript naming no worktree passes|orch|-|agent:none|0|-|-
a reader that cannot answer is refused with its words|failing|-|agent:live-claude|2|dev-stop-check: unread=$WT_LIVE|cause
a reader that cannot answer on a continued stop is reported, not held|failing|-|active:live-claude|0|dev-stop-check: unread=$WT_LIVE|cause
a reader in the shared tree beside the hook is found|shared|-|agent:live-claude|2|dev-stop-check: running=$RUN_LIVE|wait
a reader in the repository's shared tree is found at its root, not past it|codex|-|agent:live-claude|2|dev-stop-check: running=$RUN_LIVE|wait
a reader in the home's shared tree is found for a harness root outside the home|global|-|agent:live-claude|2|dev-stop-check: running=$RUN_LIVE|wait
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
  'a continued stop with no wait since the hold lets the live run go'
skill_load_control hold-again "$HOOK" '[ "$ACTIVE" = true ] || refuse running "$RUN_DIR"' \
  'notice abandoned "$RUN_DIR"' HOOK stop_rows 'a continued stop after a wait since the hold is held again'
skill_load_control never-held "$HOOK" 'notice transcript unread "$WAITED"' \
  '[ "$HELD" -gt 0 ] || notice abandoned "$RUN_DIR"' HOOK stop_rows \
  'a continued stop on a run this hook never held is held'
skill_load_control wait-since-hold "$HOOK" 'notice transcript unread "$WAITED"' \
  'WAITED=$((HELD + 1))' HOOK stop_rows 'a wait before the last hold does not hold again'
skill_load_control unread-continued "$HOOK" 'notice() { # KEY VALUE [DETAIL]' '[ "$1" != unread ] || refuse "$@"' \
  HOOK stop_rows 'a reader that cannot answer on a continued stop is reported, not held'
# The one transcript reader takes no quote before a path.
skill_load_control quoted-path "$HOOK" '"$TRANSCRIPT" 2>&1) || rc=$?' \
  'rc=0; found=$(grep -noE -- "$1/[^\"'"'"'[:space:]\\\\]+" "$TRANSCRIPT" 2>&1) || rc=$?' \
  HOOK stop_rows 'a double-quoted worktree in a Claude Code call is read' \
  'a single-quoted worktree in a Claude Code call is read' \
  'a double-quoted worktree in a Codex exec_command call is read' \
  'a single-quoted run dir in a Claude Code wait is read' \
  'a double-quoted run dir in a Claude Code wait is read' \
  'a single-quoted run dir in a Codex wait is read' \
  'a double-quoted run dir in a Codex wait is read'
skill_load_control shared-tree "$HOOK" 'for candidate in "$AT/skills/$SCRIPT" "$AT/.agents/skills/$SCRIPT"; do' \
  '[ "$candidate" != "$AT/.agents/skills/$SCRIPT" ] || continue' HOOK stop_rows \
  'a reader in the shared tree beside the hook is found'
skill_load_control root-stop "$HOOK" 'LEVELS=0' 'ROOT=/' HOOK stop_rows \
  'a reader in the repository'"'"'s shared tree is found at its root, not past it'
skill_load_control root-fallback "$HOOK" '"$ROOT"/*) READER="$ROOT/.agents/skills/$SCRIPT"' 'READER=""' \
  HOOK stop_rows 'a reader in the repository'"'"'s shared tree is found at its root, not past it'
skill_load_control home-fallback "$HOOK" 'READER="$HOME_DIR/.agents/skills/$SCRIPT"' 'READER=""' HOOK stop_rows \
  'a reader in the home'"'"'s shared tree is found for a harness root outside the home'
skill_load_control no-run "$HOOK" 'LIVE=$("$READER" --live --worktree "$WORKTREE" 2>&1) || rc=$?' \
  '[ "$rc" != 1 ] || rc=0' HOOK stop_rows 'a worktree with no run passes'
skill_load_control removed "$HOOK" 'while IFS= read -r WORKTREE; do' \
  '[ -d "$WORKTREE" ] || refuse unread "$WORKTREE"' HOOK stop_rows 'a worktree since removed passes'
skill_load_control subagent-transcript "$HOOK" 'refuse payload invalid-json' \
  'FIELDS=$(printf '"'"'%s'"'"' "$INPUT" | jq -r '"'"'["transcript_path", .transcript_path, "false"] | @tsv'"'"')' \
  HOOK stop_rows 'the parent'"'"'s transcript is not the subagent'"'"'s'
# The one transcript reader runs a path on past a backslash.
skill_load_control escaped-arguments "$HOOK" '"$TRANSCRIPT" 2>&1) || rc=$?' \
  'rc=0; found=$(grep -noE -- "$1(\\\\*\"|'"'"')?/[^\"'"'"'[:space:]]+" "$TRANSCRIPT" 2>&1) || rc=$?' \
  HOOK stop_rows 'a live run named by a Codex exec_command call is refused'
skill_load_control unread "$HOOK" 'refuse() { # KEY VALUE [DETAIL]' '[ "$1" != unread ] || exit 0' \
  HOOK stop_rows 'a reader that cannot answer is refused with its words'
skill_load_control payload "$HOOK" 'refuse() { # KEY VALUE [DETAIL]' '[ "$1" != payload ] || exit 0' \
  HOOK stop_rows 'a payload that is not JSON is refused'
skill_load_control reported-gaps "$HOOK" 'notice() { # KEY VALUE [DETAIL]' 'exit 0' HOOK stop_rows \
  'no reader beside the hook is reported, not held' 'a missing jq is reported, not held'

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
