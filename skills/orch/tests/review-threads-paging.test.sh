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
# STUB_GH_EXIT makes the call itself fail.
cat >"$TMP_ROOT/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
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
fails_closed "hasNextPage with a null cursor is refused" \
  "$(page "$P1" true null)"
fails_closed "hasNextPage with an empty cursor is refused" \
  "$(page "$P1" true '""')"
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
rc=0; out="$(call)" || rc=$?
[[ "$rc" -ne 0 && -z "$out" ]] && ok "a cursor that does not advance is refused" \
  || bad "a cursor that does not advance is refused" "rc=$rc out=$out"

# A cursor that keeps advancing past the page bound: an unbounded walk is not
# a verified one, so the bound is a refusal and never a truncation.
cat >"$TMP_ROOT/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"isResolved":false}],"pageInfo":{"hasNextPage":true,"endCursor":"C%s"}}}}}}\n' "$RANDOM$RANDOM"
EOF
chmod +x "$TMP_ROOT/bin/gh"
rc=0; out="$(call)" || rc=$?
[[ "$rc" -ne 0 && -z "$out" ]] && ok "a walk past the page bound is refused, not truncated" \
  || bad "a walk past the page bound is refused, not truncated" "rc=$rc out=$out"

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

printf '\npass: %s   fail: %s\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
