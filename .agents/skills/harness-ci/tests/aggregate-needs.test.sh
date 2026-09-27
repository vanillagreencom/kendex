#!/usr/bin/env bash
# The aggregate accepts only successful dependencies and skips that a
# successful classifier authorized for the named jobs: through its one waiver
# for a --skippable job, or through the lane's own verdict, read out of the
# results, for a --lane job.
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
  local label="$1" expected="$2" waiver="$3" results="$4"
  shift 4
  run_args "$label" "$expected" --results "$results" --classifier changes \
    --waiver "$waiver" "$@"
}

run_args() { # LABEL EXPECTED_STATUS ARGS...
  local label="$1" expected="$2" out status record
  shift 2
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

# The lane verdicts are the classifier job's own outputs, as toJSON(needs)
# carries them. A lane stands a job down only where its verdict is false.
lanes_needs() { # TEST_VERDICT BUILD_VERDICT TEST_RESULT BUILD_RESULT [EXTRA_OUTPUTS]
  jq -cn --arg t "$1" --arg b "$2" --arg tr "$3" --arg br "$4" --argjson extra "${5:-{\}}" '
    {changes: {result: "success", outputs: ({lane_test: $t, lane_build: $b} + $extra)},
     test: {result: $tr}, build: {result: $br}}'
}
run_args lane-false-skip "exit=0 aggregate-needs: accepted" \
  --results "$(lanes_needs false true skipped success)" --classifier changes \
  --lane test=test --lane build=build
run_args lane-true-skip "exit=1 aggregate-needs: rejected classifier=changes waiver=" \
  --results "$(lanes_needs true true skipped success)" --classifier changes \
  --lane test=test --lane build=build
run_args lane-verdict-absent "exit=1 aggregate-needs: rejected classifier=changes waiver=" \
  --results '{"changes":{"result":"success","outputs":{}},"test":{"result":"skipped"}}' \
  --classifier changes --lane test=test
run_args lane-of-another-job "exit=1 aggregate-needs: rejected classifier=changes waiver=" \
  --results "$(lanes_needs true false skipped success)" --classifier changes \
  --lane test=test --lane build=build
run_args lane-named-for-another-lane "exit=0 aggregate-needs: accepted" \
  --results "$(lanes_needs true false skipped success)" --classifier changes \
  --lane test=build
run_args job-in-no-lane "exit=1 aggregate-needs: rejected classifier=changes waiver=" \
  --results "$(lanes_needs false false success skipped '{"lane_null":"false"}')" \
  --classifier changes --lane test=test
run_args lane-beside-waiver "exit=0 aggregate-needs: accepted" \
  --results "$(lanes_needs false true skipped skipped)" --classifier changes \
  --waiver true --skippable build --lane test=test
run_args lane-classifier-failed "exit=1 aggregate-needs: rejected classifier=changes waiver=" \
  --results '{"changes":{"result":"failure","outputs":{"lane_test":"false"}},"test":{"result":"skipped"}}' \
  --classifier changes --lane test=test
run_args lane-malformed "exit=2 aggregate-needs: invalid-arguments=invalid-lane value=test" \
  --results "$(lanes_needs false false skipped success)" --classifier changes --lane test
run_args skippable-without-waiver "exit=2 aggregate-needs: invalid-arguments=missing option=--waiver" \
  --results "$all_success" --classifier changes --skippable test
run_args nothing-skippable "exit=2 aggregate-needs: invalid-arguments=missing option=--skippable" \
  --results "$all_success" --classifier changes

if [ -z "${AGGREGATE_NEEDS_CONTROL:-}" ]; then
  [ ! -L "$AGGREGATE" ] || { echo "the aggregate control refuses a symlink" >&2; exit 1; }
  build_mutant() { # RULE OUTPUT
    awk -v rule="$1" '
      BEGIN { changed = 0 }
      rule == "classifier" && index($0, ".[$classifier].result == \"success\" and") {
        print "    true and"
        changed += 1
        next
      }
      rule == "dependency" && index($0, "$entry.value.result == \"success\" or") {
        print "      true or"
        changed += 1
        next
      }
      rule == "waiver" && index($0, "($waiver == \"true\" and") {
        print "      (true and"
        changed += 1
        next
      }
      rule == "membership" && index($0, "($skippable | split(\"\\n\") | index($entry.key)) != null) or") {
        print "       true) or"
        changed += 1
        next
      }
      rule == "lane" && index($0, "$verdicts.outputs[\"lane_\\($lane_of[$entry.key])\"] == \"false\")") {
        print "         true)"
        changed += 1
        next
      }
      rule == "lane-membership" && index($0, "($lane_of[$entry.key] != null and") {
        print "        (true and"
        changed += 1
        next
      }
      { print }
      END { if (changed != 1) exit 2 }
    ' "$AGGREGATE" >"$2"
  }

  run_mutant_control() { # RULE LABEL
    local rule="$1" label="$2" mutant control_status
    mutant="$SANDBOX/aggregate-needs-$rule-mutant"
    if ! build_mutant "$rule" "$mutant"; then
      echo "could not build the $rule aggregate control" >&2
      exit 1
    fi
    cmp -s "$AGGREGATE" "$mutant" && {
      echo "the $rule aggregate control changed no source" >&2
      exit 1
    }
    if ! bash -n "$mutant"; then
      echo "the $rule aggregate control does not compile" >&2
      exit 1
    fi
    chmod +x "$mutant"
    control_status=0
    if AGGREGATE_NEEDS_CONTROL=1 AGGREGATE_NEEDS_UNDER_TEST="$mutant" \
      bash "$TEST_DIR/aggregate-needs.test.sh" \
      >"$SANDBOX/$rule-control.stdout" 2>"$SANDBOX/$rule-control.stderr"; then
      control_status=0
    else
      control_status=$?
    fi
    assert_eq "$label" 1 "$control_status"
  }

  run_mutant_control classifier \
    "the classifier-success mutant turns the aggregate suite red"
  run_mutant_control dependency \
    "the dependency-success mutant turns the aggregate suite red"
  run_mutant_control waiver \
    "the waiver mutant turns the aggregate suite red"
  run_mutant_control membership \
    "the skippable-membership mutant turns the aggregate suite red"
  run_mutant_control lane \
    "the lane-verdict mutant turns the aggregate suite red"
  run_mutant_control lane-membership \
    "the lane-membership mutant turns the aggregate suite red"
fi

printf 'aggregate-needs: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
