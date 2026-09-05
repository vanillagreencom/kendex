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

# jq is the only reader of the payload. Without it the command cannot be read,
# and a command this hook has not read cannot be shown to name a PID.
if ! command -v jq >/dev/null 2>&1 || ! command -v cat >/dev/null 2>&1; then
  echo "block-argv-kill: jq and cat are required to read the hook payload; refusing rather than skipping the guard" >&2
  exit 2
fi

INPUT=$(cat) || {
  echo "block-argv-kill: could not read the hook payload from stdin; refusing rather than skipping the guard" >&2
  exit 2
}
# An empty payload is no payload: jq reads nothing from it and says nothing,
# which would pass as an absent command.
case "$INPUT" in
  *[![:space:]]*) ;;
  *)
    echo "block-argv-kill: the hook payload is empty; refusing rather than skipping the guard" >&2
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
  echo "block-argv-kill: hook payload is not valid JSON, or names a command that is not a string; refusing rather than skipping the guard" >&2
  exit 2
fi

# The word between two edges: the ends of the command or any character an
# identifier cannot hold, so `/usr/bin/pkill`, `"pkill"` and `$(which pkill)`
# are the verb and `unpkill`, `pkill-wrapper` and `killall.log` are not. `=~`
# runs without REG_NEWLINE, so the edge classes admit a newline and a verb on
# the second line of a multi-line call is found; `^` alone would not reach it.
KILL_RE='(^|[^[:alnum:]_.-])(pkill|killall)($|[^[:alnum:]_.-])'

if [[ ! $COMMAND =~ $KILL_RE ]]; then
  exit 0
fi

{
  echo "block-argv-kill: refusing a kill by process name or argv pattern:"
  echo "  $COMMAND"
  echo "On a shared machine the pattern matches every lane running that tool, and the caller's own shell when its command line holds the pattern."
  echo "Kill one process you can name instead:"
  echo "  kill <pid>                  a PID you recorded when you launched it"
  echo "  readlink /proc/<pid>/cwd    then kill it only if that path is inside your own worktree"
  echo "pgrep and ps are fine for finding a PID; the kill itself takes the PID."
} >&2
exit 2
