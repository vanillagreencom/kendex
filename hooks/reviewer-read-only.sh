#!/usr/bin/env bash
# ---
# name: reviewer-read-only
# event: PreToolUse
# matcher: Edit|MultiEdit|NotebookEdit|Write|Bash
# description: For a subagent whose agent_type starts with `reviewer-`, refuses every Edit, MultiEdit and NotebookEdit call; a Write whose path lies inside a git work tree unless it is the review artifact, `<dir>/tmp/review-*.json`; and a Bash command that runs `git commit` or `git push` (options between `git` and the verb allowed). Any other agent, and a payload naming no agent_type, passes. Claude Code only, the harness that names the calling subagent in the payload.
# safety: Reads the payload and asks git whether a path is inside a work tree; writes nothing. A payload it cannot read is refused, never skipped. The refusal names the artifact path a reviewer may write and never suggests bypassing.
# timeout: 10
# harnesses: [claude-code]
# ---

set -euo pipefail

# Paths and command text are matched by byte ranges below; git's own
# messages are read in English.
export LC_ALL=C

# jq is the only reader of the payload; git answers whether a path is inside
# a work tree. Without them the call cannot be judged, and an unjudged call
# is refused rather than let through.
if ! command -v jq >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
  echo "reviewer-read-only: jq and git are required to read the hook payload and judge the path; refusing rather than skipping the guard" >&2
  exit 2
fi

INPUT=$(cat) || {
  echo "reviewer-read-only: could not read the hook payload from stdin" >&2
  exit 2
}

# One jq read for the strings the decision needs. A payload that does not
# parse, or whose agent_type or tool_name is not a string, is refused.
if ! FIELDS=$(printf '%s' "$INPUT" | jq -r '
  def str($v): if $v == null then "" elif ($v | type) == "string" then $v else error("not a string") end;
  [str(.agent_type), str(.tool_name)] | @tsv' 2>/dev/null); then
  echo "reviewer-read-only: hook payload is not valid JSON, or its agent_type or tool_name is not a string; refusing rather than skipping the guard" >&2
  exit 2
fi
TAB=$'\t'
AGENT_TYPE=${FIELDS%%"$TAB"*}
TOOL_NAME=${FIELDS#*"$TAB"}

case "$AGENT_TYPE" in
  reviewer-*) ;;
  *) exit 0 ;;
esac

case "$TOOL_NAME" in
  Edit | MultiEdit | NotebookEdit)
    echo "reviewer-read-only: a reviewer edits nothing. Findings go in the review artifact, written with the Write tool to <worktree>/tmp/review-$AGENT_TYPE-<timestamp>.json; the fix is the author's." >&2
    exit 2
    ;;
  Write)
    if ! TARGET=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path
      | if type == "string" then . else error("not a string") end' 2>/dev/null); then
      echo "reviewer-read-only: the Write payload names no file_path string; refusing rather than skipping the guard" >&2
      exit 2
    fi
    case "$TARGET" in
      */tmp/review-*.json) exit 0 ;;
    esac
    # Inside a work tree or not is asked of the nearest directory that
    # exists, since Write creates the missing ones. "Not a git repository" is
    # the pass; any other failure is a git that could not answer.
    DIR=$(dirname -- "$TARGET")
    while [ ! -d "$DIR" ] && [ "$DIR" != "/" ] && [ "$DIR" != "." ]; do
      DIR=$(dirname -- "$DIR")
    done
    if ANSWER=$(git -C "$DIR" rev-parse --is-inside-work-tree 2>&1); then
      if [ "$ANSWER" != "true" ]; then
        exit 0
      fi
      echo "reviewer-read-only: a reviewer writes nothing into a repository but its artifact, <worktree>/tmp/review-$AGENT_TYPE-<timestamp>.json; $TARGET is not that path. A control file goes under a mktemp -d of your own." >&2
      exit 2
    fi
    case "$ANSWER" in
      *"not a git repository"*) exit 0 ;;
    esac
    echo "reviewer-read-only: git could not say whether $TARGET is inside a work tree, so the write is refused:" >&2
    printf '%s\n' "$ANSWER" >&2
    exit 2
    ;;
  Bash)
    if ! COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command
      | if . == null then "" elif type == "string" then . else error("not a string") end' 2>/dev/null); then
      echo "reviewer-read-only: the Bash payload names a command that is not a string; refusing rather than skipping the guard" >&2
      exit 2
    fi
    # `git`, then any run of options (a value-taking one with its value),
    # then the verb as its own word. `git cat-file commit` and `git
    # commit-tree` are reads and do not match.
    GIT_WRITE='(^|[^[:alnum:]_.-])git([[:space:]]+(-C|-c|--git-dir|--work-tree|--namespace|--exec-path)[[:space:]]+[^[:space:]]+|[[:space:]]+-[^[:space:]]*)*[[:space:]]+(commit|push)([[:space:]]|$|[;|)&])'
    # Never `grep -q` here: an early exit turns the producer's SIGPIPE into
    # status 141 under pipefail, read as no match.
    if printf '%s\n' "$COMMAND" | grep -E -- "$GIT_WRITE" >/dev/null; then
      echo "reviewer-read-only: a reviewer commits and pushes nothing; the orchestrator owns the branch. Report the finding in the review artifact instead." >&2
      exit 2
    fi
    exit 0
    ;;
esac

exit 0
