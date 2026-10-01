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

# The real skill-load-check hook puts its anchors deep inside a large file.
# Pattern characters in a comment must remain literal, and no other byte
# may change when the helper inserts the mutation.
HOOK="$TMP_ROOT/deep-source.sh"
ANCHOR='value=expected # [*?] \ $ literal'
perl -e 'print "#" . ("p" x 22000) . "\n"' >"$HOOK"
printf '%s\nprintf "%%s\\n" "$value"\n' "$ANCHOR" >>"$HOOK"
perl -e 'print "#" . ("s" x 22000) . "\n"' >>"$HOOK"
perl -e 'print "#" . ("p" x 22000) . "\n"' >"$TMP_ROOT/deep-expected.sh"
printf '%s\nvalue=broken\nprintf "%%s\\n" "$value"\n' "$ANCHOR" >>"$TMP_ROOT/deep-expected.sh"
perl -e 'print "#" . ("s" x 22000) . "\n"' >>"$TMP_ROOT/deep-expected.sh"
skill_load_control deep "$HOOK" "$ANCHOR" value=broken HOOK selected_rows \
  'first selected row' 'second selected row'
status=0
cmp -s -- "$TMP_ROOT/deep.sh" "$TMP_ROOT/deep-expected.sh" || status=$?
assert_eq "$status" 0 'the deep literal edit preserves every other source byte'
HOOK="$TMP_ROOT/source.sh"

# Bad anchors and failed file operations must stop before the row callback.
# A directory at the output path forces a write failure even as root.
while IFS='|' read -r MODE want; do
  source="$HOOK"
  anchor=value=expected
  case "$MODE" in
    missing) anchor=value=absent ;;
    ambiguous) source="$TMP_ROOT/repeated.sh"; printf '%s\n' "$anchor" "$anchor" >"$source" ;;
    unreadable) source="$TMP_ROOT/absent.sh" ;;
    symlink) source="$TMP_ROOT/linked.sh"; ln -s "$HOOK" "$source" ;;
    unwritable) mkdir "$TMP_ROOT/invalid.sh" ;;
    *) echo "skill-load-control-test: mode=$MODE" >&2; exit 2 ;;
  esac
  set +e
  (
    set -e
    skill_load_control invalid "$source" "$anchor" value=broken HOOK selected_rows 'first selected row'
  ) >"$TMP_ROOT/invalid.log" 2>&1
  status=$?
  set -e
  IFS= read -r first <"$TMP_ROOT/invalid.log"
  assert_eq "status=$status first=$first" "status=2 first=skill-load-control: $want" "the helper rejects $MODE mutation input"
done <<'ROWS'
missing|anchor=missing
ambiguous|anchor=ambiguous
unreadable|source=unreadable
symlink|source=symlink
unwritable|mutation=unwritable
ROWS

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
