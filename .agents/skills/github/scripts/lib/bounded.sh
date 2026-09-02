#!/usr/bin/env bash
# Portable wall-clock bound for GitHub helper subprocesses.

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

_kendex_github_stop_bounded_group() {
  local signal="$1" target="$2" pid="$3" grace=0 group="" members="" member scan_failed=0
  [ -n "$target" ] || return 0

  case "$target" in -*) group="${target#-}" ;; esac
  if [ -n "$group" ]; then
    while [ "$grace" -lt 10 ]; do
      if ! members="$(_kendex_github_bounded_group_members "$group" "$pid")"; then
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
  fi

  if [ "$scan_failed" -eq 1 ]; then
    kill -s "$signal" -- "$target" 2>/dev/null || true
  elif [ -n "$pid" ]; then
    kill -s "$signal" "$pid" 2>/dev/null || true
  fi

  grace=0
  while [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && [ "$grace" -lt 10 ]; do
    sleep 0.1
    grace=$((grace + 1))
  done
  kill -KILL -- "$target" 2>/dev/null || true
  [ -z "$pid" ] || wait "$pid" 2>/dev/null || true
}

_kendex_github_forward_bounded_signal() {
  local signal="$1" target="$2" pid="$3" old_hup="$4" old_int="$5" old_term="$6"
  trap - HUP INT TERM
  _kendex_github_stop_bounded_group "$signal" "$target" "$pid"
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

  local restore_monitor=0 pid="" ticks=0 max_ticks status=0 target=""
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
  trap '_kendex_github_forward_bounded_signal HUP "$target" "$pid" "$old_hup" "$old_int" "$old_term"' HUP
  trap '_kendex_github_forward_bounded_signal INT "$target" "$pid" "$old_hup" "$old_int" "$old_term"' INT
  trap '_kendex_github_forward_bounded_signal TERM "$target" "$pid" "$old_hup" "$old_int" "$old_term"' TERM
  case "$-" in
    *m*) ;;
    *) set -m; restore_monitor=1 ;;
  esac

  "$@" &
  pid=$!
  [ "$restore_monitor" -eq 0 ] || set +m
  target="-$pid"
  if ! kill -0 -- "$target" 2>/dev/null; then
    target="$pid"
  fi

  while kill -0 "$pid" 2>/dev/null; do
    if [ "$ticks" -ge "$max_ticks" ]; then
      _kendex_github_stop_bounded_group TERM "$target" "$pid"
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
