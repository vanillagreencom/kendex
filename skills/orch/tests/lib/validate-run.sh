#!/usr/bin/env bash
# A dev-validate-run run directory as dev-return-write reads it: the start
# record's validate-mode= line, the one field a receipt takes from the run.
# Sourced by the suites that write receipts; dev_validate_run.sh pins the
# record a real run writes.

validate_run_dir() { # DIR MODE — create DIR with a start record naming MODE; print DIR
  mkdir -p "$1"
  printf 'validate-mode=%s\n' "$2" > "$1/start"
  printf '%s\n' "$1"
}
