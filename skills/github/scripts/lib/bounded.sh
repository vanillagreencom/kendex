#!/usr/bin/env bash
# Portable wall-clock bound for GitHub helper subprocesses.

_KENDEX_BOUNDED_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=group-leader.sh
source "$_KENDEX_BOUNDED_LIB_DIR/group-leader.sh"
unset _KENDEX_BOUNDED_LIB_DIR

_kendex_github_restore_trap() {
  local signal="$1" saved="$2"
  if [ -n "$saved" ]; then
    eval "$saved"
  else
    trap - "$signal"
  fi
}

_kendex_github_bounded_group_members() {
  local group="$1" leader="$2"
  ps -eo pid=,pgid= 2>/dev/null | awk -v group="$group" -v leader="$leader" '
    $2 == group && $1 != leader { print $1 }
  '
}

# Wait out the leader, then KILL what is left and reap it. TARGET is the group
# when the child has one and the bare pid when it is still inside the fork
# window group-leader.sh describes.
_kendex_github_reap_bounded_leader() { # PID TARGET
  local pid="$1" target="$2" grace=0
  while kill -0 "$pid" 2>/dev/null && [ "$grace" -lt 10 ]; do
    sleep 0.1
    grace=$((grace + 1))
  done
  kill -KILL -- "$target" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

# Stop a child THIS FRAME forked, grouped yet or not. Called with the pid alone:
# the group is asked for here, where the signal is sent, and never cached at the
# fork. A probe run where `$!` is assigned can land inside the fork window and
# find no group, and a target pinned there would leave the command's own
# children alive when the bound expires. By the time a stop is wanted the child
# has long since grouped; one still inside that window is this frame's own
# bash-then-perl, with no children of its own, which a single signal at the pid
# ends — and the group sweep below still covers a group that appeared meanwhile.
_kendex_github_stop_bounded_group() { # SIGNAL PID
  local signal="$1" pid="$2" grace=0 members="" member scan_failed=0
  [ -n "$pid" ] || return 0

  if ! kill -0 -- "-$pid" 2>/dev/null; then
    kill -0 "$pid" 2>/dev/null || return 0
    kill -s "$signal" "$pid" 2>/dev/null || true
    if ! kill -0 -- "-$pid" 2>/dev/null; then
      _kendex_github_reap_bounded_leader "$pid" "$pid"
      return 0
    fi
  fi

  while [ "$grace" -lt 10 ]; do
    if ! members="$(_kendex_github_bounded_group_members "$pid" "$pid")"; then
      scan_failed=1
      break
    fi
    [ -n "$members" ] || break
    while IFS= read -r member; do
      [ -z "$member" ] || kill -s "$signal" "$member" 2>/dev/null || true
    done <<<"$members"
    sleep 0.1
    grace=$((grace + 1))
  done

  if [ "$scan_failed" -eq 1 ]; then
    kill -s "$signal" -- "-$pid" 2>/dev/null || true
  else
    kill -s "$signal" "$pid" 2>/dev/null || true
  fi

  _kendex_github_reap_bounded_leader "$pid" "-$pid"
}

_kendex_github_forward_bounded_signal() {
  local signal="$1" pid="$2" old_hup="$3" old_int="$4" old_term="$5"
  trap - HUP INT TERM
  _kendex_github_stop_bounded_group "$signal" "$pid"
  _kendex_github_restore_trap HUP "$old_hup"
  _kendex_github_restore_trap INT "$old_int"
  _kendex_github_restore_trap TERM "$old_term"
  kill -s "$signal" "$$" 2>/dev/null || true
  case "$signal" in HUP) return 129 ;; INT) return 130 ;; TERM) return 143 ;; esac
}

# The one reading of the bound grammar. The bound is polled on a 0.1s tick
# below, so it is read to one decimal place and no finer: a figure the poll
# could not honour is junk, not a tighter bound. A leading zero is decimal,
# never octal.
#
# Separate from the runner because a caller has to be able to tell a bound it
# cannot read from a command that failed, and it may not ask by running the
# command: 125 arrives after the command did not run, so there is no output to
# explain it. Asking here keeps one judge of the grammar.
kendex_github_bound_ticks() { # SECONDS — tenths on stdout; 1 when unreadable
  local seconds="$1" whole frac
  case "$seconds" in
    *.*) whole="${seconds%.*}" frac="${seconds#*.}" ;;
    *) whole="$seconds" frac=0 ;;
  esac
  case "$whole" in '' | *[!0-9]*) return 1 ;; esac
  # Ten times an 18-digit whole part is past what signed 64-bit shell
  # arithmetic holds, and the wrap lands on 0 for one such value in ten, which
  # the runner below reads as "no bound" and then waits on forever. Refused on
  # width here, before the multiply, so no call site inherits the wrap.
  [ "${#whole}" -le 17 ] || return 1
  case "$frac" in [0-9]) ;; *) return 1 ;; esac
  printf '%s' "$(((10#$whole) * 10 + frac))"
}

kendex_github_run_bounded() {
  local seconds="$1"
  shift

  local pid="" ticks=0 max_ticks status=0
  if ! max_ticks="$(kendex_github_bound_ticks "$seconds")"; then
    # 125 arrives having run nothing, so there is no output to explain it and
    # most callers can only pass it upward — an auth check that never ran, a
    # token that never resolved, and no name for the setting behind either.
    # Said once, here, where the grammar is read: no call site can go quiet
    # again by forgetting to say it.
    printf "bounded: '%s' is not a number of seconds to one decimal place; nothing ran\n" \
      "$seconds" >&2
    return 125
  fi
  if [ "$max_ticks" -eq 0 ]; then
    "$@"
    return
  fi

  local old_hup old_int old_term
  old_hup="$(trap -p HUP)"
  old_int="$(trap -p INT)"
  old_term="$(trap -p TERM)"
  trap '_kendex_github_forward_bounded_signal HUP "$pid" "$old_hup" "$old_int" "$old_term"' HUP
  trap '_kendex_github_forward_bounded_signal INT "$pid" "$old_hup" "$old_int" "$old_term"' INT
  trap '_kendex_github_forward_bounded_signal TERM "$pid" "$old_hup" "$old_int" "$old_term"' TERM

  # The child takes its own group, and `<&0` hands it the caller's stdin: both
  # are what job control used to supply here, and the parent-side setpgid it
  # also brought printed onto this stderr whenever it lost the race with the
  # child. group-leader.sh holds the whole of that reasoning.
  "${KENDEX_GROUP_LEADER[@]}" "$@" <&0 &
  pid=$!

  while kill -0 "$pid" 2>/dev/null; do
    if [ "$ticks" -ge "$max_ticks" ]; then
      _kendex_github_stop_bounded_group TERM "$pid"
      _kendex_github_restore_trap HUP "$old_hup"
      _kendex_github_restore_trap INT "$old_int"
      _kendex_github_restore_trap TERM "$old_term"
      return 124
    fi
    sleep 0.1
    ticks=$((ticks + 1))
  done

  wait "$pid" || status=$?
  _kendex_github_restore_trap HUP "$old_hup"
  _kendex_github_restore_trap INT "$old_int"
  _kendex_github_restore_trap TERM "$old_term"
  return "$status"
}

kendex_github_run_bounded_capture() {
  local seconds="$1" stdout_file="$2" stderr_file="$3"
  shift 3
  kendex_github_run_bounded "$seconds" "$@" >"$stdout_file" 2>"$stderr_file"
}
