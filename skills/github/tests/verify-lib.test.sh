#!/usr/bin/env bash
# verify-lib's run_stack under live errexit: a failing build or test command
# is recorded with its summary and raises its issue whatever its output is
# (larger than a pipe buffer, one line past MAX_ARG_STRLEN, or matching no
# summary pattern), and a passing one is recorded as such.
#
# Both failure branches once built their summary as
# `echo "$output" | grep -E ... | head -5 | tr`: head closed the pipe on its
# fifth line, SIGPIPEd grep, and pipefail made 141 the status of an unguarded
# assignment, so under errexit the branch died before recording anything.
# Each row runs run_stack with errexit LIVE and reads RESULTS_JSON out of an
# EXIT trap, which is what the summary must survive.
#
# A row is `label|command|stage|build|test|issues`:
#   command  a fixture (see command_of): `large` two thousand matching error
#            lines, `long-line` one matching line past MAX_ARG_STRLEN,
#            `quiet` a failure matching no pattern, `pass` success
#   stage    where the stack spec runs it: `build`, `test`, or `both`
#   build    `.builds.rust`: `-` when never recorded, `ok`, or
#            `fail:<summary length>:<its first 72 characters>`; a success
#            that is neither true nor false renders as its JSON, since
#            verify_prs reads it as truthiness
#   test     `.tests.rust`, the same
#   issues   every issue type in order, joined by `,`; `-` for none
set -euo pipefail

# A suite running from inside a git hook inherits GIT_DIR, GIT_COMMON_DIR,
# GIT_WORK_TREE and GIT_INDEX_FILE, which take precedence over `git -C`;
# sourcing verify-lib.sh runs git rev-parse.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$TEST_DIR/../scripts/lib/verify-lib.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
PASS=0
FAIL=0

assert_eq() {
  local got="$1" want="$2" label="$3"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$label"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        want: %s\n        got:  %s\n' "$label" "$want" "$got"
  fi
}

# --- the commands ---------------------------------------------------------------
cat >"$TMP_ROOT/large.sh" <<'CMD'
#!/usr/bin/env bash
for i in $(seq 1 2000); do
  printf 'error[E0001]: mismatched types at src/lib.rs:%d — expected u32, found i64\n' "$i"
done
exit 1
CMD
cat >"$TMP_ROOT/long-line.sh" <<'CMD'
#!/usr/bin/env bash
pad=""
for _ in $(seq 1 200); do
  pad="$pad$(printf 'x%.0s' {1..1000})"
done
printf 'error[E0001]: %s\n' "$pad"
exit 1
CMD
cat >"$TMP_ROOT/quiet.sh" <<'CMD'
#!/usr/bin/env bash
echo "build stopped: nothing here matches"
exit 1
CMD
chmod +x "$TMP_ROOT"/*.sh
command_of() {
  case "$1" in
    large|long-line|quiet) printf 'bash %s/%s.sh' "$TMP_ROOT" "$1" ;;
    pass) printf 'true' ;;
    *) echo "UNKNOWN-COMMAND: $1" >&2; exit 2 ;;
  esac
}

# The fixtures' preconditions: the matching text clears two pipe buffers, and
# the single line clears MAX_ARG_STRLEN (131072) on its own. BSD wc pads its
# count, so the blanks come off.
size_of() { bash "$TMP_ROOT/$1.sh" | wc -c | tr -d ' ' || true; }
for f in large long-line; do
  if [[ "$(size_of "$f")" -ge 131072 ]]; then
    PASS=$((PASS + 1)); printf '  ok    precondition: %s writes at least 131072 bytes\n' "$f"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  precondition: %s writes at least 131072 bytes (got %s)\n' "$f" "$(size_of "$f")"
  fi
done

# run_stack under live errexit, RESULTS_JSON recovered from an EXIT trap: an
# aborted run_stack leaves the entry it never wrote missing rather than taking
# the results down with it.
cat >"$TMP_ROOT/drive.sh" <<'DRIVE'
#!/usr/bin/env bash
set -euo pipefail
lib="$1" spec="$2" work="$3" out="$4"
# shellcheck disable=SC1090
source "$lib"
init_results
trap 'printf "%s" "${RESULTS_JSON:-}" >"$out"' EXIT
run_stack "$spec" "$work"
DRIVE

slot() { # results path
  jq -r --arg p "$1" '
    getpath($p | split(".")) as $s
    | if $s == null then "-"
      elif $s.success == true then "ok"
      elif $s.success == false then "fail:\($s.error | length):\($s.error[0:72])"
      else "success=\($s.success | tojson)"
      end' <"$TMP_ROOT/results.json"
}

run() { # command stage
  local cmd spec
  cmd="$(command_of "$1")"
  case "$2" in
    build) spec="rust|$cmd||." ;;
    test) spec="rust||$cmd|." ;;
    both) spec="rust|$cmd|$cmd|." ;;
    *) echo "UNKNOWN-STAGE: $2" >&2; exit 2 ;;
  esac
  : >"$TMP_ROOT/results.json"
  bash "$TMP_ROOT/drive.sh" "$LIB" "$spec" "$TMP_ROOT" "$TMP_ROOT/results.json" >/dev/null 2>&1 || true
  printf 'build=%s test=%s issues=%s' "$(slot builds.rust)" "$(slot tests.rust)" \
    "$(jq -r '[.issues[] | .type] | if length == 0 then "-" else join(",") end' <"$TMP_ROOT/results.json")"
}

run_table() {
  local title="$1" rows="$2" label command stage build test issues got row field before=$((PASS + FAIL))
  echo "=== $title ==="
  while IFS= read -r row; do
    [[ "$row" != "" ]] || continue
    IFS='|' read -r label command stage build test issues <<<"$row"
    for field in "$label" "$command" "$stage" "$build" "$test" "$issues"; do
      [[ "$field" != "" ]] || { printf 'a row with an empty field asserts nothing: %s\n' "$row" >&2; exit 1; }
    done
    got="$(run "$command" "$stage")"
    # A rendering aid for writing rows; the run is refused after the loop.
    if [[ "${GITHUB_TABLE_PROBE:-}" == 1 ]]; then
      printf '%s => %s\n' "$label" "$got"
      continue
    fi
    assert_eq "$got" "build=$build test=$test issues=$issues" "$label"
  done <<<"$rows"
  # At least one row asserted, and every listed row: an empty table and a
  # probe run are both refused.
  [[ "$((PASS + FAIL))" -gt "$before" ]] || { echo "no row was asserted (a probe run renders rows instead)" >&2; exit 2; }
  [[ "$((PASS + FAIL - before))" -eq "$(printf '%s\n' "$rows" | grep -c '|')" ]] || { echo "not every listed row was asserted" >&2; exit 2; }
}

LINE1='error[E0001]: mismatched types at src/lib.rs:1 — expected u32, found i64'

run_table "the failure summaries under live errexit" "\
a large build failure is recorded with its first error line, raises its issue and stops the stack|large|both|fail:365:$LINE1|-|rust_build_failed
a large test failure too|large|test|-|fail:365:$LINE1|rust_tests_failed
one error line past MAX_ARG_STRLEN is clipped to what reaches argv, its head kept|long-line|build|fail:2000:error[E0001]: xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx|-|rust_build_failed
one error line past MAX_ARG_STRLEN is clipped in the test branch too|long-line|test|-|fail:2000:error[E0001]: xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx|rust_tests_failed
a build failure matching no pattern has an empty summary, not a missing entry|quiet|build|fail:0:|-|rust_build_failed
a test failure matching no pattern too|quiet|test|-|fail:0:|rust_tests_failed
a passing build and test are recorded with no issue|pass|both|ok|ok|-
"

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
