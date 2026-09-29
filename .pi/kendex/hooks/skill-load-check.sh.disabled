#!/usr/bin/env bash
# ---
# name: skill-load-check
# event: PreToolUse
# matcher: Edit|MultiEdit|NotebookEdit|Write|Bash
# description: Refuses a call a repository rule ties to a skill until the agent making the call has loaded that skill, so each "load skill X before doing Y" rule is decided rather than remembered. The rules are one table of trigger and skill. The defaults: an Edit, MultiEdit, NotebookEdit or Write onto a path inside a git work tree that ends in `.md` needs docs-writing, and one onto any other path there needs code-quality; a Bash call naming `linear.sh` at the word it executes or at any word after it needs linear whatever it asks of Linear, so a call that only mentions the name inside a quoted note or a heredoc body is no command, while a call that hands the name to another command, such as `echo /tmp/linear.sh` or `cat .../linear.sh`, is refused alongside the calls that really run it: a word that launches what follows it, `bash` and `env` among them, picks its command by options nothing here reads, so every word after the first is judged rather than any launcher being listed. KENDEX_SKILL_LOAD_RULES appends a repository's own rules: `<glob>=<skill>` for an edit, the glob matched against the path from the work tree's root with `*` crossing `/` and extended patterns such as `!(*.md)` read, and `bash:<regex>=<skill>` for a command, the regex matched against each command the shell would run from the word it executes on, past leading assignments, and from every word after that one, entries separated by `;`. A call needing two skills is refused on the first one not loaded. Loaded is read off the transcript that records that agent's tool calls: a `Skill` tool call whose `skill` input names the skill, or, in a Pi session file, a successful `read` tool call whose `path` ends in `<skill>/SKILL.md`: one whose result is recorded under the same `toolCallId` and is not an error. That transcript is the session transcript the payload names, or, when the payload carries `agent_id` because a subagent made the call, the subagent's own `agent-<agent_id>.jsonl` under the session's `subagents/` directory, directly or one directory below; the lead session's load does not pass a subagent's call. A Pi subagent is its own process with its own session file, which is the transcript its payload names. On Copilot, whose payload names no transcript, loaded is read off a record kept per agent outside every repository, `$XDG_STATE_HOME/kendex/skill-load-check/<sessionId>` or under `~/.local/state` where that is unset: the skill-load-record hook beside this one runs it with the argument `record` after each `skill` tool call and appends the skill `toolArgs.skill` names only when `toolResult.resultType` is `success`, and the payload's `sessionId` names the agent, a subagent apart from the session that launched it, so the lead's load does not pass a subagent's call there either. A record untouched for 30 days is removed. There the matcher names every runtime tool Copilot's hooks reference lists for Edit, Write and Bash: the command is `toolArgs.command` of a `bash` or `powershell` call, the edit's target `toolArgs.path` of an `edit`, `create` or `str_replace_editor` call, whatever the last one's own command, and each file an `apply_patch` call's patch names on an `*** Add File: `, `*** Update File: `, `*** Delete File: ` or `*** Move to: ` line, a call with no target it can read being refused as `payload=no-file-path`; a refusal is also Copilot's `permissionDecision` deny on stdout, its reason the refusal's text, under the same exit 2. A Copilot call reaching another harness's copy, which Copilot runs from `.claude/settings.json`, passes there under `skill-load-check: harness=copilot`, the Copilot copy being its judge, so where no Copilot copy is installed that line is the one trace of a call nothing judged. A call needing a skill that reaches a Copilot copy with no skill-load-record beside it is refused as `carrier=<path>`: nothing writes the record there, and the remedy is `skill-load-record` added to the manifest's hooks list beside skill-load-check. The work tree's own `tmp/` is scratch and passes, and so does every path outside a work tree. KENDEX_SKILL_LOAD_HOOK=off disables it for a session that is not working under those rules. Not run on codex: a file write is `apply_patch`, whose payload carries no `tool_input.file_path`, and a skill load is a shell read of SKILL.md with no skill record. Not run on gemini: its tool-call payload and its record of a skill load are unmeasured. Not run on copilot: the Copilot route this describes is built but not installed until the skill-load row of `tools/harness-smoke --only copilot`, which shows a subagent judged by its own loads and not its parent's, passes on a host where Copilot is logged in. Not run on antigravity: the file arrives as `toolCall.args.TargetFile` and a skill load is a `view_file` read with no skill record.
# summary: Holds back edits and Linear commands until the agent making them has loaded the skill the repository ties to them, so the standard is applied rather than remembered.
# safety: Reads the payload, asks git where an edit's target is, reads a command with the commit-guards skill's command-position library, and reads the transcript of the agent making the call, or on Copilot the record of the skills that agent loaded; writes only that record, from a finished skill load, in a directory under the user's state home created private to the user. A payload, a rule, a git answer, the library or a transcript it cannot read is refused, never passed, so an unreadable state never reads as loaded: an `agent_id` that is not a string of ASCII letters, digits, `_` and `-`, the alphabet the harness names subagents in, or that names no single subagent transcript, is refused, and so is a Copilot `sessionId` outside that alphabet. The refusal names the skill to load and the path or command it refused, and never a bypass. Every refusal opens with `skill-load-check: <key>=<value>`; what a command this hook runs writes is captured at the site and replayed under that line, so nothing precedes the key.
# timeout: 15
# harnesses: [claude, pi, opencode, cursor]
# ---

set -euo pipefail

# Paths, rules and transcript bytes are matched by byte ranges below; git's own
# messages are read in English.
export LC_ALL=C

LF=$'\n'
# The rule table every repository starts from, in the grammar a repository's
# own entries use, and the only place the defaults live. A markdown target
# needs docs-writing and every other target code-quality, so a markdown edit is
# judged by the markdown standard alone. A command naming `linear.sh` at a word
# the shell may execute, by any directory, needs linear whatever it asks of
# Linear, since that skill governs every Linear read and write; no action is
# listed, so none can be missing. Rules are judged in order, so a call two
# rules match is refused on the first skill not loaded.
LINEAR_CALL="^[\"']?([^[:space:]]*/)?linear\\.sh[\"']?([[:space:]]|\$)"
DEFAULT_RULES="!(*.md)=code-quality;*.md=docs-writing;bash:$LINEAR_CALL=linear"

# Which harness this install serves comes from where it is installed, as
# hooks/lane-mail-check.sh reads it: `hook_target` in
# `crates/core/src/engine/targets.rs` writes the copilot copy under
# `.github/hooks` at project scope, and at global scope beside the registry
# document `<name>.json` that only a copilot install leaves. Read before
# anything that could fail, because it decides the shape of every refusal.
HOOK_DIR=${BASH_SOURCE[0]%/*}
[ "$HOOK_DIR" != "${BASH_SOURCE[0]}" ] || HOOK_DIR=.
INSTALL=""
case "$HOOK_DIR" in
  */.github/hooks) INSTALL=copilot ;;
esac
if [ -z "$INSTALL" ] && [ -f "${BASH_SOURCE[0]%.sh}.json" ]; then INSTALL=copilot; fi

# What the refusals name, empty until each is known: the edit's target or the
# command, the transcript the loaded state is read from, and on Copilot the
# record of the calling agent's loads and the skill a finished load named.
REFUSED=""
TRANSCRIPT=""
STATE_DIR=""
STATE=""
SKILL=""
# The event this run serves, judged once `refuse` stands below: `check` until
# then, so a refusal of the argument itself takes the judgement's shape.
ARM=check
# Every line this hook writes, and the only place its text lives. The first
# line is the contract a reader parses, `skill-load-check: <key>=<value>`: a
# stable key for the condition and the value acted on — the missing tool, why
# the payload could not be read, the rule that could not be read, the library
# that is not installed, the transcript or record that could not be read or
# written, or the skill that is not loaded. The English explanation follows
# it, and it never names a bypass. What a command this hook runs wrote is
# captured where the hook reads it and passed here as the cause, so it is
# replayed under the key rather than ahead of it.
message() { # KEY VALUE [CAUSE]
  printf 'skill-load-check: %s=%s\n' "$1" "$2"
  case "$1=$2" in
    missing-tools=*)
      echo "the commands ${2//,/, } are required to read the hook payload, place the target path and read the transcript or record of loaded skills and are not on PATH; refusing rather than skipping the guard"
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
      echo "the payload names no file_path or notebook_path string, nor on Copilot a toolArgs path or, for apply_patch, a patch with an Add File, Update File, Delete File or Move to line, so the edit's target is unknown; refusing rather than skipping the guard"
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
    payload=invalid-session-id)
      echo "the Copilot payload's sessionId is not a string of ASCII letters, digits, _ and -, so the agent making the call, and the skills it loaded, cannot be named; refusing rather than skipping the guard"
      ;;
    payload=invalid-skill)
      echo "the finished skill call names no skill in toolArgs.skill spelled in letters, digits, '.', '_', ':' and '-', so no load is recorded, and a call that needs the skill will be refused as though it were not loaded"
      ;;
    transcript=unreadable)
      echo "the transcript $TRANSCRIPT is not exactly one readable file, so which skills are loaded cannot be read; refusing"
      ;;
    transcript=unread)
      echo "the transcript $TRANSCRIPT could not be read, so which skills are loaded cannot be read; refusing:"
      ;;
    state=unlocatable)
      echo "neither XDG_STATE_HOME nor HOME is an absolute path, so the record of the skills a Copilot agent loaded has nowhere to be read or written; refusing"
      ;;
    state=unreadable)
      echo "the record $STATE of the skills this agent loaded is not a readable file, so which skills are loaded cannot be read; refusing:"
      ;;
    state=unwritable)
      echo "the load of the $SKILL skill could not be written to $STATE, so a call that needs it will be refused as though it were not loaded:"
      ;;
    state=unpruned)
      echo "the load was recorded, but the records untouched for 30 days could not be removed from $STATE_DIR:"
      ;;
    carrier=*)
      echo "the skill-load-record hook that writes down a Copilot agent's skill loads is not installed beside this one, so no load this agent made can be read, and the call is refused as though none were made. Add skill-load-record to the hooks list of the kendex manifest for this scope, beside skill-load-check, and run kendex apply; then load the skill and make the call again"
      ;;
    harness=*)
      echo "a Copilot call reached this install of the hook, which is not the Copilot one: the call is left to the skill-load-check Copilot installs under .github/hooks or in its own hooks directory, and where that copy is not installed it is not judged"
      ;;
    unloaded=*)
      printf '%s\n' "$REFUSED"
      echo "the agent making this call has not loaded the $2 skill, whose rules the call would be judged by. Load it — the Skill tool, skill: $2 — and make the call after that."
      ;;
    git=unreadable)
      echo "git could not say where $REFUSED is, so the edit is refused:"
      ;;
    arm=*)
      echo "the argument names no event this hook serves: none judges a tool call, and record writes down a finished skill load; refusing"
      ;;
  esac
  # The cause a command this hook ran wrote, captured at the site and
  # replayed here: under the keyed line, never ahead of it.
  [ -z "${3:-}" ] || printf '%s\n' "$3"
}

# The one exit for a refusal, KEY VALUE [CAUSE] as `message` takes them. The
# text goes to stderr, where every harness but Copilot reads it beside exit 2.
# Copilot does not hand a command hook's stderr to the model, so its install
# also answers on stdout in the form its hooks reference gives for the event:
# a tool call is denied with `permissionDecision` "deny" and the text as
# `permissionDecisionReason`, under the exit 2 that denies on its own; and a
# finished skill load that could not be recorded hands the text back as
# `additionalContext` at exit 0, since a postToolUse answer is parsed only
# there. The JSON is jq's: where jq is the missing tool, stdout stays empty
# and the exit status still denies; a jq that fails ends the run at exit 2,
# a denial before a tool call and a warning shown to the user after one.
refuse() { # KEY VALUE [CAUSE]
  local text
  text=$(message "$@")
  printf '%s\n' "$text" >&2
  if [ "$INSTALL" = copilot ] && command -v jq >/dev/null 2>&1; then
    case "$ARM" in
      check) jq -n -c --arg t "$text" '{permissionDecision: "deny", permissionDecisionReason: $t}' ;;
      record) jq -n -c --arg t "$text" '{additionalContext: $t}' ;;
    esac || exit 2
  fi
  [ "$ARM" = check ] || exit 0
  exit 2
}

# A condition no call can end, reported and passed: the keyed line on stderr
# at exit 0, for the operator reading the hook log.
notice() { # KEY VALUE [CAUSE]
  message "$@" >&2
  exit 0
}

# The event this run serves: the pre-tool judgement with no argument, or
# `record`, the argument the skill-load-record hook beside this one passes on
# Copilot's postToolUse, where a skill load that finished is written down for
# the judgement to read.
case "${1:-check}" in
  check | record) ARM="${1:-check}" ;;
  *) refuse arm "$1" ;;
esac

# The off switch stands before everything, so a session that is not working
# under these rules needs none of the tools below.
if [ "${KENDEX_SKILL_LOAD_HOOK:-}" = off ]; then
  exit 0
fi

# Every external command this run needs. jq reads the payload and the
# transcript's lines, git places the target path, cat hands the payload over,
# grep narrows the transcript and then answers whether a skill is among what
# was loaded, and dirname walks up to the nearest existing directory; a
# record run hands the payload over, reads it, makes the record's directory
# and removes the records gone stale. An unchecked absence is not a stall but
# a pass: a missing grep makes the transcript read empty, which is the loaded
# answer this hook must never reach by accident. So the whole set is checked
# before anything is judged, and the value names every one of them the PATH is
# missing, in the order checked.
case "$ARM" in
  check) TOOLS="jq git cat grep dirname" ;;
  record) TOOLS="jq cat mkdir find" ;;
esac
MISSING=""
for dependency in $TOOLS; do
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

# Whether Copilot made the call is read from the call, by the rule
# hooks/lane-mail-check.sh reads it by: both payload formats Copilot's hooks
# reference gives carry `timestamp`, and its own camelCase one names the
# session `sessionId`; no Claude Code, Pi, OpenCode or Cursor payload carries
# either. Copilot also runs the hooks `.claude/settings.json` registers, so a
# Copilot call can reach an install that is not Copilot's; that copy passes it
# under its own keyed line, since its loaded state is a transcript Copilot
# names nowhere and its answers take a shape Copilot does not read. The
# Copilot install is the one judge of a Copilot call.
CALL=$(printf '%s' "$INPUT" | jq -r 'if has("sessionId") or has("timestamp") then "copilot" else "" end' 2>/dev/null) ||
  refuse payload invalid-json
if [ "$CALL" = copilot ] && [ "$INSTALL" != copilot ]; then notice harness copilot; fi

# On Copilot the agent making the call is the payload's `sessionId`, which
# names a subagent apart from the session that launched it; the environment's
# COPILOT_AGENT_SESSION_ID does not, since a nested launch keeps the outer
# session's id there. The skills that agent loaded are recorded under that id
# in a directory of its own outside every repository, one file per agent, one
# skill per line, written by the record run below. The id is judged as the
# payload holds it before it names a file, in the alphabet the agent_id read
# below uses, so a `/`, a NUL or a newline cannot name another file.
if [ "$CALL" = copilot ] || [ "$ARM" = record ]; then
  SESSION=$(printf '%s' "$INPUT" | jq -r '.sessionId
    | if type == "string" and . != "" and gsub("[A-Za-z0-9_-]"; "") == "" then .
      else error("not a session id") end' 2>/dev/null) ||
    refuse payload invalid-session-id
  STATE_ROOT=${XDG_STATE_HOME:-}
  [ -n "$STATE_ROOT" ] || STATE_ROOT=${HOME:+$HOME/.local/state}
  case "$STATE_ROOT" in
    /*) ;;
    *) refuse state unlocatable ;;
  esac
  STATE_DIR=$STATE_ROOT/kendex/skill-load-check
  STATE=$STATE_DIR/$SESSION
fi

# A finished skill load, written down. Copilot fires postToolUse only after a
# tool succeeds and says so in the structured outcome, `toolResult.resultType`
# "success", which is what is read: the text meant for the model is not, and a
# request, a failed load and a denied one never reach this run as a success.
# A call that is no finished skill load records nothing. Each load is one
# line appended by a single write, so two loads finishing at once in one
# session both land, and a reader never sees half a line; the append also
# renews the file's time, so the prune after it never takes the record just
# written. A record untouched for 30 days belongs to a session long ended and
# is removed; a session resumed after that is refused once and loads again.
if [ "$ARM" = record ]; then
  SKILL=$(printf '%s' "$INPUT" | jq -r '
    if .toolName == "skill"
      and (.toolResult | if type == "object" then .resultType == "success" else false end)
    then .toolArgs
      | if type == "string" then fromjson else . end
      | if type == "object" then .skill else null end
      | if type == "string" and . != "" and gsub("[A-Za-z0-9._:-]"; "") == "" then .
        else error("not a skill name") end
    else "" end' 2>/dev/null) ||
    refuse payload invalid-skill
  [ -n "$SKILL" ] || exit 0
  umask 077
  WROTE=$(mkdir -p -- "$STATE_DIR" 2>&1) || refuse state unwritable "$WROTE"
  WROTE=$({ printf '%s\n' "$SKILL" >>"$STATE"; } 2>&1) || refuse state unwritable "$WROTE"
  PRUNED=$(find "$STATE_DIR" -type f -mtime +30 -exec rm -f {} + 2>&1) ||
    notice state unpruned "$PRUNED"
  exit 0
fi

# The call's command or targets, read where its harness carries them: Claude
# Code, Pi, OpenCode and Cursor under `tool_input`, one path; Copilot under
# `toolArgs`, which arrives as an object or as one JSON-encoded string. There
# the shell tools `bash` and `powershell` carry the command, and `edit`,
# `create` and `str_replace_editor` the path, whatever the last one's own
# command. `apply_patch` carries a patch in the grammar Copilot CLI parses it
# by, the toolArgs themselves or their `input` or `patch` string as its own
# renderer reads them, and every file it adds, updates, deletes or moves to
# is named on a `*** Add File: `, `*** Update File: `, `*** Delete File: ` or
# `*** Move to: ` line; each is judged as a target. A line holds no newline,
# so neither does a path read from one.
if [ "$CALL" = copilot ]; then
  IS_BASH='.toolName == "bash" or .toolName == "powershell"'
  ARGS='(.toolArgs | if type == "string" then fromjson else . end | if type == "object" then . else {} end)'
  COMMAND_AT="$ARGS | .command"
  TARGETS_AT='if .toolName == "apply_patch" then .toolArgs
      | if type == "string" then (. as $raw | try fromjson catch $raw) else . end
      | if type == "object" then (.input // .patch) else . end
      | strings | split("\n")[] | rtrimstr("\r")
      | capture("^[*]{3} (?:(?:Add|Update|Delete) File|Move to): (?<p>.+)$") | .p
    else '"$ARGS"' | .path end'
else
  IS_BASH='.tool_name == "Bash"'
  COMMAND_AT='.tool_input.command'
  TARGETS_AT='.tool_input.file_path // .tool_input.notebook_path'
fi

if [ "$(printf '%s' "$INPUT" | jq -r "$IS_BASH" 2>/dev/null)" = true ]; then
  REFUSED=$(printf '%s' "$INPUT" | jq -r "$COMMAND_AT"'
    | if type == "string" then . else error("not a string") end' 2>/dev/null) ||
    refuse payload no-command

  # The command reader is commit-guards' command-position library. A catalog
  # hook ships as one file, so the library comes from this hook's own install,
  # never from whichever repository the session has open, by the walk
  # hooks/lane-mail-check.sh owns for its reader: from the hook's physical
  # directory up five levels, stopping at the open repository's root and after
  # the home directory, where Pi's global hook sits four levels down, each
  # level's `skills/` and shared `.agents/skills/` tree; then the home's shared
  # tree, for a harness root CODEX_HOME, PI_CODING_AGENT_DIR or COPILOT_HOME
  # moved out of the home; then the repository's own copy, only where this hook
  # is installed in that repository. Without it no command can be read, and the
  # call is refused.
  LIBRARY=commit-guards/scripts/lib/command-position.sh
  AT=$(cd -P -- "$HOOK_DIR" 2>/dev/null && pwd -P) || AT=""
  HOME_DIR=$(cd -P -- "${HOME:-/}" 2>/dev/null && pwd -P) || HOME_DIR=""
  ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || ROOT=""
  FOUND_LIBRARY=""
  LEVELS=0
  while [ -n "$AT" ] && [ "$LEVELS" -lt 5 ] && [ "$AT" != "$ROOT" ] && [ "$AT" != / ]; do
    for candidate in "$AT/skills/$LIBRARY" "$AT/.agents/skills/$LIBRARY"; do
      if [ -f "$candidate" ]; then
        FOUND_LIBRARY=$candidate
        break
      fi
    done
    { [ -z "$FOUND_LIBRARY" ] && [ "$AT" != "$HOME_DIR" ]; } || break
    AT=${AT%/*}
    [ -n "$AT" ] || AT=/
    LEVELS=$((LEVELS + 1))
  done
  if [ -z "$FOUND_LIBRARY" ] && [ -n "$HOME_DIR" ] && [ "$HOME_DIR" != "$ROOT" ] \
    && [ -f "$HOME_DIR/.agents/skills/$LIBRARY" ]; then
    FOUND_LIBRARY="$HOME_DIR/.agents/skills/$LIBRARY"
  fi
  PHYSICAL_HOOK_DIR=$(cd -P -- "$HOOK_DIR" 2>/dev/null && pwd -P) || PHYSICAL_HOOK_DIR=""
  if [ -z "$FOUND_LIBRARY" ] && [ -n "$ROOT" ] && [ -f "$ROOT/.agents/skills/$LIBRARY" ]; then
    case "$PHYSICAL_HOOK_DIR" in
      "$ROOT"/*) FOUND_LIBRARY="$ROOT/.agents/skills/$LIBRARY" ;;
    esac
  fi
  [ -n "$FOUND_LIBRARY" ] || refuse missing-library "$LIBRARY"
  # shellcheck source=../skills/commit-guards/scripts/lib/command-position.sh
  source "$FOUND_LIBRARY"

  # A command rule matches each text the shell may execute, read from the word
  # it executes on and from every word after it; an edit rule never matches a
  # command.
  command_segments "$REFUSED"
  command_rule() { # TRIGGER SKILL
    case "$1" in
      bash:*)
        if [[ $CANDIDATE =~ ${1#bash:} ]]; then
          require "$2"
        fi
        ;;
    esac
  }
  while IFS= read -r SEGMENT; do
    command_text "$SEGMENT"
    while IFS= read -r CANDIDATE; do
      [ -z "$CANDIDATE" ] || each_rule command_rule
    done <<TEXTS
$COMMAND_TEXTS
TEXTS
  done <<EOF
$SEGMENTS
EOF
else
  # Every target, one JSON string per line so a path's own newline stays
  # inside it; none, or one that is not a string, leaves the edit unknown.
  TARGETS=$(printf '%s' "$INPUT" | jq -r "[$TARGETS_AT]"'
    | if length > 0 and all(type == "string") then .[] | tojson
      else error("no target") end' 2>/dev/null) ||
    refuse payload no-file-path

  # An edit glob reads extended patterns, so a rule can name what a path is
  # not, as the default code-quality rule does.
  shopt -s extglob
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

  # The skills the target REFUSED needs, added to REQUIRED.
  edit_target() {
    # Where the target is, is asked of the nearest directory that exists,
    # since a Write creates the missing ones. "Not a git repository" needs
    # nothing: a file outside every work tree is a session's own scratch and
    # no repository's code.
    DIR=$(dirname -- "$REFUSED")
    while [ ! -d "$DIR" ] && [ "$DIR" != "/" ] && [ "$DIR" != "." ]; do
      DIR=$(dirname -- "$DIR")
    done
    if ANSWER=$(git -C "$DIR" rev-parse --is-inside-work-tree 2>&1); then
      [ "$ANSWER" = "true" ] || return 0
    else
      case "$ANSWER" in
        *"not a git repository"*) return 0 ;;
      esac
      refuse git unreadable "$ANSWER"
    fi

    # The work tree's own tmp/ is scratch: commit messages, status files and
    # notes. git names the directory's place in the work tree, so the answer
    # does not depend on comparing two spellings of a path, one of which git
    # has already resolved through its symlinks. The same place is what an
    # edit rule's glob is matched against.
    PREFIX=$(git -C "$DIR" rev-parse --show-prefix 2>&1) || refuse git unreadable "$PREFIX"
    PLACE=$PREFIX${REFUSED#"$DIR"/}
    case "$PLACE" in
      tmp/*) return 0 ;;
    esac
    each_rule edit_rule
  }

  # A refusal names every target of the call, so a patch's refusal names
  # each file it would have written.
  ALL=""
  while IFS= read -r encoded; do
    REFUSED=$(printf '%s' "$encoded" | jq -r . 2>&1) || refuse payload no-file-path "$REFUSED"
    edit_target
    ALL=$ALL${ALL:+$LF}$REFUSED
  done <<EOF
$TARGETS
EOF
  REFUSED=$ALL
fi

[ -n "$REQUIRED" ] || exit 0
FIRST=${REQUIRED%%"$LF"*}

# The verdict once LOADED holds what the calling agent loaded, one skill per
# line: the call passes when every skill it needs is among them, and is
# refused on the first, in rule order, that is not.
judge_loaded() {
  while IFS= read -r skill; do
    [ -n "$skill" ] || continue
    grep -Fx -e "$skill" <<<"$LOADED" >/dev/null || refuse unloaded "$skill"
  done <<EOF
$REQUIRED
EOF
  exit 0
}

# A Copilot agent's loads are the record the run above keeps for its session:
# no record is no load yet, and a record that cannot be read is refused.
# Without the skill-load-record hook beside this one nothing writes that
# record, which is state this hook cannot read, so a call that needs a skill
# is refused under its own key, naming the manifest line that installs it.
if [ "$CALL" = copilot ]; then
  [ -f "$HOOK_DIR/skill-load-record.sh" ] || refuse carrier "$HOOK_DIR/skill-load-record.sh"
  [ -e "$STATE" ] || refuse unloaded "$FIRST"
  [ -f "$STATE" ] || refuse state unreadable
  LOADED=$(cat -- "$STATE" 2>&1) || refuse state unreadable "$LOADED"
  judge_loaded
fi

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
judge_loaded
