#!/usr/bin/env bash
# Private bridge to orch's model classes for a task, and the attach window.
set -euo pipefail
ROOT="$(cd -- "${BASH_SOURCE[0]%/*}/../../.." && pwd -P)"
SCRIPT_DIR="$ROOT/orch/scripts"
for package in mailbox orch; do
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
source "$SCRIPT_DIR/lib/lane-launch.sh"
source "$SCRIPT_DIR/lib/lane-state.sh"
source "$SCRIPT_DIR/lib/pane-write.sh"
source "$SCRIPT_DIR/lib/copilot-session.sh"
source "$SCRIPT_DIR/lib/lane-relaunch.sh"
source "$SCRIPT_DIR/lib/tmux-server.sh"
case "$verb" in
  task-model)
    # The harness, model and effort a task of HARNESS ($1) on MODEL ($2) at
    # EFFORT ($3) runs, a model class resolved for the home HOME ($4).
    source "$ROOT/jarvis/scripts/lib/jarvis-env.sh"
    jarvis_load "$4"
    source "$SCRIPT_DIR/lib/overseer-launch.sh"
    DEP_ERR=/dev/stderr
    ol_entry_model "$1:$2:$3" || { printf 'jarvis-task: selection=model-unread\n%s\n' "$OL_CLASS_ERR" >&2; exit 1; }
    ol_model_line "$OL_ENTRY_WARNING"
    jq -cn --arg harness "$OL_ENTRY_HARNESS" --arg model "$OL_ENTRY_MODEL" --arg effort "$OL_ENTRY_EFFORT" \
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
    lane_run_detached /dev/null "$errors" "${launch[@]}" || exit 5
    launcher="$!" waited=0
    # A terminal that hands its window to a running server exits 0 at once,
    # so only a new client on the session proves the window opened.
    while (( waited < 50 )); do
      after="$(clients)" || exit 5
      for pid in $after; do
        [[ $'\n'"$before"$'\n' == *$'\n'"$pid"$'\n'* ]] || exit 0
      done
      if [[ -n "$launcher" ]]; then
        state="$(lane_process_state "$launcher")" || {
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
