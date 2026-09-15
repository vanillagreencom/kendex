#!/usr/bin/env bash
# ---
# name: skill-load-check
# event: PreToolUse
# matcher: Edit|MultiEdit|NotebookEdit|Write|Bash
# description: Refuses a call a repository rule ties to a skill until the agent making the call has loaded that skill, so each "load skill X before doing Y" rule is decided rather than remembered. The rules are one table of trigger and skill. The defaults: an Edit, MultiEdit, NotebookEdit or Write onto a path inside a git work tree needs code-quality, and one onto a path ending in `.md` needs docs-writing too; a Bash call whose command runs a `linear.sh` write verb (`issues create|update|bulk-update|archive|delete|trash|block|unblock|activate|complete`, `comments create|update|delete`, `labels create|update|delete`, `projects` and `cycles` writes) needs linear, read only where the shell would run it, so the verb inside a quoted note or a heredoc body is no command. KENDEX_SKILL_LOAD_RULES appends a repository's own rules: `<glob>=<skill>` for an edit, the glob matched against the path from the work tree's root with `*` crossing `/`, and `bash:<regex>=<skill>` for a command, entries separated by `;`. A call needing two skills is refused on the first one not loaded. Loaded is read off the transcript that records that agent's tool calls: a `Skill` tool call whose `skill` input names the skill, or, in a Pi session file, a successful `read` tool call whose `path` ends in `<skill>/SKILL.md`: one whose result is recorded under the same `toolCallId` and is not an error. That transcript is the session transcript the payload names, or, when the payload carries `agent_id` because a subagent made the call, the subagent's own `agent-<agent_id>.jsonl` under the session's `subagents/` directory, directly or one directory below; the lead session's load does not pass a subagent's call. A Pi subagent is its own process with its own session file, which is the transcript its payload names. The work tree's own `tmp/` is scratch and passes, and so does every path outside a work tree. KENDEX_SKILL_LOAD_HOOK=off disables it for a session that is not working under those rules. Not run on codex: a file write is `apply_patch`, whose payload carries no `tool_input.file_path`, and a skill load is a shell read of SKILL.md with no skill record. Not run on gemini: its tool-call payload and its record of a skill load are unmeasured. Not run on copilot: its preToolUse payload carries no transcript path and names the file as `toolArgs.path`. Not run on antigravity: the file arrives as `toolCall.args.TargetFile` and a skill load is a `view_file` read with no skill record.
# summary: Holds back edits and Linear writes until the agent making them has loaded the skill the repository ties to them, so the standard is applied rather than remembered.
# safety: Reads the payload, asks git where an edit's target is, reads a command with the commit-guards skill's command-position library, and reads the transcript of the agent making the call; writes nothing. A payload, a rule, a git answer, the library or a transcript it cannot read is refused, never passed, so an unreadable state never reads as loaded: an `agent_id` that is not a string of ASCII letters, digits, `_` and `-`, the alphabet the harness names subagents in, or that names no single subagent transcript, is refused. The refusal names the skill to load and the path or command it refused, and never a bypass. Every refusal opens with `skill-load-check: <key>=<value>`; what a command this hook runs writes is captured at the site and replayed under that line, so nothing precedes the key.
# timeout: 15
# harnesses: [claude, pi, opencode, cursor]
# ---

set -euo pipefail

# Paths, rules and transcript bytes are matched by byte ranges below; git's own
# messages are read in English.
export LC_ALL=C

LF=$'\n'
# The rule table every repository starts from, in the grammar a repository's
# own entries use, and the only place the defaults live. Rules are judged in
# order, so an edit needing code-quality and docs-writing is refused on
# code-quality first.
Q="[\"']?"
LINEAR_WRITE="(^|[^[:alnum:]_.-])linear\\.sh${Q}[[:space:]]+${Q}(issues?[[:space:]]+${Q}(create|update|bulk-update|archive|delete|trash|block|unblock|activate|complete)|comments?[[:space:]]+${Q}(create|update|delete)|labels?[[:space:]]+${Q}(create|update|delete)|projects?[[:space:]]+${Q}(create|update|delete|add-dependency|remove-dependency|post-update|reorder|set-sort-order)|cycles?[[:space:]]+${Q}(create|update))${Q}([[:space:]]|\$)"
DEFAULT_RULES="*=code-quality;*.md=docs-writing;bash:$LINEAR_WRITE=linear"

# What the refusals name, empty until each is known: the edit's target or the
# command, and the transcript the loaded state is read from.
REFUSED=""
TRANSCRIPT=""
# Every line this hook writes, and the only place its text lives. The first
# line is the contract a reader parses, `skill-load-check: <key>=<value>`: a
# stable key for the condition and the value acted on — the missing tool, why
# the payload could not be read, the rule that could not be read, the library
# that is not installed, the transcript that could not be read, or the skill
# that is not loaded. The English explanation follows it, and it never names a
# bypass. What a command this hook runs wrote is captured where the hook reads
# it and passed here as the cause, so it is replayed under the key rather than
# ahead of it.
refuse() { # KEY VALUE [CAUSE]
  {
    printf 'skill-load-check: %s=%s\n' "$1" "$2"
    case "$1=$2" in
      missing-tools=*)
        echo "the commands ${2//,/, } are required to read the hook payload, place the target path and read the session transcript and are not on PATH; refusing rather than skipping the guard"
        ;;
      malformed-rule=*)
        echo "KENDEX_SKILL_LOAD_RULES holds an entry that is not <glob>=<skill> or bash:<regex>=<skill>, with a non-empty glob, a regex that compiles and a skill named in letters, digits, '.', '_', ':' and '-'; refusing rather than dropping the rule"
        ;;
      missing-library=*)
        echo "the commit-guards skill's $2 is not installed beside this hook, and it is what reads the command; install the commit-guards skill in this scope. Refusing rather than skipping the guard"
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
      payload=no-command)
        echo "the payload names no command string, so what the call runs is unknown; refusing rather than skipping the guard"
        ;;
      payload=no-transcript)
        echo "the payload names no transcript_path string, so which skills are loaded cannot be read; refusing rather than skipping the guard"
        ;;
      payload=invalid-agent-id)
        echo "the payload's agent_id is not a string of ASCII letters, digits, _ and -, so the transcript of the subagent making the call cannot be found; refusing rather than skipping the guard"
        ;;
      transcript=unreadable)
        echo "the transcript $TRANSCRIPT is not exactly one readable file, so which skills are loaded cannot be read; refusing"
        ;;
      transcript=unread)
        echo "the transcript $TRANSCRIPT could not be read, so which skills are loaded cannot be read; refusing:"
        ;;
      unloaded=*)
        printf '%s\n' "$REFUSED"
        echo "the agent making this call has not loaded the $2 skill, whose rules the call would be judged by. Load it — the Skill tool, skill: $2 — and make the call after that."
        ;;
      git=unreadable)
        echo "git could not say where $REFUSED is, so the edit is refused:"
        ;;
    esac
    # The cause a command this hook ran wrote, captured at the site and
    # replayed here: under the keyed line, never ahead of it.
    [ -z "${3:-}" ] || printf '%s\n' "$3"
  } >&2
  exit 2
}

# The off switch stands before everything, so a session that is not working
# under these rules needs none of the tools below.
if [ "${KENDEX_SKILL_LOAD_HOOK:-}" = off ]; then
  exit 0
fi

# Every external command this hook runs. jq reads the payload and the
# transcript's lines, git places the target path, cat hands the payload over,
# grep narrows the transcript and then answers whether a skill is among what
# was loaded, and dirname walks up to the nearest existing directory. An
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

RULES=$DEFAULT_RULES
[ -z "${KENDEX_SKILL_LOAD_RULES:-}" ] || RULES="$RULES;$KENDEX_SKILL_LOAD_RULES"

# Every rule, handed to CALLBACK as its trigger and its skill. The whole table
# is read before any call is judged, so a rule that cannot be read refuses
# every call rather than only the ones it would have matched. The blanks
# around an entry are not part of it; a newline inside one is.
each_rule() { # CALLBACK
  local rest=$RULES raw entry trigger skill
  while :; do
    raw=${rest%%;*}
    entry=${raw#"${raw%%[![:blank:]]*}"}
    entry=${entry%"${entry##*[![:blank:]]}"}
    trigger=${entry%=*}
    skill=${entry##*=}
    case "$entry" in
      *=*) ;;
      *) refuse malformed-rule "$entry" ;;
    esac
    case "$skill" in
      "" | *[!A-Za-z0-9._:-]*) refuse malformed-rule "$entry" ;;
    esac
    case "$trigger" in
      "" | bash: | *"$LF"*) refuse malformed-rule "$entry" ;;
      bash:*)
        # A regex that does not compile answers 2, where a miss answers 1, and
        # the shell's own words on it are dropped so nothing precedes the key.
        compiled=0
        { [[ "" =~ ${trigger#bash:} ]]; } 2>/dev/null || compiled=$?
        [ "$compiled" -ne 2 ] || refuse malformed-rule "$entry"
        ;;
    esac
    "$1" "$trigger" "$skill"
    [ "$raw" != "$rest" ] || return 0
    rest=${rest#*;}
  done
}
each_rule :

# The skills the call needs, one per line in rule order, each named once.
REQUIRED=""
require() { # SKILL
  case "$LF$REQUIRED" in
    *"$LF$1$LF"*) ;;
    *) REQUIRED=$REQUIRED$1$LF ;;
  esac
}

# cat's words are captured, not left to precede the refusal: on failure the
# substitution holds what it wrote, and the refusal replays it under the keyed
# line. A cat that succeeds is silent, so the payload is not mixed with a
# diagnostic on the passing side.
INPUT=$(cat 2>&1) || refuse payload unreadable "$INPUT"

# The payload's own shape first, so a document that does not parse is named
# as that rather than as a field the reads below could not find. A path, a
# command or a transcript path may hold a tab or a newline, so each string is
# its own read and none of them share a delimiter.
printf '%s' "$INPUT" | jq -e 'type == "object"' >/dev/null 2>&1 || refuse payload invalid-json

if [ "$(printf '%s' "$INPUT" | jq -r '.tool_name == "Bash"' 2>/dev/null)" = true ]; then
  REFUSED=$(printf '%s' "$INPUT" | jq -r '.tool_input.command
    | if type == "string" then . else error("not a string") end' 2>/dev/null) ||
    refuse payload no-command

  # The command reader is commit-guards' command-position library. A catalog
  # hook ships as one file, so the library is looked for in the install the
  # hook came from, the way command-safety finds its settings loader: the
  # scope's `skills/` or shared `.agents/skills/` tree, from the hook's own
  # directory up three levels. Without it no command can be read, and the
  # call is refused.
  LIBRARY=commit-guards/scripts/lib/command-position.sh
  HOOK_DIR=${BASH_SOURCE[0]%/*}
  [ "$HOOK_DIR" != "${BASH_SOURCE[0]}" ] || HOOK_DIR=.
  AT=$(cd -P -- "$HOOK_DIR" 2>/dev/null && pwd) || AT=""
  FOUND_LIBRARY=""
  LEVELS=0
  while [ -n "$AT" ]; do
    for candidate in "$AT/skills/$LIBRARY" "$AT/.agents/skills/$LIBRARY"; do
      if [ -f "$candidate" ]; then
        FOUND_LIBRARY=$candidate
        break 2
      fi
    done
    [ "$LEVELS" -lt 3 ] && [ "$AT" != / ] || break
    AT=${AT%/*}
    [ -n "$AT" ] || AT=/
    LEVELS=$((LEVELS + 1))
  done
  [ -n "$FOUND_LIBRARY" ] || refuse missing-library "$LIBRARY"
  # shellcheck source=../skills/commit-guards/scripts/lib/command-position.sh
  source "$FOUND_LIBRARY"

  # A command rule matches a segment of what the shell would run; an edit
  # rule never matches a command.
  command_segments "$REFUSED"
  command_rule() { # TRIGGER SKILL
    case "$1" in
      bash:*)
        if [[ $SEGMENT =~ ${1#bash:} ]]; then
          require "$2"
        fi
        ;;
    esac
  }
  while IFS= read -r SEGMENT; do
    each_rule command_rule
  done <<EOF
$SEGMENTS
EOF
else
  REFUSED=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path
    | if type == "string" then . else error("not a string") end' 2>/dev/null) ||
    refuse payload no-file-path

  # Where the target is, is asked of the nearest directory that exists, since
  # a Write creates the missing ones. "Not a git repository" is the pass: a
  # file outside every work tree is a session's own scratch and no
  # repository's code.
  DIR=$(dirname -- "$REFUSED")
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
  # notes. git names the directory's place in the work tree, so the answer
  # does not depend on comparing two spellings of a path, one of which git has
  # already resolved through its symlinks. The same place is what an edit
  # rule's glob is matched against.
  PREFIX=$(git -C "$DIR" rev-parse --show-prefix 2>&1) || refuse git unreadable "$PREFIX"
  PLACE=$PREFIX${REFUSED#"$DIR"/}
  case "$PLACE" in
    tmp/*) exit 0 ;;
  esac
  edit_rule() { # TRIGGER SKILL
    case "$1" in
      bash:*) ;;
      *)
        # The glob is the pattern, unquoted on purpose.
        # shellcheck disable=SC2254
        case "$PLACE" in
          $1) require "$2" ;;
        esac
        ;;
    esac
  }
  each_rule edit_rule
fi

[ -n "$REQUIRED" ] || exit 0

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
# neither a skill nor a tool call. grep narrows it to the lines that mention a
# required skill at all, plus Pi's tool results, whose text need not name it —
# fixed strings over the file are what a transcript's size affords — and jq
# then judges only those, because the mention that counts is a Skill tool call
# whose input names it, or a Pi `read` of the skill's own SKILL.md that
# succeeded, not the skill listing in a system message or another file the
# session happened to read.
FIRST=${REQUIRED%%"$LF"*}
set --
while IFS= read -r skill; do
  [ -z "$skill" ] || set -- "$@" -e "$skill"
done <<EOF
$REQUIRED
EOF
set +e
CANDIDATES=$(grep -F "$@" -e '"toolResult"' -- "$TRANSCRIPT" 2>&1)
GREP_RC=$?
set -e
case "$GREP_RC" in
  0) ;;
  1) refuse unloaded "$FIRST" ;;
  # A grep that could not read the transcript wrote its reason where its
  # matches would have gone, so CANDIDATES carries the cause.
  *) refuse transcript unread "$CANDIDATES" ;;
esac

# Each line is read as raw text and parsed on its own, so the line the harness
# was still writing when the hook ran is skipped rather than taken for the
# whole file. Every step names the type it accepts: a line of another shape
# yields nothing instead of ending the read, and nothing is the unloaded
# answer.
# Claude Code records the load as a Skill tool_use. Pi records a toolCall of
# its `read` tool before the read runs and the outcome afterwards as a
# toolResult message under the same toolCallId, isError true when it failed,
# so only a call with a result that is not an error is a load: a failed read
# and one whose result was never written are not. The path is absolute or
# relative, so it is matched whole or after a `/`, against each required
# skill, and `not-code-quality/SKILL.md` is not code-quality's.
LOADED=$(printf '%s\n' "$CANDIDATES" | jq -R -n -r --arg required "$REQUIRED" '
  ($required | split("\n") | map(select(. != ""))) as $skills
  | [inputs | fromjson? | objects | .message | objects] as $messages
  | [$messages[] | select(.role == "toolResult" and .isError != true) | .toolCallId | strings] as $read
  | $messages[]
  | .content
  | arrays | .[]
  | objects
  | if .type == "tool_use" and .name == "Skill" then .input | objects | .skill | strings
    elif .type == "toolCall" and .name == "read" and ((.id | strings) as $id | $read | index([$id]) != null)
    then (.arguments | objects | .path | strings) as $path
      | $skills[] as $skill
      | select($path == "\($skill)/SKILL.md" or ($path | endswith("/\($skill)/SKILL.md")))
      | $skill
    else empty end' 2>&1) || refuse transcript unread "$LOADED"

while IFS= read -r skill; do
  [ -n "$skill" ] || continue
  grep -Fx -e "$skill" <<<"$LOADED" >/dev/null || refuse unloaded "$skill"
done <<EOF
$REQUIRED
EOF
exit 0
