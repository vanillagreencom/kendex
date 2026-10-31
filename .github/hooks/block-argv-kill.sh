#!/usr/bin/env bash
# ---
# name: block-argv-kill
# event: PreToolUse
# matcher: Bash
# description: Refuse a command that kills processes by name or by argv pattern (`pkill`, `killall`), whatever flags follow. On a machine where several agents share one checkout and its worktrees, a pattern that matches a tool's name matches every lane running that tool, the caller's own shell included when its command line holds the pattern. Names the accepted forms: `kill <pid>` on a PID the caller recorded when it launched the process, or one whose `/proc/<pid>/cwd` the caller has read and found inside its own worktree. Inside a tmux session (`TMUX` set), also refuse a `tmux kill-server` or `kill-session` that names no `-S` or `-L` socket: tmux takes that server from `TMUX`, so the stop ends the caller's own session and its lane. Names `env -u TMUX tmux -S PATH`.
# summary: Stops a command that kills processes by name, which on a machine running several agents stops every lane using that tool, and, inside tmux, a tmux stop that names no socket, which ends your own session. Names the safe forms: kill a process id you started, or give tmux the socket you started.
# safety: For the name rule, one regex over the raw command decides: a `pkill` or `killall` word between two word edges, wherever in the command it stands, a path prefix, a quote or a substitution around it included. Reading the word wherever it stands refuses a harmless command that merely spells it, an echo or a heredoc line included, and that is the accepted cost: it fails closed, so it stalls one command rather than ending another lane's run. A word is seen only where the command already spells it: a spelling the shell assembles from quotes or escapes (`p\kill`, `p'kill'`) is not seen here and reaches the shell, the frozen lexical-scanner class every guard in this directory declares. `kill`, `pgrep` and `ps` are not read, so the same hazard spelled as `kill $(pgrep -f …)` or `pgrep -f … | xargs kill` passes; the rule is the two verbs, and the remedy text is what asks for a PID. The tmux rule holds only while `TMUX` is set in the hook's environment, which the harness inherits from its pane. Each simple command, split at `;`, `&`, `|`, parentheses, backquotes and newlines, is read word by word: after a `tmux` word, its flags and the arguments of `-c`, `-f`, `-L`, `-S` and `-T`, then its command word; `kill-server` or `kill-session` there is refused unless a `-L` or `-S` flag came first or an `env` before `tmux` unsets `TMUX` (`-u TMUX`, `-uTMUX`, `--unset=TMUX`). The same reading refuses `echo tmux kill-server`, and does not see a stop chained after `\;`, an abbreviated command name, a tmux the shell assembles at run time or one a script file runs. Missing tools or unreadable payload produce one keyed warning and allow the call. Every refusal opens with `block-argv-kill: <key>=<value>`; what a command this hook runs writes is captured at the site and replayed under that line, so nothing precedes the key.
# timeout: 10
# ---

set -euo pipefail
trap 'rc=$?; case $rc in 0 | 2) ;; *) refuse exit "$rc" ;; esac' EXIT

# The command as it was read, empty until the reader has it: the refusal quotes
# it, and a refusal can be reached before it is set.
COMMAND=""
# Every line this hook writes, and the only place its text lives. The first
# line is the contract a reader parses, `block-argv-kill: <key>=<value>`: a
# stable key for the condition and the value acted on — the missing tool, why
# the payload could not be read, or the verb the command spelled. The English
# explanation and the remedy follow on later lines.
# The keyed line stands first, at position 1. What a command this hook runs
# wrote is captured where the hook reads it and passed here as the cause, so
# it is replayed under the key rather than ahead of it.
refuse() { # KEY VALUE [CAUSE]
  printf 'block-argv-kill: %s=%s\n' "$1" "$2" >&2
  case "$1=$2" in
    missing-tools=*)
      echo "the commands ${2//,/, } are required to read the hook payload and are not on PATH; this check is unavailable" >&2
      ;;
    payload=unreadable)
      echo "the hook payload could not be read from stdin; this check is unavailable" >&2
      ;;
    payload=empty)
      echo "the hook payload is empty, which would read as an absent command; this check is unavailable" >&2
      ;;
    payload=invalid-json)
      echo "the hook payload is not valid JSON, or names a command that is not a string; this check is unavailable" >&2
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
    tmux-socket=*)
      printf 'block-argv-kill: fix=env -u TMUX tmux -S PATH %s\n' "$2" >&2
      echo "refusing a tmux stop that names no server:" >&2
      echo "  $COMMAND" >&2
      echo "Inside a tmux session, tmux takes the server from TMUX, so this stop ends the server your own session runs in." >&2
      echo "Name the server you started instead:" >&2
      echo "  env -u TMUX tmux -S PATH $2    PATH is the socket you gave tmux -S when you started it" >&2
      echo "  tmux -L NAME $2                NAME is the socket name you gave tmux -L" >&2
      ;;
  esac
  # The cause a command this hook ran wrote, captured at the site and replayed
  # here: under the keyed line, never ahead of it.
  [ -z "${3:-}" ] || printf '%s\n' "$3" >&2
  case "$1" in
    refused | tmux-socket | path) exit 2 ;;
    *)
      echo "Check skipped. Repair the hook installation, tools or payload adapter; retry the command." >&2
      exit 0 ;;
  esac
}

# jq is the only reader of the payload. Without it the command cannot be read,
# and a command this hook has not read cannot be shown to name a PID. The value
# names every one of them the PATH is missing, in the order checked.
MISSING=""
for dependency in jq cat; do
  command -v "$dependency" >/dev/null 2>&1 || MISSING="$MISSING,$dependency"
done
[ -z "$MISSING" ] || refuse missing-tools "${MISSING#,}"

# cat's words are captured, not left to precede the refusal: on failure the
# substitution holds what it wrote, and the refusal replays it under the keyed
# line. A cat that succeeds is silent, so the payload is not mixed with a
# diagnostic on the passing side.
INPUT=$(cat 2>&1) || refuse payload unreadable "$INPUT"
# An empty payload is no payload: jq reads nothing from it and says nothing,
# which would pass as an absent command.
case "$INPUT" in
  *[![:space:]]*) ;;
  *) refuse payload empty ;;
esac

# A payload that does not parse, or that names a command which is not a
# string, produces a warning and allows the call. An absent command is the empty
# string and passes. The command is read where each harness carries it:
# `tool_input.command` (Claude Code, Codex, Gemini CLI and the Pi carrier), a
# bare `command`, or Copilot's `toolArgs.command`, whose `toolArgs` arrives as
# an object or as one JSON-encoded string. The null tests are spelled out
# because jq's `//` reads `false` as absent, and `false` is not a command
# either.
COMMAND=$(printf '%s' "$INPUT" \
  | jq -er 'def copilot: .toolArgs
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

# The verb the command spelled is the second group of the regex above, the
# only one that carries it, so the first line names what was matched.
if [[ $COMMAND =~ $KILL_RE ]]; then
  refuse refused "${BASH_REMATCH[2]}"
fi

# With neither -S nor -L, tmux takes its server from $TMUX before TMUX_TMPDIR
# (tmux 3.7c, run recorded on KEN-4601), so inside a tmux session a stop that
# names no server reaches the caller's own: lane FLT-1418 ended on
# `TMUX_TMPDIR=$d tmux kill-server`. Each simple command, split at ; & | ( )
# backquote and newline, is read word by word: tmux's flags, the argument each
# of -c -f -L -S -T takes, then its command word. A -L or -S flag names the
# server; an `env` before tmux that unsets TMUX leaves none to inherit.
tmux_unnamed_stop() { # -> the stop verb on stdout; status 0 when one names no server
  local segments=$COMMAND nl=$'\n' sep segment word prev env_seen unset_tmux tmux_seen named want_arg
  local -a words
  for sep in ';' '&' '|' '(' ')' '`'; do segments=${segments//"$sep"/$nl}; done
  while IFS= read -r segment; do
    read -ra words <<<"$segment"
    env_seen=0 unset_tmux=0 tmux_seen=0 named=0 want_arg=0 prev=""
    for word in ${words[@]+"${words[@]}"}; do
      word=${word#[\"\']}
      word=${word%[\"\']}
      if [ "$tmux_seen" = 0 ]; then
        case "$word" in
          env) env_seen=1 ;;
          -uTMUX | --unset=TMUX) unset_tmux=$env_seen ;;
          TMUX) case "$prev" in -u | --unset) unset_tmux=$env_seen ;; esac ;;
          tmux | */tmux) tmux_seen=1 ;;
        esac
        prev=$word
      elif [ "$want_arg" = 1 ]; then
        want_arg=0
      elif [[ $word == -?* ]]; then
        [[ ! $word =~ ^-[2CDhlNuvV]*[LS] ]] || named=1
        [[ ! $word =~ ^-[2CDhlNuvV]*[cfLST]$ ]] || want_arg=1
      else
        case "$word" in
          kill-server | kill-session)
            if [ "$named" = 0 ] && [ "$unset_tmux" = 0 ]; then
              printf '%s' "$word"
              return 0
            fi ;;
        esac
        break
      fi
    done
  done <<<"$segments"
  return 1
}

# $TMUX is the hook's own environment, which the harness inherits from the
# pane the session runs in; unset, a stop with no socket reaches no session's
# server by inheritance.
if [ -n "${TMUX:-}" ] && STOP=$(tmux_unnamed_stop); then
  refuse tmux-socket "$STOP"
fi
