#!/usr/bin/env bash
# ---
# name: reviewer-stop-check
# event: SubagentStop
# matcher:
# description: Blocks a reviewer subagent's stop once when the worktree it reviewed is not clean. The worktree is the one the artifact path in the subagent's transcript names (`<worktree>/tmp/review-<agent>-*.json`, the newest mention); `git status --porcelain --untracked-files=all` there listing anything blocks, naming each path, and a transcript naming no artifact path blocks the same way, since the review contract is an artifact at that path. An agent_type not starting with `reviewer-` passes, as does `stop_hook_active` true; a block is recorded per agent_id under `<git common dir>/kendex/reviewer-stop/` so a later stop of the same subagent passes. Claude Code only, the harness with a SubagentStop event that names the agent.
# safety: Reads the payload, the transcript and git status; the only write is the per-agent marker under the reviewed repository's git common dir. Exit 2 names the paths and asks for the reviewer's own files to be deleted and the rest reported, never bypassed. jq is required to read the payload; a payload, transcript or git that cannot be read is refused, never passed.
# timeout: 30
# harnesses: [claude-code]
# ---

set -euo pipefail

# Agent ids and paths are matched by byte ranges below; a locale that reads
# them as something else changes what a filename may hold.
export LC_ALL=C

if ! command -v jq >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
  echo "reviewer-stop-check: jq and git are required to read the hook payload and the worktree; refusing rather than skipping the guard" >&2
  exit 2
fi

INPUT=$(cat) || {
  echo "reviewer-stop-check: could not read the hook payload from stdin" >&2
  exit 2
}

if ! FIELDS=$(printf '%s' "$INPUT" | jq -r '
  def str($v): if $v == null then "" elif ($v | type) == "string" then $v else error("not a string") end;
  [str(.agent_type), str(.agent_id), str(.transcript_path), (.stop_hook_active == true | tostring)] | @tsv' 2>/dev/null); then
  echo "reviewer-stop-check: hook payload is not valid JSON, or a field it reads is not a string; refusing rather than skipping the guard" >&2
  exit 2
fi
TAB=$'\t'
AGENT_TYPE=${FIELDS%%"$TAB"*}
REST=${FIELDS#*"$TAB"}
AGENT_ID=${REST%%"$TAB"*}
REST=${REST#*"$TAB"}
TRANSCRIPT=${REST%%"$TAB"*}
ACTIVE=${REST#*"$TAB"}

case "$AGENT_TYPE" in
  reviewer-*) ;;
  *) exit 0 ;;
esac
if [ "$ACTIVE" = "true" ]; then
  exit 0
fi

AGENT_SHAPE='^[A-Za-z0-9._-]+$'
if ! [[ "$AGENT_ID" =~ $AGENT_SHAPE ]]; then
  echo "reviewer-stop-check: the payload carries no usable agent_id, so a block could not be recorded; refusing" >&2
  exit 2
fi
if [ ! -r "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ]; then
  echo "reviewer-stop-check: the payload's transcript_path is not a readable file, so the reviewed worktree is unknown; refusing" >&2
  exit 2
fi

git_failed() { # SUBCOMMAND OUTPUT — an unreadable answer is never a clean one
  echo "reviewer-stop-check: git $1 failed, so the reviewed worktree's state is unknown:" >&2
  printf '%s\n' "$2" >&2
  exit 2
}

# The block is recorded once per subagent. The marker lives under the git
# common dir of the reviewed repository once that is known, and of the
# repository the hook runs in before then; both are shared by every linked
# worktree.
MARKER_REPO=.
record_and_block() { # MESSAGE-LINES on stdin
  COMMON_DIR=$(git -C "$MARKER_REPO" rev-parse --git-common-dir 2>&1) ||
    git_failed "-C $MARKER_REPO rev-parse --git-common-dir" "$COMMON_DIR"
  case "$COMMON_DIR" in
    /*) ;;
    *) COMMON_DIR="$MARKER_REPO/$COMMON_DIR" ;;
  esac
  MARKER_DIR="$COMMON_DIR/kendex/reviewer-stop"
  MARKER="$MARKER_DIR/$AGENT_ID"
  if [ -e "$MARKER" ]; then
    exit 0
  fi
  if ! mkdir -p -- "$MARKER_DIR" || ! : >"$MARKER"; then
    echo "reviewer-stop-check: could not record the marker $MARKER, so a second stop could not be told from the first" >&2
    exit 2
  fi
  cat >&2
  exit 2
}

# The newest artifact path the transcript mentions: the Write call's
# file_path, the File: line of the return message, either one. A path
# holding a quote, a space or a backslash is not read; none of the
# generated artifact paths hold one.
set +e
MENTIONS=$(grep -oE '(/[^/"[:space:]\\]+)+/tmp/review-[^/"[:space:]\\]*\.json' -- "$TRANSCRIPT")
GREP_RC=$?
set -e
case "$GREP_RC" in
  0) ;;
  1)
    record_and_block <<EOF
reviewer-stop-check: the transcript names no review artifact path (<worktree>/tmp/review-$AGENT_TYPE-<timestamp>.json), so the reviewed worktree cannot be checked for files you left behind. Write the artifact to that path, delete every probe you created, and finish.
EOF
    ;;
  *)
    echo "reviewer-stop-check: could not read the transcript $TRANSCRIPT; refusing" >&2
    exit 2
    ;;
esac
ARTIFACT=$(printf '%s\n' "$MENTIONS" | tail -n 1)
WORKTREE=${ARTIFACT%/tmp/review-*}

if ! TOPLEVEL=$(git -C "$WORKTREE" rev-parse --show-toplevel 2>&1); then
  git_failed "-C $WORKTREE rev-parse --show-toplevel" "$TOPLEVEL"
fi
MARKER_REPO=$WORKTREE
STATUS=$(git -C "$WORKTREE" status --porcelain --untracked-files=all 2>&1) ||
  git_failed "-C $WORKTREE status" "$STATUS"
if [ -z "$STATUS" ]; then
  exit 0
fi

record_and_block <<EOF
reviewer-stop-check: the reviewed worktree $TOPLEVEL is not clean:
$STATUS
Delete every file you created (a control belongs under a mktemp -d of your own) and report any change that was there before you; then finish.
EOF
