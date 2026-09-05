#!/usr/bin/env bash
# ---
# name: block-worktree-refresh
# event: PreToolUse
# matcher: Bash
# description: Refuse a `kendex` command that writes the project scope (`refresh`, `apply`, `add`, `remove`, `update-pi`) when the working directory is a linked git worktree and the command does not name the global scope. A project's kendex install is registered to the main checkout, so a project-scope write from a linked worktree renders into that checkout and removes what it does not expect there. Names the two forms that are right: the same command from the main checkout, or `--scope global` for a global change.
# safety: Reads the command text and asks git whether the working directory's git dir differs from its common dir, which is what makes a worktree linked; writes nothing. A git that cannot answer refuses. The verb is read as a word after a `kendex` word, wherever in the command it stands, so a command that merely spells the pair in prose is refused, and that is the accepted cost. `kendex verify`, `check`, `list`, `report` and every other verb pass; a command carrying `-g`, `--global` or `--scope global` in the verb's own segment passes because it names the scope this hook does not guard. A payload that cannot be read, an empty one included, is refused, never skipped.
# timeout: 10
# ---

set -euo pipefail

# jq reads the payload and git answers the one question. Without either the
# command cannot be judged, and an unjudged command is refused.
if ! command -v jq >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1 || ! command -v cat >/dev/null 2>&1; then
  echo "block-worktree-refresh: jq, git and cat are required to read the hook payload and the worktree; refusing rather than skipping the guard" >&2
  exit 2
fi

INPUT=$(cat) || {
  echo "block-worktree-refresh: could not read the hook payload from stdin; refusing rather than skipping the guard" >&2
  exit 2
}
# An empty payload is no payload: jq reads nothing from it and says nothing,
# which would pass as an absent command.
case "$INPUT" in
  *[![:space:]]*) ;;
  *)
    echo "block-worktree-refresh: the hook payload is empty; refusing rather than skipping the guard" >&2
    exit 2
    ;;
esac

# A payload that does not parse, or that names a command which is not a
# string, is refused rather than skipped. An absent command is the empty
# string and passes. The command is read where each harness carries it:
# `tool_input.command` (Claude Code, Codex, Gemini CLI and the Pi carrier), a
# bare `command`, or Copilot's `toolArgs.command`, whose `toolArgs` arrives as
# an object or as one JSON-encoded string. The null tests are spelled out
# because jq's `//` reads `false` as absent, and `false` is not a command
# either.
if ! COMMAND=$(printf '%s' "$INPUT" \
  | jq -r 'def copilot: .toolArgs
             | if . == null then null elif type == "string" then fromjson else . end
             | if . == null then null elif type == "object" then .command else error end;
           if .tool_input.command != null then .tool_input.command
           elif .command != null then .command
           elif copilot != null then copilot
           else "" end
           | if type == "string" then . else error end' 2>/dev/null); then
  echo "block-worktree-refresh: hook payload is not valid JSON, or names a command that is not a string; refusing rather than skipping the guard" >&2
  exit 2
fi

# The verb as a word after a `kendex` word, judged one segment at a time: a
# segment is the text between two of `;`, `&`, `|` and a line end, with a
# backslash-newline continuing it. The global scope is not this hook's, and
# `-g`, `--global` or `--scope global` exempts a write only when it stands in
# the same segment as the verb; read across the whole command it would let
# `kendex refresh -g && kendex refresh` through on the first command's word.
NL=$'\n'
SEGMENTS=${COMMAND//\\$NL/ }
SEGMENTS=${SEGMENTS//;/$NL}
SEGMENTS=${SEGMENTS//&/$NL}
SEGMENTS=${SEGMENTS//\|/$NL}
WRITE_RE='(^|[^[:alnum:]_.-])kendex[[:space:]]+(refresh|apply|add|remove|update-pi)([[:space:]]|$)'
GLOBAL_RE='(^|[[:space:]])(-g|--global|--scope([[:space:]]+|=)global)([[:space:]]|$)'
VERB=""
while IFS= read -r SEGMENT; do
  [[ $SEGMENT =~ $WRITE_RE ]] || continue
  # The verb is taken before the scope test, which resets BASH_REMATCH.
  FOUND=${BASH_REMATCH[2]}
  [[ $SEGMENT =~ $GLOBAL_RE ]] && continue
  VERB=$FOUND
  break
done <<EOF
$SEGMENTS
EOF
if [ -z "$VERB" ]; then
  exit 0
fi

# The working directory is the payload's cwd where the harness sends one
# (Claude Code, Codex, Gemini CLI and Copilot), else the directory the hook
# runs in (the Pi carrier).
if ! CWD=$(printf '%s' "$INPUT" \
  | jq -r 'if .cwd == null then "" elif (.cwd | type) == "string" then .cwd else error end' 2>/dev/null); then
  echo "block-worktree-refresh: the payload's cwd is not a string; refusing rather than skipping the guard" >&2
  exit 2
fi
[ -n "$CWD" ] || CWD=$PWD

# Git answers for the directory itself: the redirect variables that would make
# it answer for another repository are dropped, as kendex drops them, and its
# messages are read in English.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_CEILING_DIRECTORIES
export LC_ALL=C
# Outside a repository there is no worktree to protect and kendex answers for
# itself. Git names that case with a parenthetical on the parents it searched
# (the parent directories, or the parents up to a mount point); a `.git` file
# that points nowhere gets the same words without it, and that is a repository
# git could not read, not the absence of one. Any other failure is a git that
# could not answer, and an unanswered question refuses. The answer is read
# from stdout alone; the reason for a failure is read from stderr only once
# there is one, so tracing git cannot turn an answer into a refusal.
if ! DIRS=$(git -C "$CWD" rev-parse --git-dir --git-common-dir 2>/dev/null); then
  REASON_STATUS=0
  REASON=$(git -C "$CWD" rev-parse --git-dir --git-common-dir 2>&1 >/dev/null) || REASON_STATUS=$?
  case "$REASON" in
    *"not a git repository (or any"*) exit 0 ;;
  esac
  echo "block-worktree-refresh: git could not say whether $CWD is a linked worktree (exit $REASON_STATUS), so the write is refused:" >&2
  printf '%s\n' "$REASON" >&2
  exit 2
fi
GIT_DIR_LINE=${DIRS%%$'\n'*}
COMMON_DIR_LINE=${DIRS#*$'\n'}
# Both answers are relative to CWD when git prints them short; resolving each
# to a physical path is what lets the comparison hold across symlinked roots.
resolve() { # PATH -> physical path on stdout, relative to CWD when relative
  case "$1" in
    /*) (cd -- "$1" && pwd -P) ;;
    *) (cd -- "$CWD/$1" && pwd -P) ;;
  esac
}
if ! GIT_DIR=$(resolve "$GIT_DIR_LINE") || ! COMMON_DIR=$(resolve "$COMMON_DIR_LINE"); then
  echo "block-worktree-refresh: the git directories git named under $CWD could not be entered, so the write is refused" >&2
  exit 2
fi
if [ "$GIT_DIR" = "$COMMON_DIR" ]; then
  exit 0
fi

MAIN=${COMMON_DIR%/.git}
{
  echo "block-worktree-refresh: refusing 'kendex $VERB' at project scope from the linked worktree $CWD."
  echo "  The project install is registered to the main checkout, $MAIN; a project-scope write from here renders into that checkout and removes what it does not expect there."
  echo "  Run the same command from $MAIN, or pass --scope global for a global change. Reads (kendex verify, check, list) are not refused."
} >&2
exit 2
