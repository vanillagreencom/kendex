#!/usr/bin/env bash
# vstack#271: Linear activity emission is best-effort. If the shared
# Flightdeck activity helper cannot be loaded after a successful wrapper
# operation, emit only a clear non-blocking warning and never leak raw shell
# diagnostics such as `source: ...` or `flightdeck_activity_emit: command not found`.
#
# Run: bash skills/linear/tests/activity-emit-failure.test.sh
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
WRAPPER="$REPO_ROOT/skills/linear/scripts/_activity-emit.sh"

SANDBOX="$(mktemp -d -t linear-activity-emit-XXXXXX)"
PASS=0
FAIL=0

cleanup() { rm -rf "$SANDBOX" 2>/dev/null || true; }
trap cleanup EXIT

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        printf '  PASS: %s\n' "$label"
        PASS=$((PASS + 1))
    else
        printf '  FAIL: %s\n    expected: %s\n    actual:   %s\n' "$label" "$expected" "$actual" >&2
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        printf '  PASS: %s\n' "$label"
        PASS=$((PASS + 1))
    else
        printf '  FAIL: %s\n    missing: %s\n    actual:  %s\n' "$label" "$needle" "$haystack" >&2
        FAIL=$((FAIL + 1))
    fi
}

assert_not_contains() {
    local label="$1" needle="$2" haystack="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        printf '  PASS: %s\n' "$label"
        PASS=$((PASS + 1))
    else
        printf '  FAIL: %s\n    unexpected: %s\n    actual:     %s\n' "$label" "$needle" "$haystack" >&2
        FAIL=$((FAIL + 1))
    fi
}

# Copy the Linear trampoline into a sandbox without the sibling Flightdeck
# helper. The relative source path will fail exactly like an unavailable or
# unreadable Flightdeck install, without mutating the real repository files.
mkdir -p "$SANDBOX/linear/scripts"
cp "$WRAPPER" "$SANDBOX/linear/scripts/_activity-emit.sh"
SANDBOX_WRAPPER="$SANDBOX/linear/scripts/_activity-emit.sh"

# Managed context: failure to load the Flightdeck helper returns success and
# prints one actionable warning, not bash source/function diagnostics.
export FLIGHTDECK_MANAGED=1
export FLIGHTDECK_ACTIVITY_FILE="$SANDBOX/activity.jsonl"
managed_stdout="$SANDBOX/managed.stdout"
managed_stderr="$SANDBOX/managed.stderr"
managed_status=0
bash "$SANDBOX_WRAPPER" linear.issue_updated --summary "Issue updated" >"$managed_stdout" 2>"$managed_stderr" || managed_status=$?
managed_err="$(cat "$managed_stderr")"
assert_eq "managed helper-load failure exits 0" "0" "$managed_status"
assert_eq "managed helper-load failure has no stdout" "" "$(cat "$managed_stdout")"
assert_contains "managed helper-load failure warns clearly" "Warning: Flightdeck activity emit unavailable; continuing without activity:" "$managed_err"
assert_not_contains "managed helper-load failure hides shell source error" "No such file or directory" "$managed_err"
assert_not_contains "managed helper-load failure hides missing function error" "command not found" "$managed_err"
assert_not_contains "managed helper-load failure hides raw script line diagnostics" "line " "$managed_err"

# Unmanaged context: Linear wrapper usage should remain silent and should not
# attempt to load Flightdeck at all.
unset FLIGHTDECK_MANAGED FLIGHTDECK_ACTIVITY_FILE
unmanaged_stdout="$SANDBOX/unmanaged.stdout"
unmanaged_stderr="$SANDBOX/unmanaged.stderr"
unmanaged_status=0
bash "$SANDBOX_WRAPPER" linear.issue_updated --summary "Issue updated" >"$unmanaged_stdout" 2>"$unmanaged_stderr" || unmanaged_status=$?
assert_eq "unmanaged helper-load failure exits 0" "0" "$unmanaged_status"
assert_eq "unmanaged helper-load failure has no stdout" "" "$(cat "$unmanaged_stdout")"
assert_eq "unmanaged helper-load failure has no stderr" "" "$(cat "$unmanaged_stderr")"

printf '\nPASS=%d FAIL=%d\n' "$PASS" "$FAIL"
if [ "$FAIL" -ne 0 ]; then exit 1; fi