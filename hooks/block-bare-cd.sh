#!/usr/bin/env bash
# ---
# name: block-bare-cd
# event: PreToolUse
# matcher: Bash
# description: Not run on codex: each shell call starts a fresh process. Not run on pi: each shell call starts a fresh process. Not run on antigravity: its toolCall.args payload is not read. Refuse a command with a line that is only a `cd`. Copilot's bash tool runs every call in a fresh process, so a bare cd passes there; its powershell tool keeps the check. A here-document body is not judged because it is input to a command, not a line the shell runs. Where the shell persists across tool calls (Claude Code) a bare cd re-roots every later command and every hook that judges the working directory, while instruction files and hook paths stay with the launch directory; a cd into a worktree inside the repository, Claude Code's default `.claude/worktrees/<name>/`, also loads that tree's instruction files a second time as files there are read. Names the scoped form, `(cd /path && command)`, and, where the harness has one (Claude Code's EnterWorktree), its worktree tool for a move.
# summary: Stops a command whose whole line is a `cd`. A here-document body is not judged because it is input to a command, not a line the shell runs. Where the shell stays open between tool calls, that moves every later command with it. Names the scoped form to use instead.
# safety: Reads command text using its local here-document check. Missing tools or unreadable payload produce one keyed warning and allow the call. A matching bare-cd line still refuses. Every refusal opens with `block-bare-cd: <key>=<value>`; captured command output follows that line.
# harnesses: [claude, copilot, gemini, cursor, opencode]
# ---

set -euo pipefail
trap 'rc=$?; case $rc in 0 | 2) ;; *) refuse exit "$rc" ;; esac' EXIT

# Every line this hook writes, and the only place its text lives. The first
# line is the contract a reader parses: the keys and values are the fixed set
# hooks/AGENTS.md names, and the English explanation and the rewrite follow on
# later lines.
# The keyed line stands first, at position 1. What a command this hook runs
# wrote is captured where the hook reads it and passed here as the cause, so
# it is replayed under the key rather than ahead of it.
refuse() { # KEY VALUE [CAUSE]
  printf 'block-bare-cd: %s=%s\n' "$1" "$2" >&2
  case "$1=$2" in
    missing-tools=*)
      echo "the commands ${2//,/, } are required to read the hook payload and are not on PATH; this check is unavailable" >&2
      ;;
    payload=invalid-json)
      echo "the hook payload is not valid JSON, or names a command that is not a string; this check is unavailable" >&2
      ;;
    refused=bare-cd)
      echo "Where the shell persists across tool calls a bare cd re-roots every later command and every hook judging the working directory, while instruction files and hook paths stay with the launch directory." >&2
      echo "  Use a subshell instead: (cd /path && command). To work in a worktree, enter it with the harness's worktree tool where it has one (Claude Code's EnterWorktree) rather than cd." >&2
      ;;
  esac
  # The cause a command this hook ran wrote, captured at the site and replayed
  # here: under the keyed line, never ahead of it.
  [ -z "${3:-}" ] || printf '%s\n' "$3" >&2
  case "$1" in
    refused | path) exit 2 ;;
    *)
      echo "Check skipped. Repair the hook installation, tools or payload adapter; retry the command." >&2
      exit 0 ;;
  esac
}

# jq is the only reader of the payload, and grep and sed make every decision
# after it. Without them the command cannot be read, and a command this hook
# has not read cannot be shown to scope its directory change. The value names
# every one of them the PATH is missing, in the order checked.
MISSING=""
for dependency in jq cat grep sed; do
  command -v "$dependency" >/dev/null 2>&1 || MISSING="$MISSING,$dependency"
done
[ -z "$MISSING" ] || refuse missing-tools "${MISSING#,}"

INPUT=$(cat 2>&1) || refuse payload unreadable "$INPUT"

# A payload that does not parse, or that names a command which is not a
# string, produces a warning and allows the call. An absent command is the empty
# string and passes. The command is read where each harness carries it:
# `tool_input.command` (Claude Code, Codex, Gemini CLI and the Pi carrier), a
# bare `command`, or Copilot's `toolArgs.command`, whose `toolArgs` arrives as
# an object or as one JSON-encoded string. The null tests are spelled out
# because jq's `//` reads `false` as absent, and `false` is not a command
# either. Copilot's `toolName` bash runs each call in a fresh process
# (Copilot CLI 1.0.105's tool instructions: a cd does not persist between
# calls), so its command is read and then judged as empty; the Bash matcher
# also reaches `toolName` powershell, which keeps the check.
COMMAND=$(printf '%s' "$INPUT" \
  | jq -er 'def copilot: .toolArgs
             | if . == null then null elif type == "string" then fromjson else . end
             | if . == null then null elif type == "object" then .command else error end;
           (.toolName == "bash") as $fresh
           | if .tool_input.command != null then .tool_input.command
           elif .command != null then .command
           elif copilot != null then copilot | if $fresh and type == "string" then "" else . end
           else "" end
           | if type == "string" then . else error end' 2>/dev/null) ||
  refuse payload invalid-json

# Only a matching later terminator makes the intervening lines command input.
# This local text check needs no shell parser. It handles the first here-document
# on a line; a second body's lines keep the existing judgement.
LINES=()
while IFS= read -r line; do LINES[${#LINES[@]}]=$line; done <<<"$COMMAND"
HEREDOC_RE='(^|[^<])<<(-?)[[:blank:]]*("([^"]*)"|'"'"'([^'"'"']*)'"'"'|([^[:space:]<>&;|]+))'
JUDGED=""
for ((i=0; i<${#LINES[@]}; i++)); do
  JUDGED=$JUDGED${LINES[$i]}$'\n'
  if [[ ${LINES[$i]} =~ $HEREDOC_RE ]]; then
    strip_tabs=${BASH_REMATCH[2]}
    delimiter=${BASH_REMATCH[4]}${BASH_REMATCH[5]}${BASH_REMATCH[6]}
    for ((end=i+1; end<${#LINES[@]}; end++)); do
      terminator=${LINES[$end]}
      if [ "$strip_tabs" = - ]; then
        while [[ $terminator == $'\t'* ]]; do terminator=${terminator#$'\t'}; done
      fi
      if [ "$terminator" = "$delimiter" ]; then i=$end; break; fi
    done
  fi
done

# A line that is only a cd, its operand optional on both sides: a bare `cd`
# goes to $HOME, the same move as `cd /tmp`. sed strips the leading whitespace
# of every line so an indented one is read the same; grep reads the whole
# command rather than stopping at the first match, since an early-exiting
# reader turns its producer's SIGPIPE into status 141 under pipefail, read
# here as "no bare cd".
STRIPPED=$(echo "$JUDGED" | sed 's/^[[:space:]]*//')
BARE_STATUS=0
printf '%s\n' "$STRIPPED" | grep -E '^cd([[:space:]]+[^&|;]*)?$' >/dev/null || BARE_STATUS=$?
if [ "$BARE_STATUS" -eq 0 ]; then
  refuse refused bare-cd
fi

exit 0
