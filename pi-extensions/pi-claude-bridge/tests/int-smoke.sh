#!/usr/bin/env bash
# Smoke tests for pi-claude-bridge provider.
# Requires: pi CLI, Claude Code (for Agent SDK subprocess).

source "$(dirname "$0")/lib/bash-setup.sh"

test_notice test smoke-test

setup_test_env "smoke-test"

TIMEOUT=60
PASS=0
FAIL=0

trap cleanup_test_command EXIT

run() {
  local name="$1"; shift
  local expected="$1"; shift
  local slug
  slug=$(echo "$name" | tr ' :,' '-' | tr -cd '[:alnum:]-')
  local logfile="$LOGDIR/$slug.log"
  test_notice case "$name"
  local output
  if run_test_command "$TIMEOUT" "$@" > "$logfile" 2>&1; then
    output=$(cat -- "$logfile")
    if [[ "$output" =~ $expected ]]; then
      test_notice test_exit 0
      ((PASS+=1))
    else
      test_notice missing_output "$expected"
      test_notice log "$logfile"
      ((FAIL+=1))
    fi
  else
    local rc=$?
    test_notice command_exit "$rc"
    test_notice log "$logfile"
    ((FAIL+=1))
  fi
}

# --- Tests ---

run "provider: print mode responds" "^[Yy][Ee][Ss][.!]?$" \
  pi --no-session -ne -e "$DIR" \
  --model "pi-claude/claude-sonnet-5" \
  -p "Reply with just the word 'yes'"

run "provider: --provider flag works" "^[Yy][Ee][Ss][.!]?$" \
  pi --no-session -ne -e "$DIR" \
  --provider pi-claude \
  -p "Reply with just the word 'yes'"

run "provider: model list includes provider" "pi-claude" \
  pi --no-session -ne -e "$DIR" --list-models

# --- Summary ---

echo ""
test_notice passed "$PASS"
test_notice failed "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
