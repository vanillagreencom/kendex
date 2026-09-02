#!/usr/bin/env bash
# Regression tests for verify-lib's run_stack failure summaries (KEN-1143).
#
# Both failure branches built their summary as
# `echo "$output" | grep -E ... | head -5 | tr`. head closes the pipe on its
# fifth line and SIGPIPEs grep, and pipefail makes 141 the status of an
# unguarded assignment — so under errexit the branch died before recording
# anything: no builds/tests entry, no issue, for exactly the failures whose
# output is large. It survived only because verify_prs' one call site runs
# `run_stack ... || true`, and a command in an `||` list suppresses errexit for
# the whole call.
#
# So each case runs run_stack with errexit LIVE and reads RESULTS_JSON out of an
# EXIT trap, which is what the summary must survive. Either branch reverted to
# its piped form reddens this suite.
#
# Run: bash skills/github/tests/verify-lib-error-summary.test.sh
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$TEST_DIR/../scripts/lib/verify-lib.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

assert_eq() {
  local got="$1" want="$2" name="$3"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$name" "$want" "$got"
  fi
}

assert_ge() {
  local got="$1" bound="$2" name="$3"
  if [[ "$got" =~ ^[0-9]+$ ]] && [ "$got" -ge "$bound" ]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        wanted: >= %s\n        got:    %s\n' "$name" "$bound" "$got"
  fi
}

# A failing command whose matching error lines run well past the 64KB pipe
# buffer, so grep is still writing when head has its five lines.
cat > "$TMP_ROOT/fail.sh" <<'CMD'
#!/usr/bin/env bash
for i in $(seq 1 2000); do
  printf 'error[E0001]: mismatched types at src/lib.rs:%d — expected u32, found i64\n' "$i"
done
exit 1
CMD
chmod +x "$TMP_ROOT/fail.sh"
assert_ge "$(bash "$TMP_ROOT/fail.sh" | wc -c || true)" 131072 "failing command's error text clears two pipe buffers"

# run_stack under live errexit, with RESULTS_JSON recovered from an EXIT trap:
# an aborted run_stack leaves the entry it never wrote missing rather than
# taking the results down with it.
cat > "$TMP_ROOT/drive.sh" <<'DRIVE'
#!/usr/bin/env bash
set -euo pipefail
lib="$1" spec="$2" work="$3" out="$4"
# shellcheck disable=SC1090
source "$lib"
init_results
trap 'printf "%s" "${RESULTS_JSON:-}" >"$out"' EXIT
run_stack "$spec" "$work"
DRIVE
chmod +x "$TMP_ROOT/drive.sh"

drive() { # stack_spec -> results json on stdout
  local out="$TMP_ROOT/results.json"
  : > "$out"
  bash "$TMP_ROOT/drive.sh" "$LIB" "$1" "$TMP_ROOT" "$out" >/dev/null 2>&1 || true
  cat "$out"
}

expected_line='error[E0001]: mismatched types at src/lib.rs:1 — expected u32, found i64'

echo "=== a large build failure is still summarized (KEN-1143) ==="
results="$(drive "rust|bash $TMP_ROOT/fail.sh||.")"
assert_eq "$(jq -r '.builds.rust.success' <<<"$results")" "false" "the build failure is recorded"
assert_eq "$(jq -r '.builds.rust.error | startswith($l)' --arg l "$expected_line" <<<"$results")" "true" "the build summary carries the first error line"
assert_eq "$(jq -r '[.issues[] | select(.type == "rust_build_failed")] | length' <<<"$results")" "1" "the build failure raises its issue"

echo "=== a large test failure is still summarized (KEN-1143) ==="
results="$(drive "rust||bash $TMP_ROOT/fail.sh|.")"
assert_eq "$(jq -r '.tests.rust.success' <<<"$results")" "false" "the test failure is recorded"
assert_eq "$(jq -r '.tests.rust.error | startswith($l)' --arg l "$expected_line" <<<"$results")" "true" "the test summary carries the first error line"
assert_eq "$(jq -r '[.issues[] | select(.type == "rust_tests_failed")] | length' <<<"$results")" "1" "the test failure raises its issue"

# A failure whose output matches no summary pattern. grep exits 1, and without
# the `|| true` on the assignment errexit takes the branch down at the no-match
# — the same lost record as the SIGPIPE, reached without one. The summary is
# empty because there was nothing to summarize; the entry and its issue are not.
cat > "$TMP_ROOT/quiet-fail.sh" <<'CMD'
#!/usr/bin/env bash
echo "build stopped: nothing here matches"
exit 1
CMD
chmod +x "$TMP_ROOT/quiet-fail.sh"

echo "=== a failure matching no pattern is still recorded (KEN-1143) ==="
results="$(drive "rust|bash $TMP_ROOT/quiet-fail.sh||.")"
assert_eq "$(jq -r '.builds.rust.success' <<<"$results")" "false" "the unmatched build failure is recorded"
assert_eq "$(jq -r '.builds.rust.error' <<<"$results")" "" "its summary is empty, not missing"
assert_eq "$(jq -r '[.issues[] | select(.type == "rust_build_failed")] | length' <<<"$results")" "1" "the unmatched build failure raises its issue"

results="$(drive "rust||bash $TMP_ROOT/quiet-fail.sh|.")"
assert_eq "$(jq -r '.tests.rust.success' <<<"$results")" "false" "the unmatched test failure is recorded"
assert_eq "$(jq -r '.tests.rust.error' <<<"$results")" "" "its summary is empty, not missing"
assert_eq "$(jq -r '[.issues[] | select(.type == "rust_tests_failed")] | length' <<<"$results")" "1" "the unmatched test failure raises its issue"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
