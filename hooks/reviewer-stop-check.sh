#!/usr/bin/env bash
# ---
# name: reviewer-stop-check
# event: SubagentStop
# matcher:
# description: Blocks a reviewer subagent's stop once when the worktree it reviewed is not clean. The worktree is the one the artifact path in the subagent's transcript names (`<worktree>/tmp/review-<agent>-*.json`, the newest mention); `git status --porcelain --untracked-files=all` there listing anything blocks, naming each path, and a transcript naming no artifact path blocks the same way, since the review contract is an artifact at that path. An agent_type not starting with `reviewer-` passes, as does `stop_hook_active` true; a block is recorded per agent_id under `<git common dir>/kendex/reviewer-stop/` so a later stop of the same subagent passes. Claude Code only, the harness with a SubagentStop event that names the agent.
# safety: Reads the payload, the transcript and git status; the only write is the per-agent marker under the reviewed repository's git common dir. Exit 2 names the paths and asks for the reviewer's own files to be deleted and the rest reported, never bypassed. jq is required to read the payload; a payload, transcript or git that cannot be read is refused, never passed. Every refusal opens with `reviewer-stop-check: <key>=<value>`; what a command this hook runs writes is captured at the site and replayed under that line, so nothing precedes the key.
# timeout: 30
# harnesses: [claude-code]
# ---

set -euo pipefail

# Agent ids and paths are matched by byte ranges below; a locale that reads
# them as something else changes what a filename may hold.
export LC_ALL=C

# What the refusals name, empty until each is known: the calling subagent,
# whose type names the artifact path, the transcript the worktree is read
# from, and the worktree's own dirty paths.
AGENT_TYPE=""
TRANSCRIPT=""
STATUS=""
# Every line this hook writes, and the only place its text lives. The first
# line is the contract a reader parses, `reviewer-stop-check: <key>=<value>`: a
# stable key for the condition and the value acted on — the missing tool, why
# the payload could not be read, the git subcommand that failed, the marker
# path, or the worktree that is not clean. The English explanation and what to
# do about it follow it, and never a bypass.
# The keyed line stands first, at position 1. What a command this hook runs
# wrote is captured where the hook reads it and passed here as the cause, so
# it is replayed under the key rather than ahead of it.
refuse() { # KEY VALUE [DETAIL]
  {
    printf 'reviewer-stop-check: %s=%s\n' "$1" "$2"
    case "$1=$2" in
      missing-tools=*)
        echo "the commands ${2//,/, } are required to read the hook payload and the worktree and are not on PATH; refusing rather than skipping the guard"
        ;;
      payload=unreadable)
        echo "the hook payload could not be read from stdin"
        ;;
      payload=invalid-json)
        echo "the hook payload is not valid JSON, or a field it reads is not a string; refusing rather than skipping the guard"
        ;;
      agent-id=invalid)
        echo "the payload carries no usable agent_id, so a block could not be recorded; refusing"
        ;;
      transcript=unreadable)
        echo "the payload's transcript_path $TRANSCRIPT is not a readable file, so the reviewed worktree is unknown; refusing"
        ;;
      transcript=unread)
        echo "the transcript $TRANSCRIPT could not be read; refusing"
        ;;
      artifact=missing)
        echo "the transcript names no review artifact path (<worktree>/tmp/review-$AGENT_TYPE-<timestamp>.json), so the reviewed worktree cannot be checked for files you left behind. Write the artifact to that path, delete every probe you created, and finish."
        ;;
      marker=*)
        echo "the marker $2 could not be recorded, so a second stop could not be told from the first"
        ;;
      worktree=*)
        echo "the reviewed worktree $2 is not clean:"
        printf '%s\n' "$STATUS"
        echo "Delete every file you created (a control belongs under a mktemp -d of your own) and report any change that was there before you; then finish."
        ;;
      git=*)
        echo "git $2 failed, so the reviewed worktree's state is unknown:"
        ;;
    esac
    # The cause a command this hook ran wrote, captured at the site and
    # replayed here: under the keyed line, never ahead of it.
    [ -z "${3:-}" ] || printf '%s\n' "$3"
  } >&2
  exit 2
}

# Every external command this hook runs. jq reads the payload and git answers
# for the worktree; cat hands the payload over, grep finds the artifact paths in
# the transcript, tail takes the newest, and mkdir records the marker. An
# unchecked absence is not a stall but a pass: a missing tail aborts the
# artifact assignment on a status the harness runs past. So the whole set is
# checked before anything is judged, and the value names every one of them the
# PATH is missing, in the order checked.
MISSING=""
for dependency in jq git cat grep tail mkdir; do
  command -v "$dependency" >/dev/null 2>&1 || MISSING="$MISSING,$dependency"
done
[ -z "$MISSING" ] || refuse missing-tools "${MISSING#,}"

# cat's words are captured, not left to precede the refusal: on failure the
# substitution holds what it wrote, and the refusal replays it under the keyed
# line. A cat that succeeds is silent, so the payload is not mixed with a
# diagnostic on the passing side.
INPUT=$(cat 2>&1) || refuse payload unreadable "$INPUT"

FIELDS=$(printf '%s' "$INPUT" | jq -r '
  def str($v): if $v == null then "" elif ($v | type) == "string" then $v else error("not a string") end;
  [str(.agent_type), str(.agent_id), str(.transcript_path), (.stop_hook_active == true | tostring)] | @tsv' 2>/dev/null) ||
  refuse payload invalid-json
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
  refuse agent-id invalid
fi
if [ ! -r "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ]; then
  refuse transcript unreadable
fi

git_failed() { # SUBCOMMAND OUTPUT — an unreadable answer is never a clean one
  refuse git "$1" "$2"
}

# The block is recorded once per subagent. The marker lives under the git
# common dir of the reviewed repository once that is known, and of the
# repository the hook runs in before then; both are shared by every linked
# worktree.
MARKER_REPO=.
record_and_block() { # KEY VALUE
  COMMON_DIR=$(git -C "$MARKER_REPO" rev-parse --git-common-dir 2>&1) ||
    git_failed 'rev-parse --git-common-dir' "$COMMON_DIR"
  case "$COMMON_DIR" in
    /*) ;;
    *) COMMON_DIR="$MARKER_REPO/$COMMON_DIR" ;;
  esac
  MARKER_DIR="$COMMON_DIR/kendex/reviewer-stop"
  MARKER="$MARKER_DIR/$AGENT_ID"
  if [ -e "$MARKER" ]; then
    exit 0
  fi
  # Both probes are captured rather than left to write first: the group runs
  # the redirection in a subshell so the shell's own "cannot create" reaches
  # the same variable mkdir's message would.
  if ! MARKER_ERR=$(mkdir -p -- "$MARKER_DIR" 2>&1) ||
    ! MARKER_ERR=$( { : >"$MARKER"; } 2>&1 ); then
    refuse marker "$MARKER" "$MARKER_ERR"
  fi
  refuse "$1" "$2"
}

# The newest artifact path the transcript mentions: the Write call's
# file_path, the File: line of the return message, either one. A path
# holding a quote, a space or a backslash is not read; none of the
# generated artifact paths hold one.
set +e
MENTIONS=$(grep -oE '(/[^/"[:space:]\\]+)+/tmp/review-[^/"[:space:]\\]*\.json' -- "$TRANSCRIPT" 2>&1)
GREP_RC=$?
set -e
case "$GREP_RC" in
  0) ;;
  1) record_and_block artifact missing ;;
  # A grep that could not read the transcript wrote its reason where its
  # matches would have gone, so MENTIONS carries the cause.
  *) refuse transcript unread "$MENTIONS" ;;
esac
ARTIFACT=$(printf '%s\n' "$MENTIONS" | tail -n 1)
WORKTREE=${ARTIFACT%/tmp/review-*}

if ! TOPLEVEL=$(git -C "$WORKTREE" rev-parse --show-toplevel 2>&1); then
  git_failed 'rev-parse --show-toplevel' "$TOPLEVEL"
fi
MARKER_REPO=$WORKTREE
STATUS=$(git -C "$WORKTREE" status --porcelain --untracked-files=all 2>&1) ||
  git_failed status "$STATUS"
if [ -z "$STATUS" ]; then
  exit 0
fi

record_and_block worktree "$TOPLEVEL"
