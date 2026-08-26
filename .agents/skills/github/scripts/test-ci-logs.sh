#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/commands/ci-logs.sh"

PASS=0

assert_eq() {
    local name="$1"
    local actual="$2"
    local expected="$3"

    if [ "$actual" = "$expected" ]; then
        PASS=$((PASS + 1))
        printf 'PASS: %s\n' "$name"
        return 0
    fi

    printf 'FAIL: %s\n' "$name" >&2
    printf 'expected: %s\n' "$expected" >&2
    printf 'actual:   %s\n' "$actual" >&2
    exit 1
}

assert_json_field() {
    local name="$1"
    local actual="$2"
    local check="$3"

    if echo "$actual" | jq -e "$check" >/dev/null; then
        PASS=$((PASS + 1))
        printf 'PASS: %s\n' "$name"
        return 0
    fi

    printf 'FAIL: %s\n' "$name" >&2
    printf '%s\n' "$actual" >&2
    exit 1
}

mixed_checks='[
  {
    "name": "Codecov",
    "state": "FAILURE",
    "bucket": "fail",
    "link": "https://codecov.io/gh/example/repo"
  },
  {
    "name": "Lint",
    "state": "FAILURE",
    "bucket": "fail",
    "link": "https://github.com/example/repo/actions/runs/123/jobs/456"
  }
]'

selected_actions_check=$(select_failed_actions_check "$mixed_checks")
assert_json_field \
    "select_failed_actions_check prefers GitHub Actions failures" \
    "$selected_actions_check" \
    '.name == "Lint" and .link == "https://github.com/example/repo/actions/runs/123/jobs/456"'

external_only_checks='[
  {
    "name": "Codecov",
    "state": "FAILURE",
    "bucket": "fail",
    "link": "https://codecov.io/gh/example/repo"
  }
]'

selected_external_only=$(select_failed_actions_check "$external_only_checks")
assert_eq \
    "select_failed_actions_check returns empty when no Actions failure exists" \
    "$selected_external_only" \
    ""

passing_checks='[
  {
    "name": "Lint",
    "state": "SUCCESS",
    "bucket": "pass",
    "link": "https://github.com/example/repo/actions/runs/1/jobs/2"
  }
]'

assert_eq \
    "count_failed_checks counts external and Actions failures" \
    "$(count_failed_checks "$mixed_checks")" \
    "2"

assert_eq \
    "count_failed_checks ignores passing checks" \
    "$(count_failed_checks "$passing_checks")" \
    "0"

printf 'PASS: %s assertions\n' "$PASS"
