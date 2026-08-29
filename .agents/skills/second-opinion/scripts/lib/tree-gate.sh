#!/usr/bin/env bash

second_opinion_tree_child() {
  local grace="$1" stderr_file="$2"
  shift 2
  local cli_pid="" cli_rc=0 cancel_rc=""
  cancel_cli() {
    cancel_rc="$1"
    [[ -z "$cli_pid" ]] || stop_process_group "$cli_pid" "$grace"
  }
  cleanup_cli() {
    [[ -z "$cli_pid" ]] || stop_process_group "$cli_pid" "$grace"
    [[ -z "$cli_pid" ]] || wait "$cli_pid" 2>/dev/null || true
  }
  trap cleanup_cli EXIT
  trap 'cancel_cli 143' TERM HUP
  trap 'cancel_cli 130' INT
  IFS= read -r release || { [[ -z "$cancel_rc" ]] || exit "$cancel_rc"; exit 1; }
  [[ "$release" == release ]] || exit 1
  [[ -z "$cancel_rc" ]] || exit "$cancel_rc"
  set -m
  "$@" <&8 2>"$stderr_file" &
  cli_pid=$!
  set +m
  exec 8<&-
  wait "$cli_pid" || cli_rc=$?
  stop_process_group "$cli_pid" "$grace"
  [[ -z "$cancel_rc" ]] || exit "$cancel_rc"
  exit "$cli_rc"
}
