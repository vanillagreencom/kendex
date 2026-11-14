#!/usr/bin/env bash
# Private bridge to orch's model classes for a task, and the attach window.
set -euo pipefail
ROOT="$(cd -- "${BASH_SOURCE[0]%/*}/../../.." && pwd -P)"
for package in mailbox; do
  if [[ ! -d "$ROOT/$package/scripts" ]]; then
    printf 'jarvis-session: dependency=%s\n' "$package" >&2
    exit 1
  fi
done
verb="$1"
shift
case "$verb" in
  unattended)
    # `named` where the home HOME ($2) names HARNESS ($1) among the
    # harnesses whose managed session runs with nobody at its pane; the
    # subshell reads that one key, so no other home setting reaches a launch.
    source "$ROOT/jarvis/scripts/lib/jarvis-env.sh"
    jarvis_load "$2"
    IFS=, read -r -a named <<<"${JARVIS_UNATTENDED_HARNESSES:-}"
    for entry in ${named[@]+"${named[@]}"}; do
      kendex_trim entry "$entry"
      [[ "$entry" != "$1" ]] || printf 'named\n'
    done
    exit ;;
esac
# Run COMMAND in the background in a session of its own, so the terminal
# window outlives this bridge: stdin from /dev/null, stdout appended to OUT,
# stderr to ERR, and $! its PID. Without setsid (macOS) the github package's
# group leader makes the group, with no job-control setpgid race, and execs
# COMMAND.
jarvis_run_detached() { # OUT ERR COMMAND...
  local out="$1" err="$2" lib="$ROOT/github/scripts/lib/group-leader.sh"
  shift 2
  if command -v setsid >/dev/null 2>&1; then
    setsid "$@" </dev/null >>"$out" 2>>"$err" &
  else
    # Bash 3.2 can exit on a missing source even in a checked branch.
    # shellcheck source=../../../github/scripts/lib/group-leader.sh
    { [[ -f "$lib" && -r "$lib" ]] && source "$lib"; } || {
      printf 'jarvis-session: detached=group-leader-missing path=%s\n' "$lib" >&2
      return 2
    }
    command -v perl >/dev/null 2>&1 || {
      printf 'jarvis-session: detached=missing-command commands=perl\n' >&2
      return 2
    }
    nohup "${KENDEX_GROUP_LEADER[@]}" "$@" </dev/null >>"$out" 2>>"$err" &
  fi
}

# A process's one-letter state, or an empty line where it has gone. In
# /proc/PID/stat the command name can hold spaces and `)`, so the state
# follows the last `)`. Without /proc (macOS) `ps` answers: status 1 with
# nothing printed is a process that has gone, any other failure status 2,
# no answer.
jarvis_process_state() { # PID
  local stat rest rc=0
  if [[ -d /proc/self ]]; then
    stat="$(cat -- "/proc/$1/stat" 2>/dev/null)" || stat=""
    rest="${stat##*)}"
    rest="${rest# }"
    printf '%s\n' "${rest%% *}"
    return 0
  fi
  stat="$(ps -o stat= -p "$1" 2>/dev/null)" || rc=$?
  stat="${stat//[[:space:]]/}"
  if [[ "$rc" -ne 0 ]]; then
    [[ "$rc" -eq 1 && -z "$stat" ]] || return 2
  fi
  printf '%s\n' "${stat:0:1}"
}

case "$verb" in
  task-model)
    # The harness, model and effort a task of HARNESS ($1) on MODEL ($2) at
    # EFFORT ($3) runs, a model class resolved for the home HOME ($4).
    source "$ROOT/jarvis/scripts/lib/jarvis-env.sh"
    jarvis_load "$4"
    # The three read as one HARNESS:MODEL:EFFORT entry. An all-digit model
    # names the native default. kendex classifies any other word: a class
    # runs claude's alias, a trailing [1m] kept, and codex's and copilot's
    # native default, its warning printed once; an exact id runs as written.
    # claude's managed launch asks with no runtime context, codex and copilot
    # with one that names no model list.
    IFS=: read -r harness model effort <<<"$1:$2:$3"
    [[ ! "$model" =~ ^[1-9][0-9]*$ ]] || model=""
    if [[ -n "$model" && "$harness" =~ ^(claude|codex|copilot)$ ]]; then
      word="$model" window=""
      if [[ "$word" =~ ^(.+)(\[1[mM]\])$ ]]; then word="${BASH_REMATCH[1]}" window="${BASH_REMATCH[2]}"; fi
      ask=(tier-model "$harness" --model "$word" --json)
      printf -v context '{"protocol":"model-resolution-v1","harness":"%s","account":"unpicked","host":"unpicked","providers":[],"currentProvider":null,"models":{"tag":"unsupported","source":"orch-launch"},"default":{"tag":"native-default"},"capacity":[],"rejected":[]}' "$harness"
      [[ "$harness" == claude ]] || ask+=(--runtime-context-json "$context")
      unread() { printf 'jarvis-task: selection=model-unread\n%s\n' "$1" >&2; exit 1; }
      answer="$(kendex "${ask[@]}" 2>&1)" || unread "$answer"
      fields="$(jq -r 'if .protocol == "model-resolution-v1" and (.request.tag | type) == "string"
          then [.request.tag, .warning // "", .resolution.native_selector // ""] | map(tostring) | join("\u001f")
          else error("no model-resolution answer") end' <<<"$answer" 2>&1)" || unread "$answer"$'\n'"$fields"
      # A unit separator, not a tab, which read would fold with an empty field.
      IFS=$'\x1f' read -r tag warning selector <<<"$fields"
      if [[ "$tag" != class ]]; then warning=""
      elif [[ "$harness" != claude ]]; then model=""
      elif [[ -n "$selector" ]]; then model="$selector$window"
      else unread "$answer"
      fi
      [[ -z "$warning" ]] || printf '%s\n' "$warning" >&2
    fi
    jq -cn --arg harness "$harness" --arg model "$model" --arg effort "$effort" \
      '{harness:$harness,model:$model,effort:$effort}' ;;
  open-window)
    # The attach a caller inside a tmux client opens in a new window of the
    # user's own terminal, from the caller's environment less TMUX and
    # TMUX_PANE, which jarvis-session clears. Status 3 is no terminal: no
    # $TERMINAL and no xdg-terminal-exec on PATH. 4 is a $TERMINAL naming
    # nothing on PATH with no xdg-terminal-exec, which is not that absence. 5
    # is a
    # terminal that exited non-zero, put no new client on the session within
    # 5 seconds or whose process state could not be read.
    socket="$1" session="$2"
    printf -v line 'exec tmux -S %q attach-session -t %q' "$socket" "=$session"
    # The user's configured terminal, then the desktop's. This does not share
    # orch's private open_gui choice: KEN-4687's owner-held replacement owns
    # orch and migrates its adjacent callers, so one shared choice is a
    # caller-integration concern for that rebuild.
    if [[ -n "${TERMINAL:-}" ]] && command -v "$TERMINAL" >/dev/null 2>&1; then
      launch=("$TERMINAL" -e bash -lc "$line")
    elif command -v xdg-terminal-exec >/dev/null 2>&1; then
      launch=(xdg-terminal-exec bash -lc "$line")
    elif [[ -n "${TERMINAL:-}" ]]; then
      printf 'jarvis-session: terminal=unresolved requested=%s\n' "$TERMINAL" >&2
      exit 4
    else
      exit 3
    fi
    [[ -z "${TERMINAL:-}" || "${launch[0]}" == "$TERMINAL" ]] ||
      printf 'jarvis-session: terminal=fallback requested=%s selected=%s\n' "$TERMINAL" "${launch[0]}" >&2
    clients() { tmux -S "$socket" list-clients -t "=$session" -F '#{client_pid}'; }
    before="$(clients)" || exit 5
    # The terminal's own stderr names why it failed, such as a display it
    # could not reach; its tail follows a non-zero exit.
    errors="$(mktemp "${TMPDIR:-/tmp}/jarvis-terminal.XXXXXX")" || exit 5
    trap 'rm -f -- "$errors"' EXIT
    jarvis_run_detached /dev/null "$errors" "${launch[@]}" || exit 5
    launcher="$!" waited=0
    # A terminal that hands its window to a running server exits 0 at once,
    # so only a new client on the session proves the window opened.
    while (( waited < 50 )); do
      after="$(clients)" || exit 5
      for pid in $after; do
        [[ $'\n'"$before"$'\n' == *$'\n'"$pid"$'\n'* ]] || exit 0
      done
      if [[ -n "$launcher" ]]; then
        state="$(jarvis_process_state "$launcher")" || {
          printf 'jarvis-session: launcher-state=unread pid=%s\n' "$launcher" >&2
          exit 5
        }
        if [[ -z "$state" || "$state" == Z ]]; then
          rc=0
          wait "$launcher" || rc=$?
          if [[ "$rc" != 0 ]]; then
            printf 'jarvis-session: terminal=%s exit=%s\n' "${launch[0]}" "$rc" >&2
            tail -n 5 -- "$errors" >&2
            exit 5
          fi
          launcher=""
        fi
      fi
      sleep 0.1
      waited=$((waited + 1))
    done
    printf 'jarvis-session: terminal=%s client=none seconds=5\n' "${launch[0]}" >&2
    exit 5 ;;
  *) printf 'jarvis-session: backend=%s\n' "$verb" >&2; exit 2 ;;
esac
