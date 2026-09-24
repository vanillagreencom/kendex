#!/usr/bin/env bash
# The record a repeat-mode `oversee-watch` keeps of itself, beside the fleet
# state it watches, and the one way to stop it. Two scripts read it:
# `oversee-watch`, which refuses a second watch on one fleet state and adopts
# the one a succession restarted for its pane, and `oversee-succeed`, which
# stops the running watch and restarts it from the successor pane.
#
# Files, in the directory holding the fleet state:
#   oversee-watch.pid   `key=value` lines: pid (the repeat loop's own pid,
#                       never a launcher's), state (the fleet state path,
#                       resolved), pane (the $TMUX_PANE the watch serves, or
#                       none) and origin (hand, or succession for a watch
#                       `oversee-succeed` restarted)
#   oversee-watch.argv  NUL-separated: the watch script, the directory it ran
#                       in, then its arguments, so a restart runs the same
#                       command
#   oversee-watch.log   stdout of a watch a succession restarted, where no
#   oversee-watch.err   harness is reading it; stderr beside it. The watch that
#                       adopts it replays both
#
# A record is live only while its pid runs a process whose command line names
# oversee-watch: a pid read back off disk may by then belong to anything.
#
# Sourced, never executed.

# Seconds a stopped watch has to exit before the stop is reported failed. A
# watch whose foreground child is killed with it runs its TERM trap at once;
# the bound is for a host too loaded to schedule it.
WATCH_STOP_SECS=10

# The record's paths for fleet state STATE, and STATE itself resolved, so two
# spellings of one file name one record. Returns 1 where STATE's directory
# does not resolve.
watch_pid_paths() { # STATE
  local dir
  dir="$(cd -- "$(dirname -- "$1")" 2>/dev/null && pwd -P)" || return 1
  WATCH_STATE_CANON="$dir/$(basename -- "$1")"
  WATCH_PID_FILE="$dir/oversee-watch.pid"
  WATCH_ARGV_FILE="$dir/oversee-watch.argv"
  WATCH_LOG_FILE="$dir/oversee-watch.log"
  WATCH_ERR_FILE="$dir/oversee-watch.err"
}

# Whether a live watch holds the record for STATE, with its WATCH_PID,
# WATCH_PANE and WATCH_ORIGIN set. Returns 1 where there is no record, its
# state is another file, or its pid runs no oversee-watch.
watch_pid_live() { # STATE
  local line args
  WATCH_PID="" WATCH_PANE="" WATCH_ORIGIN=""
  watch_pid_paths "$1" || return 1
  [[ -f "$WATCH_PID_FILE" ]] || return 1
  local state=""
  while IFS= read -r line; do
    case "$line" in
      pid=*) WATCH_PID="${line#pid=}" ;;
      state=*) state="${line#state=}" ;;
      pane=*) WATCH_PANE="${line#pane=}" ;;
      origin=*) WATCH_ORIGIN="${line#origin=}" ;;
    esac
  done < "$WATCH_PID_FILE"
  [[ "$WATCH_PID" =~ ^[1-9][0-9]*$ && "$state" == "$WATCH_STATE_CANON" ]] || return 1
  kill -0 "$WATCH_PID" 2>/dev/null || return 1
  args="$(ps -o args= -p "$WATCH_PID" 2>/dev/null)" || return 1
  [[ "$args" == *oversee-watch* ]]
}

# Write the record for STATE as this process: its pid, PANE, ORIGIN, and the
# command SCRIPT ARGS... run from the current directory. Each file is written
# whole and renamed into place, so a reader never sees half of one.
watch_pid_write() { # STATE PANE ORIGIN SCRIPT ARGS...
  local state="$1" pane="$2" origin="$3"
  shift 3
  watch_pid_paths "$state" || return 1
  { printf '%s\0' "$1" "$PWD"; shift; [[ $# -eq 0 ]] || printf '%s\0' "$@"; } \
    > "$WATCH_ARGV_FILE.$$" && mv -f -- "$WATCH_ARGV_FILE.$$" "$WATCH_ARGV_FILE" || return 1
  printf 'pid=%s\nstate=%s\npane=%s\norigin=%s\n' "$$" "$WATCH_STATE_CANON" "$pane" "$origin" \
    > "$WATCH_PID_FILE.$$" && mv -f -- "$WATCH_PID_FILE.$$" "$WATCH_PID_FILE"
}

# Remove the record for STATE where it still names this process, so a watch
# that has already been replaced never removes its successor's.
watch_pid_release() { # STATE
  watch_pid_paths "$1" || return 0
  grep -qxF -- "pid=$$" "$WATCH_PID_FILE" 2>/dev/null || return 0
  rm -f -- "$WATCH_PID_FILE"
}

# The recorded command as WATCH_ARGV: script, directory, then arguments.
watch_argv_read() { # STATE
  local word
  WATCH_ARGV=()
  watch_pid_paths "$1" || return 1
  [[ -f "$WATCH_ARGV_FILE" ]] || return 1
  while IFS= read -r -d '' word; do WATCH_ARGV+=("$word"); done < "$WATCH_ARGV_FILE"
  [[ ${#WATCH_ARGV[@]} -ge 2 ]]
}

# Stop the watch at PID and wait for it to go. The loop's foreground child is
# signalled with it: bash runs a trap only once that child returns, and a pass
# can sleep for its whole interval. The pass's own children finish on their
# own; none of them writes anything a later watch reads. Returns 1 when PID is
# still running at the bound, which is read off the shell's own clock rather
# than counted in sleeps, so a sleep that returns early cannot shorten it.
watch_stop() { # PID
  local deadline=$((SECONDS + WATCH_STOP_SECS)) kids kid
  # Listed before the loop is signalled, while every child is still its own.
  kids="$(pgrep -P "$1" 2>/dev/null)" || kids=""
  kill -TERM "$1" 2>/dev/null || true
  for kid in $kids; do kill -TERM "$kid" 2>/dev/null || true; done
  while kill -0 "$1" 2>/dev/null; do
    (( SECONDS < deadline )) || return 1
    sleep 0.1
  done
}
