#!/usr/bin/env bash
# ---
# name: block-argv-kill
# event: PreToolUse
# matcher: Bash
# description: Refuse a command that kills processes by name or by argv pattern (`pkill`, `killall`), whatever flags follow. On a machine where several agents share one checkout and its worktrees, a pattern that matches a tool's name matches every lane running that tool, the caller's own shell included when its command line holds the pattern. Names the accepted forms: `kill <pid>` on a PID the caller recorded when it launched the process, or one whose `/proc/<pid>/cwd` the caller has read and found inside its own worktree.
# safety: One regex over the raw command decides: a `pkill` or `killall` word between two word edges, wherever in the command it stands, a path prefix, a quote or a substitution around it included. Reading the word wherever it stands refuses a harmless command that merely spells it, an echo or a heredoc line included, and that is the accepted cost: it fails closed, so it stalls one command rather than ending another lane's run. A word is seen only where the command already spells it: a spelling the shell assembles from quotes or escapes (`p\kill`, `p'kill'`) is not seen here and reaches the shell, the frozen lexical-scanner class every guard in this directory declares. `kill`, `pgrep` and `ps` are not read, so the same hazard spelled as `kill $(pgrep -f …)` or `pgrep -f … | xargs kill` passes; the rule is the two verbs, and the remedy text is what asks for a PID. A payload that cannot be read, an empty one included, is refused, never skipped.
# timeout: 10
# ---

set -euo pipefail

# The command as it was read, empty until the reader has it: the refusal quotes
# it, and a refusal can be reached before it is set.
COMMAND=""
# Every line this hook writes, and the only place its text lives. The first
# line is the contract a reader parses, `block-argv-kill: <key>=<value>`: a
# stable key for the condition and the value acted on — the missing tool, why
# the payload could not be read, or the verb the command spelled. The English
# explanation and the remedy follow on later lines.
refuse() { # KEY VALUE
  printf 'block-argv-kill: %s=%s\n' "$1" "$2" >&2
  case "$1=$2" in
    tools=*)
      echo "$2 is required to read the hook payload; refusing rather than skipping the guard" >&2
      ;;
    payload=unreadable)
      echo "the hook payload could not be read from stdin; refusing rather than skipping the guard" >&2
      ;;
    payload=empty)
      echo "the hook payload is empty, which would read as an absent command; refusing rather than skipping the guard" >&2
      ;;
    payload=invalid-json)
      echo "the hook payload is not valid JSON, or names a command that is not a string; refusing rather than skipping the guard" >&2
      ;;
    refused=*)
      echo "refusing a kill by process name or argv pattern:" >&2
      echo "  $COMMAND" >&2
      echo "On a shared machine the pattern matches every lane running that tool, and the caller's own shell when its command line holds the pattern." >&2
      echo "Kill one process you can name instead:" >&2
      echo "  kill <pid>                  a PID you recorded when you launched it" >&2
      echo "  readlink /proc/<pid>/cwd    then kill it only if that path is inside your own worktree" >&2
      echo "pgrep and ps are fine for finding a PID; the kill itself takes the PID." >&2
      ;;
  esac
  exit 2
}

# jq is the only reader of the payload. Without it the command cannot be read,
# and a command this hook has not read cannot be shown to name a PID. jq leads
# so the world with no tools at all names it.
for dependency in jq cat; do
  command -v "$dependency" >/dev/null 2>&1 || refuse tools "$dependency"
done

# cat's own diagnostic is dropped so the refusal's keyed line is the first
# line of this hook's stderr, as it is for every other condition.
INPUT=$(cat 2>/dev/null) || refuse payload unreadable
# An empty payload is no payload: jq reads nothing from it and says nothing,
# which would pass as an absent command.
case "$INPUT" in
  *[![:space:]]*) ;;
  *) refuse payload empty ;;
esac

# A payload that does not parse, or that names a command which is not a
# string, is refused rather than skipped. An absent command is the empty
# string and passes. The command is read where each harness carries it:
# `tool_input.command` (Claude Code, Codex, Gemini CLI and the Pi carrier), a
# bare `command`, or Copilot's `toolArgs.command`, whose `toolArgs` arrives as
# an object or as one JSON-encoded string. The null tests are spelled out
# because jq's `//` reads `false` as absent, and `false` is not a command
# either.
COMMAND=$(printf '%s' "$INPUT" \
  | jq -r 'def copilot: .toolArgs
             | if . == null then null elif type == "string" then fromjson else . end
             | if . == null then null elif type == "object" then .command else error end;
           if .tool_input.command != null then .tool_input.command
           elif .command != null then .command
           elif copilot != null then copilot
           else "" end
           | if type == "string" then . else error end' 2>/dev/null) ||
  refuse payload invalid-json

# The word between two edges: the ends of the command or any character an
# identifier cannot hold, so `/usr/bin/pkill`, `"pkill"` and `$(which pkill)`
# are the verb and `unpkill`, `pkill-wrapper` and `killall.log` are not. `=~`
# runs without REG_NEWLINE, so the edge classes admit a newline and a verb on
# the second line of a multi-line call is found; `^` alone would not reach it.
KILL_RE='(^|[^[:alnum:]_.-])(pkill|killall)($|[^[:alnum:]_.-])'

if [[ ! $COMMAND =~ $KILL_RE ]]; then
  exit 0
fi

# The verb the command spelled is the second group of the regex above, the
# only one that carries it, so the first line names what was matched.
refuse refused "${BASH_REMATCH[2]}"
