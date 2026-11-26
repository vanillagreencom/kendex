#!/usr/bin/env bash
# ---
# name: stop-failure-row
# event: StopFailure
# matcher:
# description: Records that a turn ended on an API error, as one JSON row the fleet's overseer judgement reads instead of the session's pane: the runtime watch judges an overseer whose last row is a StopFailure with error `rate_limit` or `billing_error` as walled, Claude Code's own words for a usage limit and spent credit, or on Pi, which names no error kind, one whose `message` agent-runtime's limit-banner reader reads as the account's limit, or that opens with a 401, a refused sign-in, whatever its pane shows, and the lane-mail-check hook writes a Stop row over it at the overseer's next turn end, which lifts it. The row is written by the lane-mail-check hook, run from beside this one with the argument `row`, through agent-runtime's rows writer, which that hook's install's `orch-runtime turn-end` calls: it carries the time, the event, the harness, the payload's `session_id`, `transcript_path`, `cwd`, `error` and `error_details`, its `last_assistant_message` as `message`, which holds the harness's own text of the limit and its reset, and the account directory this hook's own environment names. A subagent's failure, whose payload carries an `agent_id`, writes nothing. A launched Claude Code lane lead writes StopFailure and the payload's `error` to its own `session-rows.jsonl`, or `refusal` for a safety refusal; its lane verdict is Idle with that cause, or Walled for a usage limit or spent credit (`rate_limit`, `billing_error`) and for a refused sign-in. No Stop follows that failure event. Pi keeps its lane's Stop row as the turn-end evidence. It lands in `tmp/lane-mail/overseer/session-<tmux server pid>-<pane number>.jsonl` at the main checkout, the file the fleet record's `controller.session_rows` names, under a `flock` on that file alone, and only where that directory already stands; for an overseer row, a session outside tmux and a harness another harness started in the same pane, whose process ancestry contains more than one harness, counting the installed Codex Node launcher and its direct native child as one harness, write nothing and say nothing. An install with no mailbox reader or no `orch-runtime` writes nothing and is reported under `lane-mail-check: reader=unlocatable` or `lane-mail-check: runtime=unlocatable`. A row that could not be written is reported under `lane-mail-check: rows-unwritten=<checkout>`. A lane-mail-check missing from beside this hook is reported under `stop-failure-row: judge=<path>`. Not run on codex: it has no StopFailure event (Codex hooks reference, CLI 0.160.0). For an overseer on codex the fleet watch judges a failed turn from the overseer's pane and its account headroom instead. On Pi it runs at `agent_before_settle` through the pi-hooks carrier, only on a run whose outcome is `error`, never on a completed or aborted one: the payload carries no `error`, and its `last_assistant_message` is the failed response's `errorMessage` where the carrier sends one. the runtime watch judges a Pi row only from the evidence it carries, a SessionEnd or a StopFailure with a `message`, and reads the pane of a Pi session whose last row is any other, its SessionStart, its Stop or a StopFailure with no `message`. Not run on gemini: it has no StopFailure event. The fleet watch reads nothing in its place: an orch overseer runs only on claude, codex, copilot or pi, the harnesses the runtime launches a session on, so a row on gemini would have no reader. Not run on copilot: errorOccurred fires once per recoverable model-call retry, six times for one failed turn, and Copilot has no turn-failure event (Copilot hooks reference, CLI 1.0.91). For an overseer on copilot the fleet watch judges a failed turn from the overseer's pane and its account headroom instead. Not run on antigravity: it has no StopFailure event. The fleet watch reads nothing in its place: an orch overseer runs only on claude, codex, copilot or pi, the harnesses the runtime launches a session on, so a row on antigravity would have no reader.
# summary: Writes down that a turn stopped on an error such as a usage limit, so a fleet's overseer that hits its limit is seen to be stuck without anyone reading its screen.
# safety: Runs only the lane-mail-check hook installed in its own directory, which appends one row to a file in the overseer mailbox directory under a lock on that file and reads the tmux pane id, server pid and pane shell pid, its own process ancestry through `ps`, the payload and its own environment. It refuses nothing and exits 0.
# timeout: 30
# harnesses: [claude, pi, opencode, cursor]
# requires: [lane-mail-check]
# ---
# kendex: a pi-hooks carrier before 0.19.3 names no registration, so this
# render reads it from the path the registry spawned (docs/adapters/pi.md).
if [ -z "${KENDEX_HOOK_SCOPE+set}${KENDEX_HOOK_ROOT+set}" ]; then
  kendex_hook_at=${BASH_SOURCE[0]-}
  kendex_hook_tail='/kendex/hooks/stop-failure-row.sh'
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
# resolves the orch install the row library comes from. The harness reads
# nothing this hook says, so a writer that is not there is said and passed.
JUDGE=""
if HOOK_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P); then
  JUDGE="$HOOK_DIR/lane-mail-check.sh"
fi
if [ -z "$JUDGE" ] || [ ! -f "$JUDGE" ]; then
  printf 'stop-failure-row: judge=%s\n%s\n' "${JUDGE:-unlocatable}" \
    "the lane-mail-check hook this one runs is not installed beside it, so this turn's failure is not recorded and the overseer judgement reads its pane, the named fallback; install lane-mail-check in the same scope" >&2
  exit 0
fi
exec "$BASH" "$JUDGE" row StopFailure
