#!/usr/bin/env bash
# Regression tests for orch/scripts/ci/review-predicate.sh (vstack#949) — the
# vendorable single source of truth for "is this PR head reviewed?" behind the
# pending-status review gate (DEVELOPMENT.md § CI Triggering Patterns).
#
# Verdict cases:
#   1.  non-author review at head, 0 threads      -> approved
#   2.  no evidence at all                        -> awaiting
#   3.  review at head + unresolved threads       -> threads-open (count in detail)
#   4.  CHANGES_REQUESTED at head                 -> changes-requested (wins over threads)
#   5.  CR superseded by same reviewer's later    -> approved (latest-per-reviewer)
#       review at head
#   6.  review pinned to a stale sha only         -> awaiting (head pinning)
#   7.  PR author's own review only               -> awaiting (author excluded)
#   8.  DISMISSED review only                     -> awaiting (dismissal excluded)
# Evidence surfaces:
#   9.  trusted check-run success at head         -> approved
#   10. trusted commit status success at head     -> approved
#   11. outage attestation status at head         -> approved
#   12. REVIEW_CHECK_NAME="" disables both        -> awaiting despite evidence
#       clean-analysis surfaces
#   13. OUTAGE_CONTEXT="" disables the marker     -> awaiting despite marker
#   14. custom REVIEW_CHECK_NAME matches its own  -> approved
#       context
# Fail-closed / fail-loud:
#   15. reviewThreads first:100 overflow          -> threads-open (never open past
#       (hasNextPage)                                an unverifiable read)
#   16. reviews read failure                      -> exit 2, NO verdict line
#   17. reviewThreads read failure                -> exit 2, NO verdict line
#   18. missing required env (HEAD_SHA)           -> exit 2
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
PREDICATE="$REPO_ROOT/skills/orch/scripts/ci/review-predicate.sh"
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

assert_contains() {
  local haystack="$1" needle="$2" name="$3"
  if grep -qF -- "$needle" <<<"$haystack"; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        wanted substring: %s\n        in: %s\n' "$name" "$needle" "$haystack"
  fi
}

mkdir -p "$TMP_ROOT/bin"

# Parametrized `gh` stub. The predicate pipes raw API JSON into its own local
# jq, so the stub only fabricates payloads:
#   STUB_REVIEWS_MODE   none|review_at_head|review_stale|author_only|dismissed|
#                       cr|cr_superseded|fail — the pulls/N/reviews page
#   STUB_CHECKS_MODE    none|success — the trusted check-run at head
#   STUB_STATUS_CTXS    space-separated status contexts published at state
#                       success on the head's combined status (e.g.
#                       "Devin Review" or "vstack-reviewer-outage")
#   STUB_THREADS        unresolved-thread count, or "overflow"
#                       (hasNextPage — the stub answers the graphql call with
#                       the post-jq scalar, matching the --jq the predicate
#                       sends), or "fail"
cat > "$TMP_ROOT/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -u
[[ "${1:-}" == "api" ]] || { echo "unexpected gh command: $*" >&2; exit 1; }
shift

if [[ "${1:-}" == "graphql" ]]; then
  case "${STUB_THREADS:-0}" in
    fail) echo "HTTP 500" >&2; exit 1 ;;
    *) printf '%s\n' "${STUB_THREADS:-0}"; exit 0 ;;
  esac
fi

args="$*"
case "$args" in
  *"/pulls/"*"/reviews"*)
    case "${STUB_REVIEWS_MODE:-none}" in
      fail) echo "HTTP 500" >&2; exit 1 ;;
      none) echo '[]' ;;
      review_at_head)
        echo '[{"commit_id":"headsha","state":"COMMENTED","user":{"login":"reviewer1"}}]' ;;
      review_stale)
        echo '[{"commit_id":"oldsha","state":"COMMENTED","user":{"login":"reviewer1"}}]' ;;
      author_only)
        echo '[{"commit_id":"headsha","state":"COMMENTED","user":{"login":"pr-author"}}]' ;;
      dismissed)
        echo '[{"commit_id":"headsha","state":"DISMISSED","user":{"login":"reviewer1"}}]' ;;
      cr)
        echo '[{"commit_id":"headsha","state":"CHANGES_REQUESTED","user":{"login":"reviewer1"}}]' ;;
      cr_superseded)
        echo '[{"commit_id":"headsha","state":"CHANGES_REQUESTED","user":{"login":"reviewer1"}},{"commit_id":"headsha","state":"COMMENTED","user":{"login":"reviewer1"}}]' ;;
      *) echo "unknown STUB_REVIEWS_MODE" >&2; exit 1 ;;
    esac
    ;;
  *"/pulls/"*)
    # Author resolution (only reached when PR_AUTHOR is unset); the predicate
    # passes --jq, so answer with the scalar.
    echo "pr-author"
    ;;
  *"/check-runs"*)
    name="${STUB_CHECK_NAME:-Devin Review}"
    case "${STUB_CHECKS_MODE:-none}" in
      none) echo '{"check_runs":[]}' ;;
      success) printf '{"check_runs":[{"name":"%s","conclusion":"success"}]}\n' "$name" ;;
      *) echo "unknown STUB_CHECKS_MODE" >&2; exit 1 ;;
    esac
    ;;
  *"/status"*)
    statuses=""
    for ctx in ${STUB_STATUS_CTXS:-}; do
      ctx="${ctx//_/ }"
      [[ -n "$statuses" ]] && statuses+=","
      statuses+="{\"context\":\"$ctx\",\"state\":\"success\"}"
    done
    printf '{"statuses":[%s]}\n' "$statuses"
    ;;
  *)
    echo "unexpected gh api call: $args" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$TMP_ROOT/bin/gh"

# run_predicate [ENV=val ...] — runs the predicate under the stub with the
# standard identifiers; prints stdout, returns its exit code.
run_predicate() {
  env PATH="$TMP_ROOT/bin:$PATH" \
    GH_REPO=acme/widgets PR_NUMBER=7 HEAD_SHA=headsha PR_AUTHOR=pr-author \
    "$@" bash "$PREDICATE" 2>/dev/null
}

verdict_of() { sed -n 's/^verdict=\([a-z-]*\) .*/\1/p' <<<"$1"; }

echo "=== review-predicate verdicts ==="

out=$(run_predicate STUB_REVIEWS_MODE=review_at_head STUB_THREADS=0)
assert_eq "$?" "0" "1: review at head exits 0"
assert_eq "$(verdict_of "$out")" "approved" "1: review at head, no threads -> approved"

out=$(run_predicate STUB_REVIEWS_MODE=none STUB_THREADS=0)
assert_eq "$(verdict_of "$out")" "awaiting" "2: no evidence -> awaiting"

out=$(run_predicate STUB_REVIEWS_MODE=review_at_head STUB_THREADS=2)
assert_eq "$(verdict_of "$out")" "threads-open" "3: unresolved threads -> threads-open"
assert_contains "$out" "2 unresolved review thread" "3: detail carries the count"

out=$(run_predicate STUB_REVIEWS_MODE=cr STUB_THREADS=3)
assert_eq "$(verdict_of "$out")" "changes-requested" "4: CR at head wins over open threads"

out=$(run_predicate STUB_REVIEWS_MODE=cr_superseded STUB_THREADS=0)
assert_eq "$(verdict_of "$out")" "approved" "5: CR superseded by same reviewer's later review -> approved"

out=$(run_predicate STUB_REVIEWS_MODE=review_stale STUB_THREADS=0)
assert_eq "$(verdict_of "$out")" "awaiting" "6: stale-sha review only -> awaiting"

out=$(run_predicate STUB_REVIEWS_MODE=author_only STUB_THREADS=0)
assert_eq "$(verdict_of "$out")" "awaiting" "7: author's own review only -> awaiting"

out=$(run_predicate STUB_REVIEWS_MODE=dismissed STUB_THREADS=0)
assert_eq "$(verdict_of "$out")" "awaiting" "8: DISMISSED review only -> awaiting"

echo "=== evidence surfaces ==="

out=$(run_predicate STUB_REVIEWS_MODE=none STUB_CHECKS_MODE=success STUB_THREADS=0)
assert_eq "$(verdict_of "$out")" "approved" "9: trusted check-run success -> approved"

out=$(run_predicate STUB_REVIEWS_MODE=none STUB_STATUS_CTXS=Devin_Review STUB_THREADS=0)
assert_eq "$(verdict_of "$out")" "approved" "10: trusted commit status success -> approved"

out=$(run_predicate STUB_REVIEWS_MODE=none STUB_STATUS_CTXS=vstack-reviewer-outage STUB_THREADS=0)
assert_eq "$(verdict_of "$out")" "approved" "11: outage attestation -> approved"

out=$(run_predicate STUB_REVIEWS_MODE=none STUB_CHECKS_MODE=success \
  STUB_STATUS_CTXS=Devin_Review REVIEW_CHECK_NAME= STUB_THREADS=0)
assert_eq "$(verdict_of "$out")" "awaiting" "12: empty REVIEW_CHECK_NAME disables clean-analysis surfaces"

out=$(run_predicate STUB_REVIEWS_MODE=none STUB_STATUS_CTXS=vstack-reviewer-outage \
  OUTAGE_CONTEXT= STUB_THREADS=0)
assert_eq "$(verdict_of "$out")" "awaiting" "13: empty OUTAGE_CONTEXT disables the marker"

out=$(run_predicate STUB_REVIEWS_MODE=none REVIEW_CHECK_NAME="Custom Bot" \
  STUB_CHECK_NAME="Custom Bot" STUB_CHECKS_MODE=success STUB_THREADS=0)
assert_eq "$(verdict_of "$out")" "approved" "14: custom REVIEW_CHECK_NAME matches its own name"

echo "=== fail-closed / fail-loud ==="

out=$(run_predicate STUB_REVIEWS_MODE=review_at_head STUB_THREADS=overflow)
assert_eq "$(verdict_of "$out")" "threads-open" "15: first:100 overflow fails closed to threads-open"

set +e
out=$(run_predicate STUB_REVIEWS_MODE=fail STUB_THREADS=0)
rc=$?
set -e
assert_eq "$rc" "2" "16: reviews read failure exits 2"
assert_eq "$(verdict_of "$out")" "" "16: no verdict line on read failure"

set +e
out=$(run_predicate STUB_REVIEWS_MODE=review_at_head STUB_THREADS=fail)
rc=$?
set -e
assert_eq "$rc" "2" "17: reviewThreads read failure exits 2"
assert_eq "$(verdict_of "$out")" "" "17: no verdict line on thread-read failure"

set +e
out=$(env PATH="$TMP_ROOT/bin:$PATH" GH_REPO=acme/widgets PR_NUMBER=7 \
  STUB_REVIEWS_MODE=none STUB_THREADS=0 bash "$PREDICATE" 2>/dev/null)
rc=$?
set -e
assert_eq "$rc" "2" "18: missing HEAD_SHA exits 2"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
