#!/usr/bin/env bash
# ---
# name: dev-stop-check
# event: SubagentStop
# matcher:
# description: Blocks a subagent's stop while a validation run it started is still going, naming the `dev-validate-run --wait --run-dir <run dir>` command to run next, because a subagent whose turn has ended is not woken when the run ends and its round is left with a verdict on disk and no commit. The worktrees are those the subagent's transcript names as `dev-validate-run ... --worktree <absolute path>` in a command it ran, read as the shell splits that command: the flag and the path are words of the same command as `dev-validate-run`, with no unquoted `;`, `&`, `|` or newline between them other than a redirection's `&`, and the path is bare, ending at whitespace or a shell metacharacter, or in single or double quotes; the transcript being the payload's `agent_transcript_path` where the payload carries that key (Claude Code and Codex, whose `transcript_path` is the parent session's) and its `transcript_path` where it does not; the run is the one orch's `dev-validate-run --live --worktree` reports there, the run a start would refuse as run-live, so a run that has its verdict, or whose child is gone, passes. A stop whose transcript names no such worktree, a worktree since removed, or no run still going passes silently. On `stop_hook_active` true, the harness's continued stop, a live run passes with an `abandoned=<run dir>` notice only where the transcript holds this hook's last hold for that run and no `dev-validate-run --wait --run-dir <that run dir>` call after it, the run dir read as the worktree is; every other live run is held as on a first stop. The harness records each hold in the transcript, so each further hold costs the subagent one bounded wait and the stops cannot spin. A `dev-validate-run` that cannot say whether a run is going, as one from an orch install older than `--live` cannot, holds the stop at exit 2 with its own words, and on a continued stop is reported at exit 0 instead. The `dev-validate-run` read comes from this hook's own install; a missing reader, a transcript that cannot be read and a missing tool are reported under their own key at exit 0, since the subagent can do nothing about them. Not run on copilot: its subagentStop names the lead's transcript, not the subagent's, so the worktree a subagent validated in cannot be read. Not run on pi: Pi 1.0.0's extension `types.ts` has no subagent event. Not run on gemini: it has no SubagentStop event. Not run on antigravity: it has no SubagentStop event.
# summary: Stops a coding agent from finishing while the validation run it started is still going, and hands it the command that waits for the verdict.
# safety: Reads the payload and the subagent's transcript, runs `git rev-parse` in the session's directory, and runs orch's `dev-validate-run --live`, which reads the worktree's run directories and the process table; it writes nothing. jq is required to read the payload. Exit 2 is one of three holds: a run still going, naming the run and the `--wait` command that ends the block; a `dev-validate-run` that cannot answer, naming the worktree and that reader's own words; and a payload that cannot be read or is not JSON, naming neither. Every line opens with `dev-stop-check: <key>=<value>`; what a command this hook runs writes is captured at the site and replayed under that line.
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
ACTIVE=""

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
      abandoned)
        echo "the validation run you started in $WORKTREE is still going, and this stop was already held for it with no --wait call on it since, so it passes: the run's verdict reaches nobody and the round is left uncommitted until it is recovered."
        ;;
      unread)
        printf 'dev-validate-run could not say whether a validation run is still going in %s. If you started one there, wait for it with %s --wait --run-dir <the run-dir its state=started line printed>' "$2" "$READER"
        if [ "$ACTIVE" = true ]; then echo .; else echo '; otherwise stop again.'; fi
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

if [ ! -r "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ]; then
  notice transcript unreadable
fi

# A recorded command is read as the shell splits it into words and commands,
# over the text the transcript keeps it in: a double quote escaped once in a
# Claude Code transcript's JSON and twice in a Codex rollout's arguments
# string, a single quote as itself, and a newline as an escaped `\n`.
DQUOTE='\\+"'
SQUOTE="'"
# A path is an absolute word. Bare, it ends where the shell ends an unquoted
# word, at whitespace or a metacharacter (`;`, `&`, `|`, `(`, `)`, `<`, `>`),
# so `<path>; echo $?`, `<path>&&git status`, `<path>)` and `<path>|tail` all
# give `<path>`; quoted, it is the whole span between a pair. A relative path,
# or one holding a quote, a space, a backslash or a metacharacter, is not
# read; the dev workflows pass the absolute worktree path, under which
# dev-validate-run makes its run directories.
PATH_RE="/[^[:space:]\"'\\\\&;|()<>]+"
VALUE_RE="($DQUOTE$PATH_RE$DQUOTE|$SQUOTE$PATH_RE$SQUOTE|$PATH_RE)"
# The words of one command: an unquoted `;`, `&` or `|`, or a newline, ends
# it, while a quoted word may hold any of them and the `&` of a redirection
# such as `2>&1` or `&>log` leaves the words one command. A parenthesis
# between dev-validate-run and its flags opens only a `$(...)`, whose output
# the shell hands to dev-validate-run as words.
REDIRECT_RE='&>|[<>]&'
WORDS_RE="([^\"'\\\\&;|]|$REDIRECT_RE|${DQUOTE}[^\"\\\\]*$DQUOTE|${SQUOTE}[^'\\\\]*$SQUOTE)*"

# The one reader of a path in the transcript: every path it gives as the
# value after PREFIX, an extended regular expression ending in the spaces or
# the `=` the value follows, as `<line> <path>` in transcript order, or exit 1
# for none.
transcript_paths() { # PREFIX
  local found rc=0
  found=$(grep -noE -- "$1$VALUE_RE" "$TRANSCRIPT" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || {
    printf '%s\n' "$found"
    return "$rc"
  }
  # The value is the run of path characters the match ends in, its closing
  # quote dropped.
  printf '%s\n' "$found" | PATH_RE=$PATH_RE awk '{ line = $0; sub(/:.*/, "", line)
    match($0, ENVIRON["PATH_RE"] "[\\\\\"'\'']*$"); value = substr($0, RSTART, RLENGTH)
    sub(/[\\\\"'\'']+$/, "", value); print line, value }'
}

# A dev-validate-run command giving FLAGS, in the order the dev workflows write
# them, each flag a word of that one command, as the PREFIX of its value.
command_prefix() { # FLAGS...
  local flag prefix="dev-validate-run($DQUOTE|$SQUOTE)?"
  for flag in "$@"; do
    prefix="$prefix$WORDS_RE +$flag"
  done
  printf '%s +' "$prefix"
}

# The last transcript line giving PATH after PREFIX, 0 for none, or
# transcript_paths' failure and its words.
last_line() { # PREFIX PATH
  local found rc=0
  found=$(transcript_paths "$1") || rc=$?
  case "$rc" in
    0) printf '%s\n' "$found" | awk -v path="$2" '$2 == path { at = $1 } END { print at + 0 }' ;;
    1) echo 0 ;;
    *)
      printf '%s\n' "$found"
      return "$rc"
      ;;
  esac
}

# Every worktree a command the subagent ran handed dev-validate-run, newest
# first and each once. The command, not its output: a Claude Code call that
# outlasts its timeout records only the path of the file its output goes to,
# never the run directory the start printed.
rc=0
MENTIONS=$(transcript_paths "$(command_prefix --worktree)") || rc=$?
case "$rc" in
  0) ;;
  1) exit 0 ;;
  *) notice transcript unread "$MENTIONS" ;;
esac
WORKTREES=$(printf '%s\n' "$MENTIONS" | awk '{ seen[NR] = $2 }
  END { for (i = NR; i > 0; i--) if (!done[seen[i]]++) print seen[i] }')

unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || ROOT=""

# dev-validate-run comes from this hook's own install, by the walk
# hooks/lane-mail-check.sh owns for its reader, copied here since each hook is
# installed as one file: from the hook's physical directory
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
    *)
      # A continued stop is not held again on what the subagent cannot change.
      [ "$ACTIVE" != true ] || notice unread "$WORKTREE" "$LIVE"
      refuse unread "$WORKTREE" "$LIVE"
      ;;
  esac
  RUN_DIR=${LIVE#run-dir=}
  RUN_DIR=${RUN_DIR% pid=*}
  [ "$ACTIVE" = true ] || refuse running "$RUN_DIR"
  # A continued stop lets the run go only where this hook already held it and
  # no --wait call on it came after, so a subagent that stops without waiting
  # is let go and each further hold costs it one bounded wait. The harness
  # records the hold in the subagent's transcript, Claude Code as a user
  # message, Codex as a hook prompt, on one line with the --wait command it
  # names, which a wait on that line therefore does not follow; a hold another
  # hook made counts as none of this hook's.
  HELD=$(last_line 'dev-stop-check: running=' "$RUN_DIR") || notice transcript unread "$HELD"
  WAITED=$(last_line "$(command_prefix --wait --run-dir)" "$RUN_DIR") ||
    notice transcript unread "$WAITED"
  { [ "$HELD" -gt 0 ] && [ "$WAITED" -le "$HELD" ]; } || refuse running "$RUN_DIR"
  notice abandoned "$RUN_DIR"
done <<EOF
$WORKTREES
EOF
