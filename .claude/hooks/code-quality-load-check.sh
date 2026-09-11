#!/usr/bin/env bash
# ---
# name: code-quality-load-check
# event: PreToolUse
# matcher: Edit|MultiEdit|NotebookEdit|Write
# description: Refuses an Edit, MultiEdit, NotebookEdit or Write onto a path inside a git work tree until the agent making the call has loaded the code-quality skill, so the repository rule "load the code-quality skill before writing or changing code" is decided rather than remembered. Loaded is read off the transcript that records that agent's tool calls: a `Skill` tool call whose `skill` input is `code-quality`. That transcript is the session transcript the payload names, or, when the payload carries `agent_id` because a subagent made the call, the subagent's own `agent-<agent_id>.jsonl` under the session's `subagents/` directory, directly or one directory below; the lead session's load does not pass a subagent's edit. The work tree's own `tmp/` is scratch and passes — commit messages, status files and notes — and so does every path outside a work tree, which is where a session's temporary files belong. Every session in the repository is judged, not only a delegated agent. KENDEX_CODE_QUALITY_HOOK=off disables it for a session that is not editing the repository under those rules. Claude Code only, the harness whose payload names the transcript and whose Skill tool records the load.
# summary: Holds back edits to a repository until the session has loaded the code-quality skill, so the standard is applied rather than remembered.
# safety: Reads the payload, asks git where the target path is, and reads the transcript of the agent making the call; writes nothing. A payload, a git answer or a transcript it cannot read is refused, never passed, so an unreadable state never reads as loaded: an `agent_id` that is not a string of ASCII letters, digits, `_` and `-`, the alphabet the harness names subagents in, or that names no single subagent transcript, is refused. The refusal names the skill to load and the path it refused, and never a bypass. Every refusal opens with `code-quality-load-check: <key>=<value>`; what a command this hook runs writes is captured at the site and replayed under that line, so nothing precedes the key.
# timeout: 15
# harnesses: [claude-code]
# ---

set -euo pipefail

# Paths and transcript bytes are matched by byte ranges below; git's own
# messages are read in English.
export LC_ALL=C

# The skill the repository rule names, and the only place its name lives: the
# refusal, the transcript read and the remedy all read it from here.
SKILL=code-quality

# What the refusals name, empty until each is known: the edit's target and the
# transcript the loaded state is read from.
TARGET=""
TRANSCRIPT=""
# Every line this hook writes, and the only place its text lives. The first
# line is the contract a reader parses, `code-quality-load-check:
# <key>=<value>`: a stable key for the condition and the value acted on — the
# missing tool, why the payload could not be read, the transcript that could
# not be read, or the skill that is not loaded. The English explanation
# follows it, and it never names a bypass.
# The keyed line stands first, at position 1. What a command this hook runs
# wrote is captured where the hook reads it and passed here as the cause, so
# it is replayed under the key rather than ahead of it.
refuse() { # KEY VALUE [CAUSE]
  {
    printf 'code-quality-load-check: %s=%s\n' "$1" "$2"
    case "$1=$2" in
      missing-tools=*)
        echo "the commands ${2//,/, } are required to read the hook payload, place the target path and read the session transcript and are not on PATH; refusing rather than skipping the guard"
        ;;
      payload=unreadable)
        echo "the hook payload could not be read from stdin"
        ;;
      payload=invalid-json)
        echo "the hook payload is not valid JSON; refusing rather than skipping the guard"
        ;;
      payload=no-file-path)
        echo "the payload names no file_path or notebook_path string, so the edit's target is unknown; refusing rather than skipping the guard"
        ;;
      payload=no-transcript)
        echo "the payload names no transcript_path string, so whether $SKILL is loaded cannot be read; refusing rather than skipping the guard"
        ;;
      payload=invalid-agent-id)
        echo "the payload's agent_id is not a string of ASCII letters, digits, _ and -, so the transcript of the subagent making the call cannot be found; refusing rather than skipping the guard"
        ;;
      transcript=unreadable)
        echo "the transcript $TRANSCRIPT is not exactly one readable file, so whether $SKILL is loaded cannot be read; refusing"
        ;;
      transcript=unread)
        echo "the transcript $TRANSCRIPT could not be read, so whether $SKILL is loaded cannot be read; refusing:"
        ;;
      unloaded=*)
        echo "$TARGET is inside a repository and the agent making this edit has not loaded the $2 skill, whose rules the edit would be judged by. Load it — the Skill tool, skill: $2 — and make the edit after that."
        ;;
      git=unreadable)
        echo "git could not say where $TARGET is, so the edit is refused:"
        ;;
    esac
    # The cause a command this hook ran wrote, captured at the site and
    # replayed here: under the keyed line, never ahead of it.
    [ -z "${3:-}" ] || printf '%s\n' "$3"
  } >&2
  exit 2
}

# The off switch stands before everything, so a session that is not editing
# the repository under these rules needs none of the tools below.
if [ "${KENDEX_CODE_QUALITY_HOOK:-}" = off ]; then
  exit 0
fi

# Every external command this hook runs. jq reads the payload and the
# transcript's lines, git places the target path, cat hands the payload over,
# grep narrows the transcript and then answers whether the skill is among
# what was loaded, and dirname walks up to the nearest existing directory. An
# unchecked absence is not a stall but a pass: a missing grep makes the
# transcript read empty, which is the loaded answer this hook must never
# reach by accident. So the whole set is checked before anything is judged,
# and the value names every one of them the PATH is missing, in the order
# checked.
MISSING=""
for dependency in jq git cat grep dirname; do
  command -v "$dependency" >/dev/null 2>&1 || MISSING="$MISSING,$dependency"
done
[ -z "$MISSING" ] || refuse missing-tools "${MISSING#,}"

# cat's words are captured, not left to precede the refusal: on failure the
# substitution holds what it wrote, and the refusal replays it under the keyed
# line. A cat that succeeds is silent, so the payload is not mixed with a
# diagnostic on the passing side.
INPUT=$(cat 2>&1) || refuse payload unreadable "$INPUT"

# The payload's own shape first, so a document that does not parse is named
# as that rather than as a field the reads below could not find. A path or a
# transcript path may hold a tab or a newline, so each string is its own read
# and none of them share a delimiter.
printf '%s' "$INPUT" | jq -e 'type == "object"' >/dev/null 2>&1 || refuse payload invalid-json

TARGET=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path
  | if type == "string" then . else error("not a string") end' 2>/dev/null) ||
  refuse payload no-file-path

TRANSCRIPT=$(printf '%s' "$INPUT" | jq -r '.transcript_path
  | if type == "string" then . else error("not a string") end' 2>/dev/null) ||
  refuse payload no-transcript

# The harness adds agent_id only to a subagent's call, and transcript_path
# still names the session's transcript then. The subagent's transcript file
# name is built here, empty for the session's own call: a built name is never
# empty, so the two cases cannot be mistaken. The id is judged as the payload
# holds it, before the shell reads it: a NUL that the shell would drop, a `/`
# or a newline would each name another file. It passes only when it is
# spelled in the alphabet the harness names subagents in, ASCII letters,
# digits, `_` and `-`, which removing every such character proves by leaving
# nothing; an anchored match would not, since `$` also matches before a
# trailing newline.
AGENT_FILE=$(printf '%s' "$INPUT" | jq -r 'if has("agent_id") then .agent_id
  | if type == "string" and . != "" and gsub("[A-Za-z0-9_-]"; "") == ""
    then "agent-\(.).jsonl"
    else error("not an agent id") end
  else "" end' 2>/dev/null) ||
  refuse payload invalid-agent-id

# Where the target is, is asked of the nearest directory that exists, since a
# Write creates the missing ones. "Not a git repository" is the pass: a file
# outside every work tree is a session's own scratch and no repository's code.
DIR=$(dirname -- "$TARGET")
while [ ! -d "$DIR" ] && [ "$DIR" != "/" ] && [ "$DIR" != "." ]; do
  DIR=$(dirname -- "$DIR")
done
if ANSWER=$(git -C "$DIR" rev-parse --is-inside-work-tree 2>&1); then
  [ "$ANSWER" = "true" ] || exit 0
else
  case "$ANSWER" in
    *"not a git repository"*) exit 0 ;;
  esac
  refuse git unreadable "$ANSWER"
fi

# The work tree's own tmp/ is scratch: commit messages, status files and
# notes. git names the directory's place in the work tree, so the answer does
# not depend on comparing two spellings of a path, one of which git has
# already resolved through its symlinks.
PREFIX=$(git -C "$DIR" rev-parse --show-prefix 2>&1) || refuse git unreadable "$PREFIX"
case "$PREFIX${TARGET#"$DIR"/}" in
  tmp/*) exit 0 ;;
esac

# A subagent's tool calls, its load among them, are recorded in its own
# transcript beside the session's: `<session>/subagents/agent-<id>.jsonl`, or
# one directory below subagents/. Only the `*` is a pattern, so exactly the
# built file name matches, and a count other than one leaves no transcript to
# judge by.
if [ -n "$AGENT_FILE" ]; then
  SUBAGENTS="${TRANSCRIPT%.jsonl}/subagents"
  MATCHES=0
  FOUND=""
  for candidate in "$SUBAGENTS/$AGENT_FILE" "$SUBAGENTS"/*/"$AGENT_FILE"; do
    if [ -e "$candidate" ]; then
      MATCHES=$((MATCHES + 1))
      FOUND=$candidate
    fi
  done
  TRANSCRIPT="$SUBAGENTS/$AGENT_FILE or $SUBAGENTS/*/$AGENT_FILE"
  [ "$MATCHES" -eq 1 ] || refuse transcript unreadable
  TRANSCRIPT=$FOUND
fi

if [ ! -r "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ]; then
  refuse transcript unreadable
fi

# The transcript is a session's worth of JSON lines, most of them holding
# neither a skill nor a tool call. grep narrows it to the lines that mention
# the skill at all — a fixed string over the file is what a transcript's size
# affords — and jq then judges only those, because the mention that counts is
# a Skill tool call whose input names it, not the skill listing in a system
# message or a file the session happened to read.
set +e
CANDIDATES=$(grep -F -e "$SKILL" -- "$TRANSCRIPT" 2>&1)
GREP_RC=$?
set -e
case "$GREP_RC" in
  0) ;;
  1) refuse unloaded "$SKILL" ;;
  # A grep that could not read the transcript wrote its reason where its
  # matches would have gone, so CANDIDATES carries the cause.
  *) refuse transcript unread "$CANDIDATES" ;;
esac

# Each line is read as raw text and parsed on its own, so the line the harness
# was still writing when the hook ran is skipped rather than taken for the
# whole file. Every step names the type it accepts: a line of another shape
# yields nothing instead of ending the read, and nothing is the unloaded
# answer.
LOADED=$(printf '%s\n' "$CANDIDATES" | jq -R -r 'fromjson?
  | objects | .message
  | objects | .content
  | arrays | .[]
  | objects | select(.type == "tool_use" and .name == "Skill") | .input
  | objects | .skill
  | strings' 2>&1) || refuse transcript unread "$LOADED"

if grep -Fx -e "$SKILL" <<<"$LOADED" >/dev/null; then
  exit 0
fi

refuse unloaded "$SKILL"
