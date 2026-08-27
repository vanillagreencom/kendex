#!/usr/bin/env bash
# Shared scaffolding for the harness-ci suites: a disposable git sandbox, the
# path to the script under test, and the two assertions every suite makes.
#
# Sourced, never run. It sets the strict mode it needs rather than trusting the
# sourcing suite to have set it, which is also what every suite here sets.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
HARNESS_ONLY="$(cd "$TEST_DIR/../scripts" && pwd)/harness-only"

PASS=0
FAIL=0

# Checked on the spot: a failed mktemp leaves the variable empty, and an empty
# SANDBOX would send the cleanup trap at the filesystem root.
SANDBOX="$(mktemp -d -t harness-ci-XXXXXX)" || SANDBOX=""
if [ -z "$SANDBOX" ] || [ ! -d "$SANDBOX" ]; then
  echo "harness-ci tests: could not create a sandbox directory" >&2
  exit 1
fi
cleanup() { rm -rf "$SANDBOX" 2>/dev/null || true; }
trap cleanup EXIT

# Fixture repositories carry their own identity and default branch so the
# suite reads the same on a runner with no global git config.
new_repo() { # NAME -> prints the repo path
  local repo="$SANDBOX/$1"
  mkdir -p "$repo"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.email harness-ci@example.invalid
  git -C "$repo" config user.name "harness-ci tests"
  printf '%s' "$repo"
}

# One commit per call: write every path, then record them together.
commit_paths() { # REPO MESSAGE PATH...
  local repo="$1" message="$2" path
  shift 2
  for path in "$@"; do
    mkdir -p "$repo/$(dirname "$path")"
    printf 'content for %s\n' "$path" >>"$repo/$path"
  done
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "$message"
}

# The verdict line alone. stderr is dropped here on purpose: these assertions
# are about what a caller reads from stdout.
classify() { # ARGS... -> the harness_only= line
  "$HARNESS_ONLY" "$@" 2>/dev/null
}

assert_eq() { # LABEL EXPECTED ACTUAL
  if [ "$2" = "$3" ]; then
    printf '  PASS: %s\n' "$1"
    PASS=$((PASS + 1))
  else
    printf '  FAIL: %s\n    expected: %s\n    actual:   %s\n' "$1" "$2" "$3" >&2
    FAIL=$((FAIL + 1))
  fi
}

assert_verdict() { # LABEL true|false ARGS...
  local label="$1" expected="$2"
  shift 2
  assert_eq "$label" "harness_only=$expected" "$(classify "$@")"
}

report() { # SUITE
  printf '%s: %d passed, %d failed\n' "$1" "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ]
}
