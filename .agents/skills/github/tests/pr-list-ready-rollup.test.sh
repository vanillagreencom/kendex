#!/usr/bin/env bash
# Regression tests for pr-list-ready's statusCheckRollup classification
# (VST-9): StatusContext nodes (classic commit statuses) carry .state, not
# .conclusion — a conclusion-only predicate reads their missing conclusion as
# null and counts every one of them, pending and failing included, as
# passing. Also pins: an in-progress CheckRun (null/empty conclusion) is
# pending, never passing.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CMD="$TEST_DIR/../scripts/commands/pr-list-ready.sh"
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

# Stub gh: `api user` returns a login; `pr list` returns the fixture. All PRs
# are MERGEABLE with an APPROVED review so readiness turns on CI alone.
mkdir -p "$TMP_ROOT/bin"
cat > "$TMP_ROOT/bin/gh" <<EOF
#!/usr/bin/env bash
case "\$1 \$2" in
  "api user") echo '{"login":"tester"}' | jq -r "\${4:-.login}" 2>/dev/null || echo tester ;;
  "pr list") cat "$TMP_ROOT/fixture.json" ;;
  *) echo "unexpected gh call: \$*" >&2; exit 1 ;;
esac
EOF
chmod +x "$TMP_ROOT/bin/gh"

approved='[{"state":"APPROVED"}]'
mk_pr() { # number rollup-json
  jq -n --argjson n "$1" --argjson rollup "$2" --argjson reviews "$approved" \
    '{number: $n, title: "pr \($n)", headRefName: "b\($n)",
      reviewDecision: "APPROVED", latestReviews: $reviews,
      statusCheckRollup: $rollup, mergeable: "MERGEABLE"}'
}

jq -s '.' \
  <(mk_pr 1 '[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"},{"__typename":"StatusContext","context":"gate","state":"SUCCESS"}]') \
  <(mk_pr 2 '[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"},{"__typename":"StatusContext","context":"gate","state":"PENDING"}]') \
  <(mk_pr 3 '[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"},{"__typename":"StatusContext","context":"gate","state":"FAILURE"}]') \
  <(mk_pr 4 '[{"__typename":"StatusContext","context":"gate","state":"ERROR"}]') \
  <(mk_pr 5 '[{"__typename":"CheckRun","status":"IN_PROGRESS","conclusion":null}]') \
  <(mk_pr 6 '[]') \
  > "$TMP_ROOT/fixture.json"

out="$(PATH="$TMP_ROOT/bin:$PATH" bash "$CMD" --all)"

ci_of()    { jq -r --argjson n "$1" '.[] | select(.number == $n) | .ci' <<<"$out"; }
ready_of() { jq -r --argjson n "$1" '.[] | select(.number == $n) | .ready' <<<"$out"; }

echo "=== StatusContext nodes are judged by .state ==="
assert_eq "$(ci_of 1)"    "passing" "pr1: SUCCESS status + SUCCESS run is passing"
assert_eq "$(ready_of 1)" "true"    "pr1: and ready"
assert_eq "$(ci_of 2)"    "pending" "pr2: PENDING status is pending, not passing"
assert_eq "$(ready_of 2)" "false"   "pr2: and not ready"
assert_eq "$(ci_of 3)"    "failing" "pr3: FAILURE status is failing"
assert_eq "$(ready_of 3)" "false"   "pr3: and not ready"
assert_eq "$(ci_of 4)"    "failing" "pr4: ERROR status is failing"

echo "=== CheckRun nodes: null conclusion is pending ==="
assert_eq "$(ci_of 5)"    "pending" "pr5: in-progress run is pending, not passing"
assert_eq "$(ready_of 5)" "false"   "pr5: and not ready"

echo "=== no checks ==="
assert_eq "$(ci_of 6)"    "no_checks" "pr6: empty rollup is no_checks"
assert_eq "$(ready_of 6)" "true"      "pr6: no checks does not block readiness"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
