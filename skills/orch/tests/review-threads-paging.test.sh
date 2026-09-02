#!/usr/bin/env bash
# `orch_count_unresolved_threads` is the one reviewThreads walk in orch.
# approval-wait's waiter and queue-wait's late-findings guard both decide
# whether a PR still carries open threads from it, so a count that disagreed
# between them would let one pass a PR the other holds.
#
# It is fail-closed throughout: a page that cannot be verified prints nothing
# and returns nonzero. Reading an unverifiable page as "no threads" is the
# exact failure both callers exist to prevent, so every rule of the strict
# read gets its own must-fail case here.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
LIB="$SKILL_DIR/scripts/lib/review-threads.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }
eq()  { [[ "$1" == "$2" ]] && ok "$3" || bad "$3" "expected: $2  got: $1"; }

mkdir -p "$TMP_ROOT/bin"
ERR="$TMP_ROOT/gh.err"

# The stub answers page 1 from STUB_PAGE1 and every later page from STUB_PAGE2,
# keyed on the cursor the walk sends. Each body is the whole response, so a
# case can hand back any malformed shape it wants to see refused, and
# STUB_GH_EXIT makes the call itself fail. Every call is tallied in STUB_CALLS:
# some rules are only distinguishable from their neighbour by how many queries
# the walk spends before refusing.
STUB_CALLS="$TMP_ROOT/gh.calls"
export STUB_CALLS
cat >"$TMP_ROOT/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s' "$(( $(cat "$STUB_CALLS") + 1 ))" >"$STUB_CALLS"
if [[ -n "${STUB_GH_EXIT:-}" ]]; then
  echo "stub gh failure" >&2
  exit "$STUB_GH_EXIT"
fi
if [[ "$*" == *"cursor="* ]]; then
  printf '%s\n' "${STUB_PAGE2:?}"
else
  printf '%s\n' "${STUB_PAGE1:?}"
fi
EOF
chmod +x "$TMP_ROOT/bin/gh"
printf '0' >"$STUB_CALLS"

# $1 = nodes JSON, $2 = hasNextPage, $3 = endCursor JSON
page() {
  jq -cn --argjson nodes "$1" --argjson next "$2" --argjson cur "$3" \
    '{data:{repository:{pullRequest:{reviewThreads:{nodes:$nodes,pageInfo:{hasNextPage:$next,endCursor:$cur}}}}}}'
}

P1='[{"isResolved":false},{"isResolved":true},{"isResolved":false}]'
P2='[{"isResolved":false},{"isResolved":true}]'

# One call per case, in a subshell with the lib sourced, so no case's
# environment reaches the next.
call() {
  ( set +e
    export PATH="$TMP_ROOT/bin:$PATH"
    # shellcheck source=/dev/null
    . "$LIB"
    orch_count_unresolved_threads owner repo 7 "$ERR"
    exit $? )
}

echo "=== orch_count_unresolved_threads: the walk ==="

STUB_PAGE1="$(page "$P1" false null)"
STUB_PAGE2="$(page '[]' false null)"
export STUB_PAGE1 STUB_PAGE2
rc=0; out="$(call)" || rc=$?
eq "$rc" "0" "a single verified page succeeds"
eq "$out" "2" "only the unresolved threads are counted"

STUB_PAGE1="$(page '[]' false null)"
out="$(call)"
eq "$out" "0" "no threads counts zero, which is not a failure"

# The reason the walk exists: GitHub caps a page at 100 nodes, so a PR whose
# unresolved threads sit on page 2 must not read as clean.
STUB_PAGE1="$(page "$P1" true '"CURSOR2"')"
STUB_PAGE2="$(page "$P2" false null)"
rc=0; out="$(call)" || rc=$?
eq "$rc" "0" "a two-page walk succeeds"
eq "$out" "3" "both pages' unresolved threads are counted"

echo
echo "--- fail-closed: an unverifiable read counts nothing ---"

# Each case is a must-fail control for one rule of the strict read: without
# that rule the walk would answer with a count a caller reads as authoritative.
fails_closed() { # $1 = case name, $2 = page-1 body
  STUB_PAGE1="$2"
  local out rc=0
  out="$(call)" || rc=$?
  if [[ "$rc" -ne 0 && -z "$out" ]]; then
    ok "$1"
  else
    bad "$1" "rc=$rc out=$out"
  fi
}

STUB_PAGE2="$(page "$P2" false null)"
fails_closed "a null reviewThreads is refused" \
  '{"data":{"repository":{"pullRequest":{"reviewThreads":null}}}}'
fails_closed "nodes that are not an array is refused" \
  '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":{},"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}'
fails_closed "a page with no pageInfo is refused" \
  '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}'
fails_closed "a non-boolean hasNextPage is refused" \
  '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[],"pageInfo":{"hasNextPage":"no","endCursor":null}}}}}}'
fails_closed "a non-boolean isResolved is refused" \
  '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"isResolved":"false"}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}'
# A partial response: well-shaped data beside a top-level errors array is data
# for the pages GitHub could serve, and counting it undercounts the blockers.
fails_closed "a partial response with a top-level errors array is refused" \
  "$(jq -c '.errors = [{"message":"timeout"}]' <<<"$(page "$P1" false null)")"
# `{}` and `""` both measure length zero, which read as "no errors" before the
# type check went in — the malformed body would have counted as a clean one.
fails_closed "an errors field that is not an array is refused" \
  "$(jq -c '.errors = {}' <<<"$(page "$P1" false null)")"
fails_closed "a response that is not an object is refused" '"not an object"'

# A cursor that repeats forever: the walk stops rather than spinning to the
# page bound.
STUB_PAGE1="$(page "$P1" true '"CURSOR2"')"
STUB_PAGE2="$(page "$P2" true '"CURSOR2"')"
printf '0' >"$STUB_CALLS"
rc=0; out="$(call)" || rc=$?
[[ "$rc" -ne 0 && -z "$out" ]] && ok "a cursor that does not advance is refused" \
  || bad "a cursor that does not advance is refused" "rc=$rc out=$out"
eq "$(cat "$STUB_CALLS")" "2" "the non-advancing cursor is caught on the page that repeats it"

# The missing-cursor rule, isolated from the non-advancing one beside it. On
# page 1 the two are indistinguishable -- an empty cursor equals the empty
# starting cursor, so either rule refuses after one query and deleting one
# leaves the case green. From page 2 they part: an empty cursor no longer
# equals "CURSOR2", so with `[ -n "$page_cursor" ]` deleted the walk accepts
# it, restarts from page 1 and oscillates to the page bound. The query TALLY
# is what tells the two apart -- two calls means the missing cursor was
# refused where it appeared, not swallowed and rediscovered 18 pages later.
cursor_missing_on_page_two() { # $1 = case name, $2 = page-2 endCursor JSON
  STUB_PAGE1="$(page "$P1" true '"CURSOR2"')"
  STUB_PAGE2="$(page "$P2" true "$2")"
  printf '0' >"$STUB_CALLS"
  local out rc=0
  out="$(call)" || rc=$?
  [[ "$rc" -ne 0 && -z "$out" ]] && ok "$1" || bad "$1" "rc=$rc out=$out"
  eq "$(cat "$STUB_CALLS")" "2" "$1, on the page that omitted it"
}
cursor_missing_on_page_two "hasNextPage with a null cursor is refused" null
cursor_missing_on_page_two "hasNextPage with an empty cursor is refused" '""'

# --- where the page bound sits ---------------------------------------------
# The bound is new to approval-wait, which paginated without one before, so a
# PR past it now fails the waiter and the late-findings guard closed and stays
# that way. That cliff has to be measured, not just shown to exist: an
# always-advancing stub driven by a call COUNTER (never $RANDOM, so the page
# number is the call number) walks exactly the bound, then one page more.
cat >"$TMP_ROOT/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
n=$(( $(cat "$STUB_CALLS") + 1 ))
printf '%s' "$n" >"$STUB_CALLS"
next=true
[[ "$n" -ge "${STUB_LAST_PAGE:?}" ]] && next=false
printf '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"isResolved":false}],"pageInfo":{"hasNextPage":%s,"endCursor":"C%s"}}}}}}\n' "$next" "$n"
EOF
chmod +x "$TMP_ROOT/bin/gh"

# Read the bound off the lib: spelling 20 here would pin the test to itself.
PAGE_MAX="$( . "$LIB"; printf '%s' "$ORCH_THREAD_PAGE_MAX" )"
[[ "$PAGE_MAX" =~ ^[0-9]+$ && "$PAGE_MAX" -ge 2 ]] && ok "the lib names a numeric page bound" \
  || bad "the lib names a numeric page bound" "ORCH_THREAD_PAGE_MAX=$PAGE_MAX"

printf '0' >"$STUB_CALLS"
STUB_LAST_PAGE="$PAGE_MAX"; export STUB_LAST_PAGE
rc=0; out="$(call)" || rc=$?
[[ "$rc" -eq 0 && "$out" == "$PAGE_MAX" ]] \
  && ok "a walk of exactly ORCH_THREAD_PAGE_MAX pages succeeds and counts every page" \
  || bad "a walk of exactly ORCH_THREAD_PAGE_MAX pages succeeds and counts every page" \
     "rc=$rc out=$out want=$PAGE_MAX pages=$(cat "$STUB_CALLS")"
eq "$(cat "$STUB_CALLS")" "$PAGE_MAX" "the walk stopped on the last page it was given"

printf '0' >"$STUB_CALLS"
STUB_LAST_PAGE=$((PAGE_MAX + 1))
rc=0; out="$(call)" || rc=$?
[[ "$rc" -ne 0 && -z "$out" ]] \
  && ok "a walk of ORCH_THREAD_PAGE_MAX+1 pages is refused, not truncated" \
  || bad "a walk of ORCH_THREAD_PAGE_MAX+1 pages is refused, not truncated" \
     "rc=$rc out=$out pages=$(cat "$STUB_CALLS")"
eq "$(cat "$STUB_CALLS")" "$PAGE_MAX" "the refusal spends no query past the bound"
unset STUB_LAST_PAGE

# A failed gh call: its stderr must reach ERR_FILE, which is what the callers
# classify as transient or terminal.
cat >"$TMP_ROOT/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "HTTP 401: Bad credentials" >&2
exit 1
EOF
chmod +x "$TMP_ROOT/bin/gh"
: >"$ERR"
rc=0; out="$(call)" || rc=$?
[[ "$rc" -ne 0 && -z "$out" ]] && ok "a failed query is refused" \
  || bad "a failed query is refused" "rc=$rc out=$out"
grep -Fq 'Bad credentials' "$ERR" && ok "the query's own stderr reaches the error file" \
  || bad "the query's own stderr reaches the error file" "$(cat "$ERR")"

echo
echo "=== both callers read threads through this walk ==="

# The point of the shared walk: neither caller may carry a second reviewThreads
# query, or the waiter and the guard can disagree about what an open thread is.
for script in approval-wait queue-wait; do
  if grep -Fq 'orch_count_unresolved_threads' "$SKILL_DIR/scripts/$script"; then
    ok "$script counts threads through the shared walk"
  else
    bad "$script counts threads through the shared walk"
  fi
  if grep -Fq 'reviewThreads(first:' "$SKILL_DIR/scripts/$script"; then
    bad "$script carries its own reviewThreads query"
  else
    ok "$script carries no reviewThreads query of its own"
  fi
done


echo
echo "=== what a refused page does to approval-wait ==="

# The grep pair above proves approval-wait reads through this walk. This proves
# what happens when the walk refuses. approval-wait's old counter tolerated a
# reviewThreads page with no pageInfo (`.pageInfo.hasNextPage // false`) and
# counted it as ZERO open threads; this walk refuses it, so the exit below is
# newly reachable and no case had been seen to take it.
#
# The classification is the part worth pinning. gh_failure_is_transient reads
# GH_ERR_FILE, and a SHAPE failure leaves that file EMPTY -- the lib appends
# only gh's own stderr, and here gh exits 0 having printed a well-formed but
# unusable body. An empty error file matches no transient token, so the failure
# is terminal and the wait exits at once. A classifier that read "no error text"
# as transient would instead spend the entire wait budget re-reading a page that
# will never parse, and report the PR as still pending rather than as broken.
AW="$SKILL_DIR/scripts/approval-wait"
AW_REPO="$TMP_ROOT/aw-repo"
mkdir -p "$AW_REPO/.agents/skills" "$TMP_ROOT/awbin"
ln -sfn "$SKILL_DIR" "$AW_REPO/.agents/skills/orch"
git init -q "$AW_REPO"

# The smallest gh approval-wait needs: an auth probe, the repo name, the
# approval snapshot, and the thread query whose body this case controls.
cat >"$TMP_ROOT/awbin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-} ${2:-}" in
  "auth status") exit 0 ;;
  "repo view")   echo "owner/repo"; exit 0 ;;
  "api graphql") printf '%s\n' "${STUB_AW_THREADS:?}"; exit 0 ;;
  "pr view")
    if [[ "$*" == *"-q .headRefOid"* ]]; then echo "headsha1"; exit 0; fi
    echo '{"reviewDecision":"APPROVED","latestReviews":[{"author":{"login":"r1"},"state":"APPROVED"}],"headRefOid":"headsha1","author":{"login":"pr-author"}}'
    exit 0 ;;
esac
printf 'unexpected gh call: %s\n' "$*" >&2
exit 1
EOF
chmod +x "$TMP_ROOT/awbin/gh"

run_aw() { # $1 = graphql body
  ( set +e
    cd "$AW_REPO" || exit 9
    PATH="$TMP_ROOT/awbin:$PATH" STUB_AW_THREADS="$1" \
      .agents/skills/orch/scripts/approval-wait 7 1 4 --json
    exit $? )
}

# The control first: a page the walk accepts must reach the approved verdict,
# or the refusals below would prove nothing about the shape and everything
# about the stub.
aw_err="$TMP_ROOT/aw-ok.err"
rc=0; out="$(run_aw "$(page '[]' false null)" 2>"$aw_err")" || rc=$?
eq "$rc" "0" "approval-wait reaches its verdict on a page the walk accepts"
eq "$(jq -r .status <<<"$out")" "approved" "the accepted page produces the approved verdict"

for body_name in null_threads bad_isresolved; do
  case "$body_name" in
    null_threads)    body='{"data":{"repository":{"pullRequest":{"reviewThreads":null}}}}' ;;
    bad_isresolved)  body="$(page '[{"isResolved":"false"}]' false null)" ;;
  esac
  aw_err="$TMP_ROOT/aw-$body_name.err"
  rc=0; out="$(run_aw "$body" 2>"$aw_err")" || rc=$?
  eq "$rc" "1" "$body_name: approval-wait exits 1 rather than counting an unverifiable page"
  eq "$(jq -r .status <<<"$out")" "error" "$body_name: it reports status error"
  grep -Fq "review thread query failed" <<<"$(jq -r '.error // ""' <<<"$out")" \
    && ok "$body_name: the error names the thread query" \
    || bad "$body_name: the error names the thread query" "$out"
  eq "$(jq -r '.transient_api_errors // "null"' <<<"$out")" "null" \
    "$body_name: an empty error file classifies terminal, never transient"
  eq "$(jq -r '.elapsed_seconds < 3' <<<"$out")" "true" \
    "$body_name: it terminates at once rather than retrying to the deadline"
done

printf '\npass: %s   fail: %s\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
