#!/usr/bin/env bash
# ---
# name: dev-stop-check
# event: SubagentStop
# matcher:
# description: Blocks a subagent's stop once while a validation run it started is still going, naming the `dev-validate-run --wait --run-dir <run dir>` command to run next, because a subagent whose turn has ended is not woken when the run ends and its round is left with a verdict on disk and no commit. The worktrees are those the subagent's transcript names as `dev-validate-run ... --worktree <absolute path>` in a command it ran, the transcript being the payload's `agent_transcript_path` where the payload carries that key (Claude Code and Codex, whose `transcript_path` is the parent session's) and its `transcript_path` where it does not; the run is the one orch's `dev-validate-run --live --worktree` reports there, the run a start would refuse as run-live, so a run that has its verdict, or whose child is gone, passes. A stop whose transcript names no such worktree, a worktree since removed, or no run still going passes silently, as does `stop_hook_active` true, the harness's continued stop, so the refusal comes once per stop. The `dev-validate-run` read comes from this hook's own install; a missing reader, a transcript that cannot be read and a missing tool are reported under their own key at exit 0, since the subagent can do nothing about them. Not run on copilot: its subagentStop names the lead's transcript, not the subagent's, so the worktree a subagent validated in cannot be read. Not run on pi: Pi 1.0.0's extension `types.ts` has no subagent event. Not run on gemini: it has no SubagentStop event. Not run on antigravity: it has no SubagentStop event.
# summary: Stops a coding agent from finishing while the validation run it started is still going, and hands it the command that waits for the verdict.
# safety: Reads the payload and the subagent's transcript, runs `git rev-parse` in the session's directory, and runs orch's `dev-validate-run --live`, which reads the worktree's run directories and the process table; it writes nothing. jq is required to read the payload, and a payload that cannot be read is refused. Exit 2 names the run and the `--wait` command that ends the block. Every line opens with `dev-stop-check: <key>=<value>`; what a command this hook runs writes is captured at the site and replayed under that line.
# timeout: 30
# harnesses: [claude, codex, opencode, cursor]
# requires-skills: [orch]
# ---

set -euo pipefail

# Paths are matched by byte ranges below.
export LC_ALL=C

# What the lines name, empty until each is known.
TRANSCRIPT_FIELD=""
TRANSCRIPT=""
WORKTREE=""

# Every line this hook writes, and the only place its text lives. The first
# line is `dev-stop-check: <key>=<value>`; the English follows it, and then the
# cause a command this hook ran wrote, captured at the site.
message() { # KEY VALUE [DETAIL]
  {
    printf 'dev-stop-check: %s=%s\n' "$1" "$2"
    case "$1" in
      missing-tools)
        echo "the commands ${2//,/, } are required to read the hook payload and the transcript and are not on PATH, so this stop was not checked for a validation run still going"
        ;;
      payload)
        echo "the hook payload could not be read, or a field it reads is not a string; refusing rather than skipping the check"
        ;;
      transcript)
        echo "the payload's $TRANSCRIPT_FIELD [$TRANSCRIPT] could not be read, so this stop was not checked for a validation run still going"
        ;;
      reader)
        echo "orch's dev-validate-run is not installed with this hook, so this stop was not checked for a validation run still going; install the orch skill in the same scope"
        ;;
      running)
        echo "the validation run you started in $WORKTREE is still going. A subagent whose turn has ended is not woken when it ends, so its verdict would reach nobody and the round would be left uncommitted. Wait for it, repeating while it prints state=running:"
        printf '%s --wait --run-dir %s\n' "$READER" "$2"
        echo "then finish the round from the verdict it prints."
        ;;
      unread)
        echo "dev-validate-run could not say whether a validation run is still going in $2. If you started one there, wait for it with $READER --wait --run-dir <the run-dir its state=started line printed>; otherwise stop again."
        ;;
    esac
    [ -z "${3:-}" ] || printf '%s\n' "$3"
  } >&2
}

refuse() { # KEY VALUE [DETAIL]
  message "$@"
  exit 2
}

# A gap the subagent cannot close is reported, never held: a refusal it can do
# nothing about would hold every stop (hooks/AGENTS.md).
notice() { # KEY VALUE [DETAIL]
  message "$@"
  exit 0
}

MISSING=""
for dependency in jq git cat grep awk; do
  command -v "$dependency" >/dev/null 2>&1 || MISSING="$MISSING,$dependency"
done
[ -z "$MISSING" ] || notice missing-tools "${MISSING#,}"

INPUT=$(cat 2>&1) || refuse payload unreadable "$INPUT"

# The transcript is the subagent's own: Claude Code and Codex send it as
# `agent_transcript_path` beside a `transcript_path` naming the parent
# session's, and Codex sends the key null for a thread with no rollout, which
# reads as empty and is reported below.
FIELDS=$(printf '%s' "$INPUT" | jq -r '
  def str($v): if $v == null then "" elif ($v | type) == "string" then $v else error("not a string") end;
  (if has("agent_transcript_path") then "agent_transcript_path" else "transcript_path" end) as $field |
  [$field, str(.[$field]), (.stop_hook_active == true | tostring)] | @tsv' 2>/dev/null) ||
  refuse payload invalid-json
TAB=$'\t'
TRANSCRIPT_FIELD=${FIELDS%%"$TAB"*}
REST=${FIELDS#*"$TAB"}
TRANSCRIPT=${REST%%"$TAB"*}
ACTIVE=${REST#*"$TAB"}

[ "$ACTIVE" != true ] || exit 0

if [ ! -r "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ]; then
  notice transcript unreadable
fi

# Every worktree a command the subagent ran handed dev-validate-run, newest
# first and each once. The command, not its output: a Claude Code call that
# outlasts its timeout records only the path of the file its output goes to,
# never the run directory the start printed. A relative path or one holding a quote, a space or a
# backslash is not read; the dev workflows pass the absolute worktree path.
set +e
MENTIONS=$(grep -oE 'dev-validate-run[^"\\]* --worktree /[^"[:space:]\\]+' -- "$TRANSCRIPT" 2>&1)
GREP_RC=$?
set -e
case "$GREP_RC" in
  0) ;;
  1) exit 0 ;;
  *) notice transcript unread "$MENTIONS" ;;
esac
WORKTREES=$(printf '%s\n' "$MENTIONS" | awk '{ sub(/.* --worktree /, ""); seen[NR] = $0 }
  END { for (i = NR; i > 0; i--) if (!done[seen[i]]++) print seen[i] }')

unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || ROOT=""

# dev-validate-run comes from this hook's own install, by the walk
# hooks/command-safety.sh makes for the commit-guards library, copied here
# since each hook is installed as one file: from the hook's physical directory
# up five levels, stopping at the open repository's root and after the home
# directory, each level's `skills/` and shared `.agents/skills/` tree; then the
# home's shared tree, for a harness root moved out of the home; then the
# repository's own copy, only where this hook is installed in that repository.
SCRIPT=orch/scripts/dev-validate-run
case "${BASH_SOURCE[0]}" in
  */*) HOOK_DIR=${BASH_SOURCE[0]%/*} ;;
  *) HOOK_DIR=. ;;
esac
HOOK_DIR=$(cd -P -- "$HOOK_DIR" 2>/dev/null && pwd -P) || HOOK_DIR=""
HOME_DIR=$(cd -P -- "${HOME:-/}" 2>/dev/null && pwd -P) || HOME_DIR=""
AT=$HOOK_DIR
READER=""
LEVELS=0
while [ -n "$AT" ] && [ "$LEVELS" -lt 5 ] && [ "$AT" != "$ROOT" ] && [ "$AT" != / ]; do
  for candidate in "$AT/skills/$SCRIPT" "$AT/.agents/skills/$SCRIPT"; do
    if [ -x "$candidate" ]; then
      READER=$candidate
      break
    fi
  done
  { [ -z "$READER" ] && [ "$AT" != "$HOME_DIR" ]; } || break
  AT=${AT%/*}
  [ -n "$AT" ] || AT=/
  LEVELS=$((LEVELS + 1))
done
if [ -z "$READER" ] && [ -n "$HOME_DIR" ] && [ "$HOME_DIR" != "$ROOT" ] \
  && [ -x "$HOME_DIR/.agents/skills/$SCRIPT" ]; then
  READER="$HOME_DIR/.agents/skills/$SCRIPT"
fi
if [ -z "$READER" ] && [ -n "$ROOT" ] && [ -x "$ROOT/.agents/skills/$SCRIPT" ]; then
  case "$HOOK_DIR" in
    "$ROOT"/*) READER="$ROOT/.agents/skills/$SCRIPT" ;;
  esac
fi
[ -n "$READER" ] || notice reader "${HOOK_DIR:-unlocatable}"

while IFS= read -r WORKTREE; do
  # A worktree since removed holds no run directory, so no run to wait on.
  [ -d "$WORKTREE" ] || continue
  rc=0
  LIVE=$("$READER" --live --worktree "$WORKTREE" 2>&1) || rc=$?
  case "$rc" in
    0) ;;
    1) continue ;;
    *) refuse unread "$WORKTREE" "$LIVE" ;;
  esac
  RUN_DIR=${LIVE#run-dir=}
  RUN_DIR=${RUN_DIR% pid=*}
  refuse running "$RUN_DIR"
done <<EOF
$WORKTREES
EOF
