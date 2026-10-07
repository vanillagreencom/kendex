#!/usr/bin/env bash
# Tests for pr-list-ready's refresh of PRs whose mergeable state reads
# UNKNOWN. The refreshed PRs, each carrying its statusCheckRollup, grow with
# the open-PR count; handed to jq as one argument they fail the listing with
# "Argument list too long". The fixture refreshes 60 PRs of about 26 KiB
# each: one PR stays under Linux's per-argument limit (128 KiB) and all of
# them pass macOS's whole-argv limit (1 MiB), so the control fails on both.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP_ROOT="$(mktemp -d)" || { echo "pr-list-ready-unknown-refresh: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "pr-list-ready-unknown-refresh: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "pr-list-ready-unknown-refresh: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

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

# shellcheck source=lib/gh-stub.sh
. "$TEST_DIR/lib/gh-stub.sh"
# shellcheck source=lib/mutant-copy.sh
. "$TEST_DIR/lib/mutant-copy.sh"
GH_STUB_DIR="$TMP_ROOT/gh-stub" gh_stub_install "$TMP_ROOT/bin"
gh_stub_answer api-user tester

PR_COUNT=60
# 160 passing CheckRuns with 80-character names: about 26 KiB per PR.
rollup="$(jq -nc '[range(160) | {__typename: "CheckRun", status: "COMPLETED",
  conclusion: "SUCCESS", name: ("check-\(.)-" + ("x" * 72))}]')"
mk_pr() { # number mergeable
  jq -nc --argjson n "$1" --arg m "$2" --argjson rollup "$rollup" \
    '{number: $n, title: "pr \($n)", headRefName: "b\($n)",
      reviewDecision: "APPROVED", latestReviews: [{state: "APPROVED"}],
      statusCheckRollup: $rollup, mergeable: $m}'
}

listed=()
for n in $(seq 1 "$PR_COUNT"); do
  pr="$(mk_pr "$n" UNKNOWN)"
  listed+=("$pr")
  gh_stub_answer "pr-view:view $n --json" "$(mk_pr "$n" MERGEABLE)"
done
gh_stub_answer pr-list "$(printf '%s\n' "${listed[@]}" | jq -sc .)"

# run SCRIPT — the ready PR numbers, comma-joined, or the failure's stderr.
run() {
  local out
  if out="$(PATH="$TMP_ROOT/bin:$PATH" bash "$1" --all 2>"$TMP_ROOT/err")"; then
    jq -r '[.[] | select(.ready) | .number] | map(tostring) | join(",")' <<<"$out"
  else
    cat "$TMP_ROOT/err"
  fi
}

want="$(seq -s, 1 "$PR_COUNT")"

echo "=== 60 refreshed PRs with 4 KiB rollups ==="
assert_eq "$(run "$TEST_DIR/../scripts/commands/pr-list-ready.sh")" "$want" \
  "every refreshed PR is listed ready"

echo "=== must-fail control: the refreshed array passed as one jq argument ==="
mutant="$(mutant_copy_edit "$TMP_ROOT/argjson" \
  "        prs=\$(printf '%s\\n%s\\n' \"\$prs\" \"\$updated_prs\" | jq -s '" \
  "        prs=\$({ printf '%s\\n' \"\$prs\"; jq -n --argjson u \"\$updated_prs\" '\$u'; } | jq -s '" \
  commands/pr-list-ready.sh)"
got="$(run "$mutant")"
case "$got" in
*"Argument list too long"*) assert_eq argv-limit argv-limit "control: the argument route fails" ;;
*) assert_eq "$got" "Argument list too long" "control: the argument route fails" ;;
esac

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
