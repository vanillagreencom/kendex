#!/usr/bin/env bash
# Shared setup functions for bash-based integration tests.
# Source this file at the start of test scripts.

set -euo pipefail

# Strip node_modules/.bin from PATH so we use the system pi, not the vendored one.
__clean_path() {
	echo "$PATH" | tr ':' '\n' | grep -v node_modules | tr '\n' ':'
}

# Setup standard test environment.
# Usage: setup_test_env "test-name"
# Sets: DIR, LOGDIR, LOGFILE (if specified), DEBUG_LOG, and exports CLAUDE_BRIDGE_DEBUG
setup_test_env() {
	local name="$1"
	local log_suffix="${2:-.log}"  # optional: suffix for logfile, or "none" for no logfile

	DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
	LOGDIR="$DIR/.test-output"
	mkdir -p "$LOGDIR"

	export CLAUDE_BRIDGE_DEBUG=1
	DEBUG_LOG="$LOGDIR/${name}-debug.log"
	export CLAUDE_BRIDGE_DEBUG_PATH="$DEBUG_LOG"

	if [[ "$log_suffix" != "none" ]]; then
		LOGFILE="$LOGDIR/${name}${log_suffix}"
	else
		LOGFILE=""
	fi

	# Clean PATH
	PATH=$(__clean_path)

	# Export for use in tests
	export DIR LOGDIR DEBUG_LOG LOGFILE PATH
}

# GNU timeout owns each command's process group. The calling script owns its PID.
TEST_COMMAND_PID=""
run_test_command() {
	timeout "$@" &
	TEST_COMMAND_PID=$!
	local status=0
	wait "$TEST_COMMAND_PID" || status=$?
	TEST_COMMAND_PID=""
	return "$status"
}

cleanup_test_command() {
	if [[ -n "$TEST_COMMAND_PID" ]]; then
		kill -- "-$TEST_COMMAND_PID" 2>/dev/null || true
		wait "$TEST_COMMAND_PID" 2>/dev/null || true
		TEST_COMMAND_PID=""
	fi
}

# Output contract: the first line is key=value; explanation follows.
test_notice() {
	printf '%s=%s\n' "$1" "$2"
	if [[ -n "${3:-}" ]]; then printf '%s\n' "$3"; fi
}

# Check for required commands or exit with error.
# Usage: require_command cmd1 cmd2 ...
require_command() {
	local cmd
	for cmd in "$@"; do
		if ! command -v "$cmd" >/dev/null 2>&1; then
			test_notice missing_command "$cmd" "Install the required command." >&2
			exit 1
		fi
	done
}
