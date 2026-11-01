#!/usr/bin/env bash
# Process identity: whether the process a PID and a start name is still the
# one running, and the process table a caller walks to find one.
#
# A start names one process for as long as its host stays up. Where /proc
# exists (Linux) it is field 22 of /proc/PID/stat, the start in clock ticks
# since boot: procps derives `ps -o lstart` from it and the boot time, which
# an NTP step, a VM resync after host sleep or a manual date change moves for
# every live process, while the tick count stays put. Where there is no /proc
# (macOS) it is `ps -o lstart=`, which the kernel fixes at fork, in the C
# locale and UTC. Either is one blank-free token, so a record can carry it as
# one field.
#
# A zombie has ended: it holds its PID only until its parent reaps it.
#
# Sourced, never run. Bash 3.2-safe.

# `STATE START` for a PID, STATE the one-letter process state, or an empty
# line for a PID with no process. Status 2 is a read that gave no answer.
#
# A PID has no process only on positive evidence: no /proc entry, or ps
# exiting 1 with nothing on stdout or stderr. BSD and macOS ps also exit 1
# with an empty stdout when ps itself fails, writing a diagnostic, so every
# other reading has status 2.
process_stat() { # PID
  local stat='' rest rc=0 start
  local out err nl=$'\n'
  local -a fields=()
  if [[ -d /proc/self ]]; then
    if ! { IFS= read -r stat <"/proc/$1/stat"; } 2>/dev/null; then
      [[ ! -e "/proc/$1" ]] || return 2
      printf '\n'
      return 0
    fi
    # The command name may hold blanks and `)`, so the fields start after
    # the last closing parenthesis: state is field 3 and the start field 22.
    rest="${stat##*) }"
    read -r -a fields <<<"$rest"
    [[ -n "${fields[0]:-}" && "${fields[19]:-}" =~ ^[0-9]+$ ]] || return 2
    printf '%s %s\n' "${fields[0]}" "${fields[19]}"
    return 0
  fi
  # One ps call answers on both streams: its stderr fills the outer capture,
  # and its status and blank-free stdout close it as one last line.
  out="$( { stat="$(LC_ALL=C ps -o stat= -p "$1")" || rc=$?; } 2>&1
    printf '\n%s %s' "$rc" "${stat//[[:space:]]/}" )"
  err=${out%"$nl"*}
  out=${out##*"$nl"}
  rc=${out%% *}
  stat=${out#* }
  if [[ "$rc" -ne 0 ]]; then
    [[ "$rc" -eq 1 && -z "$stat" && -z "$err" ]] || return 2
    printf '\n'
    return 0
  fi
  [[ -n "$stat" ]] || return 2
  rc=0
  start="$(LC_ALL=C TZ=UTC ps -o lstart= -p "$1" 2>/dev/null)" || rc=$?
  [[ "$rc" -eq 0 ]] || return 2
  start="$(awk '{ $1 = $1; gsub(/ /, "_"); print }' <<<"$start")" || return 2
  [[ -n "$start" ]] || return 2
  printf '%s %s\n' "${stat:0:1}" "$start"
}

# A process's start token, or an empty line for a PID with no process.
# Status 2 is a read that gave no answer.
process_start() { # PID
  local now
  now="$(process_stat "$1")" || return 2
  printf '%s\n' "${now#* }"
}

# `live` while PID still runs with START, `ended` when it has no process, is
# a zombie or started at another time. Status 2 is a read that gave no
# answer, which is neither.
process_identity_status() { # PID START
  local now
  now="$(process_stat "$1")" || return 2
  if [[ -z "$now" || "${now%% *}" == Z ]]; then
    printf 'ended\n'
  elif [[ "${now#* }" == "$2" ]]; then
    printf 'live\n'
  else
    printf 'ended\n'
  fi
}

# The host's processes as `PID PPID NAME` rows, the name with any directory
# stripped: macOS `ps` prints an executable's path where Linux prints its
# bare name. Status 1 is a table that could not be read.
process_table() {
  local raw
  raw="$(LC_ALL=C ps -A -o pid= -o ppid= -o comm= 2>/dev/null)" || return 1
  awk '{ pid = $1; ppid = $2; $1 = ""; $2 = ""; name = substr($0, 3); sub(/.*\//, "", name); print pid, ppid, name }' <<<"$raw"
}

# Each process's argv[0] as `PID NAME` rows, its directory and a login
# shell's leading `-` stripped. On Linux a script started through a `#!`
# line carries the script's name in the table above and the interpreter's
# here. Status 1 is a table that could not be read.
process_argv0_table() {
  local raw
  raw="$(LC_ALL=C ps -A -o pid= -o args= 2>/dev/null)" || return 1
  awk '{ name = $2; sub(/.*\//, "", name); sub(/^-/, "", name); print $1, name }' <<<"$raw"
}
