#!/usr/bin/env bash
# The aggregate accepts only successful dependencies and skips that a
# successful classifier authorized for the named jobs.
set -euo pipefail

unset GITHUB_OUTPUT
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGGREGATE="${AGGREGATE_NEEDS_UNDER_TEST:-$(cd "$TEST_DIR/../scripts" && pwd)/aggregate-needs}"
PASS=0
FAIL=0

SANDBOX="$(mktemp -d -t harness-ci-aggregate-XXXXXX)" || SANDBOX=""
if [ -z "$SANDBOX" ] || [ ! -d "$SANDBOX" ]; then
  echo "aggregate-needs tests: could not create a sandbox directory" >&2
  exit 1
fi
cleanup() { rm -rf "$SANDBOX" 2>/dev/null || true; }
trap cleanup EXIT

assert_eq() { # LABEL EXPECTED ACTUAL
  if [ "$2" = "$3" ]; then
    printf '  PASS: %s\n' "$1"
    PASS=$((PASS + 1))
  else
    printf '  FAIL: %s\n    expected: %s\n    actual:   %s\n' "$1" "$2" "$3" >&2
    FAIL=$((FAIL + 1))
  fi
}

run_case() { # LABEL EXPECTED_STATUS WAIVER RESULTS SKIPPABLE...
  local label="$1" expected="$2" waiver="$3" results="$4" out status
  shift 4
  set -- --results "$results" --classifier changes --waiver "$waiver" "$@"
  if out="$(env -i PATH="$PATH" "$AGGREGATE" "$@" 2>&1)"; then
    status=0
  else
    status=$?
  fi
  case "$status" in
    0) record="exit=0 aggregate-needs: accepted" ;;
    1) record="exit=1 $(printf '%s\n' "$out" | sed -n '1p')" ;;
    *) record="exit=$status $(printf '%s\n' "$out" | sed -n '1p')" ;;
  esac
  assert_eq "$label" "$expected" "$record"
}

all_success='{"changes":{"result":"success"},"test":{"result":"success"},"build":{"result":"success"}}'
one_skipped='{"changes":{"result":"success"},"test":{"result":"skipped"},"build":{"result":"success"}}'
two_skipped='{"changes":{"result":"success"},"test":{"result":"skipped"},"build":{"result":"skipped"}}'
failed='{"changes":{"result":"success"},"test":{"result":"failure"},"build":{"result":"success"}}'
cancelled='{"changes":{"result":"success"},"test":{"result":"cancelled"},"build":{"result":"success"}}'
classifier_failed='{"changes":{"result":"failure"},"test":{"result":"success"},"build":{"result":"success"}}'
classifier_missing='{"test":{"result":"success"},"build":{"result":"success"}}'

run_case all-success "exit=0 aggregate-needs: accepted" false "$all_success" \
  --skippable test --skippable build
run_case authorized-skip "exit=0 aggregate-needs: accepted" true "$one_skipped" \
  --skippable test
run_case authorized-skips "exit=0 aggregate-needs: accepted" true "$two_skipped" \
  --skippable test --skippable build
run_case waiver-false "exit=1 aggregate-needs: rejected classifier=changes waiver=false" \
  false "$one_skipped" --skippable test
run_case job-not-skippable "exit=1 aggregate-needs: rejected classifier=changes waiver=true" \
  true "$one_skipped" --skippable build
run_case failed-job "exit=1 aggregate-needs: rejected classifier=changes waiver=true" \
  true "$failed" --skippable test
run_case cancelled-job "exit=1 aggregate-needs: rejected classifier=changes waiver=true" \
  true "$cancelled" --skippable test
run_case classifier-failed "exit=1 aggregate-needs: rejected classifier=changes waiver=true" \
  true "$classifier_failed" --skippable test
run_case classifier-missing "exit=1 aggregate-needs: rejected classifier=changes waiver=true" \
  true "$classifier_missing" --skippable test
run_case invalid-json "exit=2 aggregate-needs: invalid-results=json" \
  true '{' --skippable test
run_case empty-object "exit=2 aggregate-needs: invalid-results=json" \
  true '{}' --skippable test

if [ -z "${AGGREGATE_NEEDS_CONTROL:-}" ]; then
  [ ! -L "$AGGREGATE" ] || { echo "the aggregate control refuses a symlink" >&2; exit 1; }
  mutant="$SANDBOX/aggregate-needs-mutant"
  if ! awk '
    BEGIN { changed = 0 }
    /      \(\$waiver == "true" and$/ {
      print "      (true and"
      changed += 1
      next
    }
    { print }
    END { if (changed != 1) exit 2 }
  ' "$AGGREGATE" >"$mutant"; then
    echo "could not build the aggregate must-fail control" >&2
    exit 1
  fi
  cmp -s "$AGGREGATE" "$mutant" && {
    echo "the aggregate must-fail control changed no source" >&2
    exit 1
  }
  chmod +x "$mutant"
  control_status=0
  if AGGREGATE_NEEDS_CONTROL=1 AGGREGATE_NEEDS_UNDER_TEST="$mutant" \
    bash "$TEST_DIR/aggregate-needs.test.sh" >"$SANDBOX/control.stdout" \
    2>"$SANDBOX/control.stderr"; then
    control_status=0
  else
    control_status=$?
  fi
  assert_eq "the waiver mutant turns the aggregate suite red" 1 "$control_status"
fi

printf 'aggregate-needs: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
