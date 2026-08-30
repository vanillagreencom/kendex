#!/usr/bin/env bash
# Portable wall-clock bound for GitHub helper subprocesses.

kendex_github_run_bounded() {
  local seconds="$1"
  shift

  case "$seconds" in
    0) "$@"; return ;;
    ''|*[!0-9]*) return 125 ;;
  esac

  local restore_monitor=0 pid ticks=0 max_ticks status=0 grace=0 target
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
  max_ticks=$((seconds * 10))

  while kill -0 "$pid" 2>/dev/null; do
    if [ "$ticks" -ge "$max_ticks" ]; then
      kill -TERM -- "$target" 2>/dev/null || true
      while kill -0 -- "$target" 2>/dev/null && [ "$grace" -lt 10 ]; do
        sleep 0.1
        grace=$((grace + 1))
      done
      kill -KILL -- "$target" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    sleep 0.1
    ticks=$((ticks + 1))
  done

  wait "$pid" || status=$?
  return "$status"
}

kendex_github_run_bounded_capture() {
  local seconds="$1" stdout_file="$2" stderr_file="$3"
  shift 3
  kendex_github_run_bounded "$seconds" "$@" >"$stdout_file" 2>"$stderr_file"
}
