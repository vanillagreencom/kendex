#!/usr/bin/env bash
# ---
# name: reviewer-stop-check
# event: SubagentStop
# matcher:
# description: Blocks a reviewer subagent's stop once when it leaves no readable review artifact or leaves files behind in the worktree it reviewed. The worktree is the one the artifact path in the subagent's transcript names (`<worktree>/tmp/review-<agent>-*.json`, the newest mention), the transcript being the payload's `agent_transcript_path` where the payload carries that key (Claude Code and Codex, whose `transcript_path` is the parent session's), a null one refused, and its `transcript_path` where it does not. The review contract is the artifact, not its mention: a transcript naming no artifact path, or naming one that does not exist or does not parse as JSON, blocks. `git status --porcelain --untracked-files=all` there listing a path the reviewer's run created or changed blocks, naming each path; a path is the reviewer's when its status-change time (ctime, which a write, chmod or rename sets), or for a deleted path its nearest existing directory's, is not before the review started, the `timestamp` of the subagent transcript's first entry where that entry is a launch record (Codex `session_meta`, Claude Code's prompt) rather than a completed tool call, and an index-side change is the reviewer's while the index's own ctime is not before that start, so a path the author left dirty or staged before the review does not block; a directory row (a submodule), a quoted path or an unreadable time counts. Where that start cannot be read, Copilot among them, every dirty path counts. An agent_type not starting with `reviewer-` passes, as does `stop_hook_active` true; a block is recorded per agent_id under `<git common dir>/kendex/reviewer-stop/` so a later stop of the same subagent passes. On Copilot it runs at subagentStop, whose payload on Copilot CLI 1.0.91 names the custom agent as `agentType` and the subagent's own session as `agentId`, carries no `stop_hook_active`, which the per-agent record stands in for: there a refusal once the agent id is read is recorded under that marker wherever the hook finds and can write a git common dir, so the same subagent's next stop passes as Claude Code's continued stop does at the flag. It names the lead's transcript, so the artifact path is read from the subagent's reply, the payload's `response`, and the block is `decision: block` on stdout at exit 0, built without jq so a missing jq still holds the subagent, the answer Copilot takes, where exit 2 lets the subagent finish. Not run on pi: Pi 1.0.0's extension `types.ts` has no subagent event. Not run on gemini: it has no SubagentStop event. Not run on antigravity: it has no SubagentStop event.
# summary: Stops a reviewer agent from finishing while the worktree it reviewed still holds files it left behind.
# safety: Reads the payload, the transcript or on Copilot the subagent's reply, the review artifact, git status and the dirty paths' and the index's change times; the only write is the per-agent marker under the reviewed repository's git common dir. Exit 2 names the paths and asks for the reviewer's own files to be deleted and the rest reported, never bypassed. jq is required to read the payload; a payload, transcript or git that cannot be read is refused, never passed, and so is an `agent_id` that is not a string of ASCII letters, digits, `_` and `-`, the alphabet the harness names subagents in; it is judged in jq where the payload holds it, so a NUL, a `/`, a newline, `.` or `..` never reaches the marker path, whatever encoding the read passes through. Every refusal opens with `reviewer-stop-check: <key>=<value>`; what a command this hook runs writes is captured at the site and replayed under that line, so nothing precedes the key.
# timeout: 30
# harnesses: [claude, codex, copilot, opencode, cursor]
# ---

set -euo pipefail

# Agent ids and paths are matched by byte ranges below; a locale that reads
# them as something else changes what a filename may hold.
export LC_ALL=C

# Which harness this install serves comes from where it is installed, as
# hooks/lane-mail-check.sh reads it: `hook_target` in
# `crates/core/src/engine/targets.rs` writes the copilot copy under
# `.github/hooks` at project scope, and at global scope beside the registry
# document `<name>.json` that only a copilot install leaves. Read first,
# because it decides the shape of every refusal.
INSTALL=""
case "${BASH_SOURCE[0]%/*}" in
  */.github/hooks) INSTALL=copilot ;;
esac
if [ -z "$INSTALL" ] && [ -f "${BASH_SOURCE[0]%.sh}.json" ]; then INSTALL=copilot; fi

# What the refusals name, empty until each is known: the calling subagent,
# whose type names the artifact path, the payload field the transcript is
# read from and the transcript itself, what the artifact path is read out of,
# and the worktree's own dirty paths.
AGENT_TYPE=""
TRANSCRIPT_FIELD=""
TRANSCRIPT=""
ARTIFACT_SOURCE="transcript"
ARTIFACT=""
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
message() { # KEY VALUE [DETAIL]
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
        echo "the payload's agent_id is not spelled in the alphabet the harness names subagents in, ASCII letters, digits, underscore and hyphen, so the marker a block would be recorded under is not this subagent's; refusing"
        ;;
      transcript=unreadable)
        echo "the payload's $TRANSCRIPT_FIELD [$TRANSCRIPT] is not a readable file, so the reviewed worktree is unknown; refusing"
        ;;
      transcript=unread)
        echo "the transcript $TRANSCRIPT could not be read; refusing"
        ;;
      artifact=unreadable)
        echo "the review artifact $ARTIFACT the $ARTIFACT_SOURCE names does not exist or does not parse as JSON, so the review it reports cannot be read. Write the review as JSON to that path, delete every probe you created, and finish."
        ;;
      artifact=missing)
        echo "the $ARTIFACT_SOURCE names no review artifact path (<worktree>/tmp/review-$AGENT_TYPE-<timestamp>.json), so the reviewed worktree cannot be checked for files you left behind. Write the artifact to that path, name it on the File: line of your reply, delete every probe you created, and finish."
        ;;
      marker=*)
        echo "the marker $2 could not be recorded, so a second stop could not be told from the first"
        ;;
      worktree=*)
        echo "the reviewed worktree $2 holds paths changed since the review started (every dirty path, where the start could not be read):"
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
  }
}

# TEXT as one JSON string, in the shell alone, so the block answer stands
# where jq is the missing tool: a copy of lane-mail-check.sh::json_string,
# since each hook is installed as one file.
json_string() { # TEXT
  local s="$1" bs=\\ q='"' octal c u
  s=${s//"$bs"/"$bs$bs"}
  s=${s//"$q"/"$bs$q"}
  for octal in 001 002 003 004 005 006 007 010 011 012 013 014 015 016 017 \
      020 021 022 023 024 025 026 027 030 031 032 033 034 035 036 037; do
    printf -v c '%b' "\\0$octal"
    printf -v u '\\u%04x' "0$octal"
    s=${s//"$c"/$u}
  done
  printf '"%s"' "$s"
}

# Set on a Copilot install once the agent id is read. Copilot's subagentStop
# carries no stop_hook_active, so from there every refusal goes through the
# per-agent marker record_and_block keeps, and the same subagent's next stop
# passes as Claude Code's continued stop passes at the flag.
MARK_EVERY_REFUSAL=0

# The one exit for a block. The text goes to stderr, which every harness but
# Copilot reads beside exit 2. Copilot lets a subagent finish on exit 2 and
# holds it on `decision: block` with the text as `reason` on stdout at exit 0,
# the subagentStop answer its hooks reference gives (lane-mail-check.sh::refuse).
refuse() { # KEY VALUE [DETAIL]
  local text
  [ "$MARK_EVERY_REFUSAL" -eq 0 ] || record_and_block "$@"
  text=$(message "$@")
  printf '%s\n' "$text" >&2
  if [ "$INSTALL" = copilot ]; then
    printf '{"decision":"block","reason":%s}\n' "$(json_string "$text")"
    exit 0
  fi
  exit 2
}

git_failed() { # SUBCOMMAND OUTPUT — an unreadable answer is never a clean one
  refuse git "$1" "$2"
}

# The block is recorded once per subagent. The marker lives under the git
# common dir of the reviewed repository once that is known, and of the
# repository the hook runs in before then; both are shared by every linked
# worktree. Reached from refuse as well, which it calls in turn, so it turns
# that routing off before it can refuse.
MARKER_REPO=.
record_and_block() { # KEY VALUE [DETAIL]
  MARK_EVERY_REFUSAL=0
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
  refuse "$@"
}

# Every external command this hook runs. jq reads the payload, the artifact
# and the review's start and git answers for the worktree; cat hands the
# payload over, grep finds the artifact paths in the transcript, tail takes the
# newest, stat reads a dirty path's change time, and mkdir records the
# marker. An
# unchecked absence is not a stall but a pass: a missing tail aborts the
# artifact assignment on a status the harness runs past. So the whole set is
# checked before anything is judged, and the value names every one of them the
# PATH is missing, in the order checked.
MISSING=""
for dependency in jq git cat grep tail stat mkdir; do
  command -v "$dependency" >/dev/null 2>&1 || MISSING="$MISSING,$dependency"
done
[ -z "$MISSING" ] || refuse missing-tools "${MISSING#,}"

# cat's words are captured, not left to precede the refusal: on failure the
# substitution holds what it wrote, and the refusal replays it under the keyed
# line. A cat that succeeds is silent, so the payload is not mixed with a
# diagnostic on the passing side.
INPUT=$(cat 2>&1) || refuse payload unreadable "$INPUT"

# The agent id names the marker a block is recorded under, so it is judged
# where the payload holds it rather than after an encoding has carried it to
# the shell: no spelling outside the alphabet reaches the marker path,
# whatever that encoding does. The encoding here is @tsv, which escapes a
# NUL, a tab, a newline, a carriage return and a backslash, so the ids a
# shell-side test could ever be handed were the dotted ones — `.` and `..`
# name the marker directory and its parent, each of which exists once a block
# has recorded the directory, and the recorded-block test below read them as
# this subagent's own and passed the stop unchecked. An id passes only when
# it is spelled in the alphabet the harness names subagents in,
# ASCII letters, digits, `_` and `-`, which removing every such character
# proves by leaving nothing; an anchored match would not, since `$` also
# matches before a trailing newline. jq hands back an id it accepted or the
# empty string, and an accepted id is never empty, so the two cannot be
# mistaken for one another downstream.
#
# The transcript is the subagent's own. Claude Code and Codex send it as
# `agent_transcript_path` on SubagentStop, beside a `transcript_path` naming
# the parent session's, whose delegation names an artifact path of its own and
# can name another worktree; Codex sends the key null for a thread with no
# rollout, which reads as empty and is refused below. A payload without the key
# names the subagent's in `transcript_path`. The field read is a column, so
# the refusal names it.
#
# Copilot spells the agent fields in camelCase, so each is read in both
# spellings, the snake_case one first. Its `transcriptPath` names the lead's
# transcript, which a Copilot install never reads, so it is not read here.
FIELDS=$(printf '%s' "$INPUT" | jq -r '
  def str($v): if $v == null then "" elif ($v | type) == "string" then $v else error("not a string") end;
  def either(a; b): if a != null then a else b end;
  (if has("agent_transcript_path") then "agent_transcript_path" else "transcript_path" end) as $field |
  [str(either(.agent_type; .agentType)),
   (str(either(.agent_id; .agentId)) | if . != "" and gsub("[A-Za-z0-9_-]"; "") == "" then . else "" end),
   $field,
   str(.[$field]),
   (.stop_hook_active == true | tostring)] | @tsv' 2>/dev/null) ||
  refuse payload invalid-json
TAB=$'\t'
AGENT_TYPE=${FIELDS%%"$TAB"*}
REST=${FIELDS#*"$TAB"}
AGENT_ID=${REST%%"$TAB"*}
REST=${REST#*"$TAB"}
TRANSCRIPT_FIELD=${REST%%"$TAB"*}
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

# Empty is the refusal jq made above, read here rather than there so the two
# stops that need no marker — an agent that is not a reviewer, and a stop the
# harness is already re-running — keep passing whatever id they carry.
if [ -z "$AGENT_ID" ]; then
  refuse agent-id invalid
fi
[ "$INSTALL" != copilot ] || MARK_EVERY_REFUSAL=1
# Copilot's subagentStop names the lead's transcript, which holds every agent
# of the session, so there the artifact path is read from the subagent's own
# reply, the payload's documented `response`.
REPLY=""
if [ "$INSTALL" = copilot ]; then
  ARTIFACT_SOURCE="reply this subagent ended with"
  REPLY=$(printf '%s' "$INPUT" | jq -r '
    if .response == null then "" elif (.response | type) == "string" then .response else error("not a string") end' 2>/dev/null) ||
    refuse payload invalid-json
elif [ ! -r "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ]; then
  refuse transcript unreadable
fi

# The newest artifact path the transcript mentions: the Write call's
# file_path, the File: line of the return message, either one; on Copilot,
# the newest the reply mentions, its File: line. A path
# holding a quote, a space or a backslash is not read; none of the
# generated artifact paths hold one.
ARTIFACT_PATTERN='(/[^/"[:space:]\\]+)+/tmp/review-[^/"[:space:]\\]*\.json'
set +e
if [ "$INSTALL" = copilot ]; then
  MENTIONS=$(grep -oE "$ARTIFACT_PATTERN" <<<"$REPLY" 2>&1)
else
  MENTIONS=$(grep -oE "$ARTIFACT_PATTERN" -- "$TRANSCRIPT" 2>&1)
fi
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
# The mention is the reviewer's word; the file is the review. Slurping parses
# the whole file, so an empty one or one with trailing garbage is refused too.
if ! ARTIFACT_ERR=$(jq -s 'if length == 0 then error("no JSON value") else empty end' "$ARTIFACT" 2>&1); then
  record_and_block artifact unreadable "$ARTIFACT_ERR"
fi
# Without optional locks, so this status never refreshes the index whose
# change time is read below as evidence of the reviewer's staging.
STATUS=$(git --no-optional-locks -C "$WORKTREE" status --porcelain --untracked-files=all 2>&1) ||
  git_failed status "$STATUS"

# When the review started: the `timestamp` of the subagent transcript's first
# entry, taken only when that entry is a launch record written before any tool
# ran, Codex's `session_meta` or Claude Code's prompt, a `user` entry carrying
# no tool result. A first entry that is a tool call is stamped when the call
# completed, after whatever the command wrote, so it gives no start. A path
# dirty before the start is the author's and nothing the reviewer does clears
# it. Copilot names only the lead's transcript; with no start every dirty path
# counts, the guard as strict as before.
START=""
if [ "$INSTALL" != copilot ]; then
  START=$(jq -nr 'input
    | select(.type == "session_meta" or (.type == "user" and ([.message.content | arrays | .[] | .type?] | index("tool_result") | not)))
    | .timestamp | strings | sub("\\.[0-9]+"; "") | fromdateiso8601 | floor' "$TRANSCRIPT" 2>/dev/null) ||
    START=""
fi
# The status-change time of PATH: a write, a chmod and a rename each set it,
# and touch cannot set it back. GNU stat, then BSD.
ctime() { # PATH
  stat -c %Z "$1" 2>/dev/null || stat -f %c "$1" 2>/dev/null
}
# Whether a status LINE is the reviewer's to clear (0) or the author's (1).
# Unknown evidence is never old: a quoted path, a time stat cannot read, and a
# directory row (a submodule, whose own entry no move of its HEAD touches)
# count as the reviewer's. An index-side change counts while the index changed
# since the start, a refresh by a read-only git command included, since the
# index records no time per entry. A deleted path is judged by its nearest
# existing directory, whose entry the deletion changed; a sibling created
# since moves that too, so the error falls toward blocking.
reviewers() { # LINE
  local x=${1:0:1} y=${1:1:1} path=${1:3} p t
  case "$path" in \"*) return 0 ;; esac
  case "$x$y" in *R* | *C*) path=${path##* -> } ;; esac
  p="$TOPLEVEL/$path"
  [ ! -d "$p" ] || return 0
  case "$x" in
    ' ' | '?') ;;
    *) [ "$INDEX_CHANGED" -eq 0 ] || return 0 ;;
  esac
  [ "$y" != ' ' ] || return 1
  while [ ! -e "$p" ] && [ ! -L "$p" ]; do p=${p%/*}; done
  t=$(ctime "$p") || return 0
  [ "$t" -ge "$START" ]
}
if [ -n "$START" ]; then
  INDEX=$(git -C "$WORKTREE" rev-parse --git-path index 2>&1) ||
    git_failed 'rev-parse --git-path index' "$INDEX"
  case "$INDEX" in
    /*) ;;
    *) INDEX="$WORKTREE/$INDEX" ;;
  esac
  INDEX_CHANGED=1
  if t=$(ctime "$INDEX") && [ "$t" -lt "$START" ]; then INDEX_CHANGED=0; fi
  OWN=""
  while IFS= read -r line; do
    reviewers "$line" || continue
    OWN="$OWN$line"$'\n'
  done <<<"$STATUS"
  STATUS=${OWN%$'\n'}
fi
if [ -z "$STATUS" ]; then
  exit 0
fi

record_and_block worktree "$TOPLEVEL"
