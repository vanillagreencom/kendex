#!/usr/bin/env bash
# ---
# name: session-end-row
# event: SessionEnd
# matcher:
# description: Records that a session ended, as one JSON row the fleet's overseer judgement reads instead of the session's pane: the runtime watch judges an overseer whose last row is a SessionEnd for any reason but `clear` or `resume` as exited only where its pane's process is a bare shell with nothing under it, and as live over a running process, whatever its screen shows. The row is written by the lane-mail-check hook, run from beside this one with the argument `row`, through agent-runtime's rows writer, which that hook's install's `orch-runtime turn-end` calls: it carries the time, the event, the harness, the payload's `session_id`, `transcript_path`, `cwd` and `reason`, and the account directory this hook's own environment names. It lands in `tmp/lane-mail/overseer/session-<tmux server pid>-<pane number>.jsonl` at the main checkout, the file the fleet record's `controller.session_rows` names, under a `flock` on that file alone, and only where that directory already stands; a session outside tmux, a session with a lane of its own and a harness another harness started in the same pane, whose process ancestry contains more than one harness, counting the installed Codex Node launcher and its direct native child as one harness, write nothing and say nothing. An install with no mailbox reader or no `orch-runtime` writes nothing and is reported under `lane-mail-check: reader=unlocatable` or `lane-mail-check: runtime=unlocatable`. A row that could not be written is reported under `lane-mail-check: rows-unwritten=<checkout>`, and the session ends either way. A lane-mail-check missing from beside this hook is reported under `session-end-row: judge=<path>`. Its timeout is 3 s, the longest Codex runs a SessionEnd hook (Codex hooks reference, CLI 0.160.0). On codex: the runtime watch judges no Codex row and reads that session's pane instead. On Pi it runs at `session_shutdown` through the pi-hooks carrier from 0.18.0, which says Pi's reason in Claude Code's words: `prompt_input_exit` for `quit`, `clear` for `new` and `fork`, and `resume` for `resume` and `reload`. Not run on gemini: the lane-mail-check hook it runs is not installed there, having no Stop event. The fleet watch reads nothing in its place: an orch overseer runs only on claude, codex, copilot or pi, the harnesses the runtime launches a session on, so a row on gemini would have no reader. On Copilot it runs at sessionEnd, which Copilot CLI 1.0.91 fires for the lead session alone and never for a subagent, with a `reason` of complete, error, abort, timeout or user_exit, and the row takes the payload's `sessionId`; the runtime watch judges Claude Code's rows, and a Pi row only where it is a SessionEnd or a StopFailure with a `message`, and reads the pane of a session whose last row is any other. On copilot: the runtime watch judges no Copilot row and reads that session's pane instead. Not run on antigravity: it has no SessionEnd event. The fleet watch reads nothing in its place: an orch overseer runs only on claude, codex, copilot or pi, the harnesses the runtime launches a session on, so a row on antigravity would have no reader.
# summary: Writes down that a session ended, so a fleet's overseer that exits is seen to have exited without anyone reading its screen.
# safety: Runs only the lane-mail-check hook installed in its own directory, which appends one row to a file in the overseer mailbox directory under a lock on that file and reads the tmux pane id, server pid and pane shell pid, its own process ancestry through `ps`, the payload and its own environment. It refuses nothing and exits 0.
# timeout: 3
# harnesses: [claude, codex, pi, copilot, opencode, cursor]
# requires: [lane-mail-check]
# ---
# kendex: a pi-hooks carrier before 0.19.3 names no registration, so this
# render reads it from the path the registry spawned (docs/adapters/pi.md).
if [ -z "${KENDEX_HOOK_SCOPE+set}${KENDEX_HOOK_ROOT+set}" ]; then
  kendex_hook_at=${BASH_SOURCE[0]-}
  kendex_hook_tail='/kendex/hooks/session-end-row.sh'
  kendex_hook_scope=''
  case ${kendex_hook_at//\\//} in
    */.pi"$kendex_hook_tail") kendex_hook_scope=project ;;
    *"$kendex_hook_tail") kendex_hook_scope=global ;;
  esac
  if [ "$kendex_hook_scope" = project ]; then
    kendex_hook_win=''
    case ${OSTYPE-} in msys* | cygwin* | win32*) kendex_hook_win=1 ;; esac
    kendex_hook_home=${HOME-}
    [ -z "$kendex_hook_win" ] || kendex_hook_home=${USERPROFILE-}
    kendex_hook_rest=${PI_CODING_AGENT_DIR-}
    kendex_hook_rest=${kendex_hook_rest#"${kendex_hook_rest%%[![:space:]]*}"}
    kendex_hook_rest=${kendex_hook_rest%"${kendex_hook_rest##*[![:space:]]}"}
    case $kendex_hook_rest in
      '~') kendex_hook_rest=$kendex_hook_home ;;
      '~/'*) kendex_hook_rest=$kendex_hook_home/${kendex_hook_rest:2} ;;
    esac
    kendex_hook_rest=${kendex_hook_rest//\\//}
    kendex_hook_lead=''
    if [ -z "$kendex_hook_win" ]; then
      case $kendex_hook_rest in /*) ;; *) kendex_hook_rest='' ;; esac
    else
      case $kendex_hook_rest in
        [A-Za-z]:/*) kendex_hook_lead=${kendex_hook_rest:0:2} kendex_hook_rest=${kendex_hook_rest:2} ;;
        //[!/]*/[!/]*) kendex_hook_lead=/ ;;
        *) kendex_hook_rest='' ;;
      esac
    fi
    kendex_hook_global=''
    if [ -n "$kendex_hook_rest" ]; then
      while [ -n "$kendex_hook_rest" ]; do
        kendex_hook_part=${kendex_hook_rest%%/*}
        case $kendex_hook_rest in */*) kendex_hook_rest=${kendex_hook_rest#*/} ;; *) kendex_hook_rest='' ;; esac
        case $kendex_hook_part in
          '' | .) ;;
          ..) kendex_hook_global=${kendex_hook_global%/*} ;;
          *) kendex_hook_global=$kendex_hook_global/$kendex_hook_part ;;
        esac
      done
      kendex_hook_global=$kendex_hook_lead${kendex_hook_global:-/}
    fi
    kendex_hook_pi=${kendex_hook_at//\\//}
    kendex_hook_pi=${kendex_hook_pi%"$kendex_hook_tail"}
    if [ -n "$kendex_hook_global" ] && [ "$kendex_hook_global" = "$kendex_hook_pi" ]; then
      kendex_hook_scope=global
      kendex_hook_project=${kendex_hook_pi%/.pi}
      case $kendex_hook_project in '' | [A-Za-z]:) kendex_hook_project=$kendex_hook_project/ ;; esac
      # The carrier's project: config.ts::walkProjectRoot from its cwd.
      kendex_hook_here=$(pwd -P 2>/dev/null) || kendex_hook_here=''
      while [ -n "$kendex_hook_here" ]; do
        [ ! -f "$kendex_hook_here/.kendex-lock.json" ] || break
        if [ "$kendex_hook_here" -ef "$kendex_hook_home" ]; then
          kendex_hook_here=''
          break
        fi
        for kendex_hook_marker in .claude .codex .opencode .cursor .pi .agents .gemini; do
          [ ! -d "$kendex_hook_here/$kendex_hook_marker" ] || break 2
        done
        case $kendex_hook_here in
          */?*)
            kendex_hook_here=${kendex_hook_here%/*}
            kendex_hook_here=${kendex_hook_here:-/}
            ;;
          *) kendex_hook_here='' ;;
        esac
      done
      if [ -n "$kendex_hook_here" ] && [ "$kendex_hook_here" -ef "$kendex_hook_project" ]; then
        kendex_hook_scope=both
      fi
    else
      kendex_hook_tail=/.pi$kendex_hook_tail
    fi
  fi
  case $kendex_hook_scope in
    project | global)
      kendex_hook_root=${kendex_hook_at:0:${#kendex_hook_at}-${#kendex_hook_tail}}
      case ${kendex_hook_root//\\//} in
        '') kendex_hook_root=${kendex_hook_at:0:1} ;;
        [A-Za-z]:) kendex_hook_root+=${kendex_hook_at:2:1} ;;
      esac
      case ${kendex_hook_root//\\//} in
        /* | [A-Za-z]:/*) export KENDEX_HOOK_SCOPE=$kendex_hook_scope KENDEX_HOOK_ROOT="$kendex_hook_root" ;;
      esac
      ;;
  esac
  unset kendex_hook_at kendex_hook_tail kendex_hook_scope kendex_hook_win kendex_hook_home \
    kendex_hook_rest kendex_hook_lead kendex_hook_global kendex_hook_part kendex_hook_pi \
    kendex_hook_project kendex_hook_here kendex_hook_marker kendex_hook_root
fi

set -euo pipefail

# The writer is the lane-mail-check hook installed beside this one, which
# resolves the orch install the row library comes from. A session's end is
# never held on its own record, so a writer that is not there is said and
# passed. The event is named for a payload that spells none, as Copilot's.
JUDGE=""
if HOOK_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P); then
  JUDGE="$HOOK_DIR/lane-mail-check.sh"
fi
if [ -z "$JUDGE" ] || [ ! -f "$JUDGE" ]; then
  printf 'session-end-row: judge=%s\n%s\n' "${JUDGE:-unlocatable}" \
    "the lane-mail-check hook this one runs is not installed beside it, so this session's end is not recorded and the overseer judgement reads its pane, the named fallback; install lane-mail-check in the same scope" >&2
  exit 0
fi
exec "$BASH" "$JUDGE" row SessionEnd
