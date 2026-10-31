# shellcheck shell=bash
# Test runners share one process identity reader and bounded tree teardown.
# STOP_GRACE belongs to the caller.
source "$(dirname "${BASH_SOURCE[0]}")/../../scripts/lib/lane-state.sh" || return 1

# With SUITE_TRACE naming a file, each stop step appends one line to it, so a
# stop that failed can be read back step by step. Bash 3.2 has no
# EPOCHREALTIME and a clock read is a fork inside the stop being traced, so
# there the time is `-` and the file's append order alone orders the steps.
suite_trace() { # EVENT...
  [ -n "${SUITE_TRACE:-}" ] || return 0
  printf '%s %s\n' "${EPOCHREALTIME:--}" "$*" >>"$SUITE_TRACE" || true
}

# A live process's start time, which with its pid names that one process: a
# number freed by its exit and handed to a later process comes back with
# another start. Status 1 for a process that has ended, a zombie included, or
# whose state or start could not be read, so nothing signals it.
started_at() { # PID
  local state start
  state="$(lane_process_state "$1")" || return 1
  case "$state" in '' | Z) return 1 ;; esac
  start="$(lane_process_start "$1")" || return 1
  [ -n "$start" ] || return 1
  printf '%s\n' "$start"
}

# PID and every process under it, one `PID START` line each. Taken before any
# signal: a process whose parent the stop ends is no longer found under it. A
# process table that cannot be read leaves PID alone in it.
tree_of() { # PID
  local table hops pid start
  table="$(lane_process_table)" || table=""
  [ -n "$table" ] || suite_trace "tree root=$1 table=unread"
  while read -r hops pid; do
    [ -n "$pid" ] || continue
    if start="$(started_at "$pid")"; then
      printf '%s %s\n' "$pid" "$start"
      suite_trace "tree root=$1 hops=$hops pid=$pid start=$start"
    else
      suite_trace "tree root=$1 hops=$hops pid=$pid start=unread"
    fi
  done <<<"0 $1
$(lane_process_below "$table" "$1" '' 0 '' pids)"
  return 0
}

# The processes of TREE that are still the ones listed there, one pid a line.
tree_live() { # TREE
  local pid start
  while read -r pid start; do
    [ -n "$pid" ] && [ "$(started_at "$pid")" = "$start" ] && printf '%s\n' "$pid"
  done <<<"$1"
  return 0
}

signal_tree() { # SIGNAL TREE
  local pid live
  live="$(tree_live "$2")"
  # shellcheck disable=SC2086 # one word per live pid
  suite_trace "signal $1 live=[" $live "]"
  for pid in $live; do
    kill -"$1" "$pid" 2>/dev/null
    suite_trace "signal $1 pid=$pid rc=$?"
  done
  return 0
}

tree_running() { [ -n "$(tree_live "$1")" ]; } # TREE

# One bounded teardown for cancellation and overdue suites. Keep identities
# from before TERM: a parent that exits no longer leads to its descendants.
# SECONDS steps on the wall clock's whole seconds, so a bound of SECONDS +
# STOP_GRACE can fall due a moment after the TERM; counting from the next step
# gives the tree the whole grace.
stop_tree() { # TREE
  local until=$((SECONDS + 1 + STOP_GRACE))
  signal_tree TERM "$1"
  while tree_running "$1" && [ "$SECONDS" -lt "$until" ]; do sleep 0.1; done
  signal_tree KILL "$1"
}
