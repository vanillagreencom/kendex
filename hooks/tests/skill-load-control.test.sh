#!/usr/bin/env bash
# The mutation helper runs only its row callback, isolates its overrides and
# counts, and rejects a passing callback, a wrong status, or a missing or
# repeated FAIL row. The skill-load-check suites are its callers.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIBRARY="${ASSERT_UNDER_TEST:-$TEST_DIR/lib/assert.sh}"
# shellcheck source=lib/assert.sh
. "$LIBRARY"
PASS=0
FAIL=0
TMP_ROOT="$(mktemp -d)" || { echo "skill-load-control: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "skill-load-control: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "skill-load-control: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
BASH_BIN="$(command -v bash)"
HOOK="$TMP_ROOT/source.sh"
printf 'value=expected\nprintf "%%s\\n" "$value"\n' >"$HOOK"

selected_rows() {
  local value
  value=$(env -i PATH="$PATH" HOME="$TMP_ROOT" "$BASH_BIN" "$HOOK")
  printf '%s\n' "$HOOK" >>"$TMP_ROOT/invoked"
  assert_eq "$value" expected 'first selected row'
  assert_eq "$value" expected 'second selected row'
}
skill_load_control selected "$HOOK" value=expected value=broken HOOK selected_rows \
  'first selected row' 'second selected row'
assert_eq "PASS=$PASS FAIL=$FAIL" 'PASS=3 FAIL=0' 'only control results reach the parent counters'
assert_eq "$HOOK" "$TMP_ROOT/source.sh" 'the override does not replace the parent hook'
assert_eq "$(cat -- "$TMP_ROOT/invoked")" "$TMP_ROOT/selected.sh" 'only the selected callback runs once on the mutant'
assert_eq "$(env -i PATH="$PATH" HOME="$TMP_ROOT" "$BASH_BIN" "$HOOK")" expected 'the original source stays unchanged'

# These callback outcomes are the helper's observable input, not substitutes
# for the helper. Each is checked through skill_load_control itself. The
# caller's outcome.log must not overlap the helper's callback capture, which
# would let control output overwrite the duplicate FAIL row before matching.
callback_outcome() {
  case "$MODE" in
    missing) assert_eq broken expected 'another row' ;;
    duplicate)
      assert_eq broken expected 'selected row'
      assert_eq broken expected 'selected row'
      ;;
    wrong-status) assert_eq broken expected 'selected row'; return 2 ;;
    passing) assert_eq expected expected 'selected row' ;;
    *) echo "skill-load-control-test: mode=$MODE" >&2; exit 2 ;;
  esac
}
while IFS='|' read -r MODE want; do
  set +e
  (
    set -e
    PASS=0
    FAIL=0
    skill_load_control outcome "$HOOK" value=expected value=broken HOOK callback_outcome 'selected row'
    [ "$FAIL" -eq 0 ]
  ) >"$TMP_ROOT/outcome.log" 2>&1
  status=$?
  set -e
  assert_eq "$status" "$want" "the helper rejects $MODE callback results"
done <<'ROWS'
missing|1
duplicate|1
wrong-status|1
passing|1
ROWS

# Reusing the caller's name-based log lets control output overwrite a FAIL
# row. The helper's own duplicate-row rejection test must then turn red.
helper_rows() {
  local status
  set +e
  env -i PATH="$PATH" HOME="$TMP_ROOT" ASSERT_UNDER_TEST="$LIBRARY" \
    HELPER_CONTROL_ACTIVE=1 "$BASH_BIN" "$TEST_DIR/skill-load-control.test.sh" >"$TMP_ROOT/helper-suite.log" 2>&1
  status=$?
  set -e
  assert_eq "$status" 0 'the helper isolates its callback log'
}
if [ "${HELPER_CONTROL_ACTIVE:-}" != 1 ]; then
  skill_load_control helper "$LIBRARY" '  set +e' '  log="$TMP_ROOT/$name.log"' LIBRARY helper_rows \
    'the helper isolates its callback log'
fi

echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
