#!/usr/bin/env bash
# Regression tests for pr-threads resolution filters in --format=raw.
#
# The raw branch echoed the GraphQL result unfiltered, so
# `--unresolved --format=raw` returned resolved threads and a verification
# workflow counting raw nodes read "all resolved" as "nothing resolved".
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
PR_THREADS="$REPO_ROOT/skills/github/scripts/commands/pr-threads.sh"
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

mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/repo"
git -C "$TMP_ROOT/repo" init -q

# The shared `gh` fake. Auth and repo answers are seeded; the GraphQL pages
# are staged per run below. The stub ships beside this test in both the source
# package and its render.
# shellcheck source=lib/gh-stub.sh
. "$TEST_DIR/lib/gh-stub.sh"
GH_STUB_DIR="$TMP_ROOT/gh-stub" gh_stub_install "$TMP_ROOT/bin"

# Shim jq to record every program it is handed, then run the real one. Raw
# output must reach the caller as the API returned it, so the unfiltered path
# has to skip the filter pass rather than re-serialize through it.
REAL_JQ="$(command -v jq)"
jq_log="$TMP_ROOT/jq-programs.log"
cat >"$TMP_ROOT/bin/jq" <<EOF
#!/usr/bin/env bash
if [ -n "\${STUB_JQ_LOG:-}" ]; then
    printf '%s\n' "\$*" >>"\$STUB_JQ_LOG"
fi
exec "$REAL_JQ" "\$@"
EOF
chmod +x "$TMP_ROOT/bin/jq"

mk_thread() { # id isResolved
    jq -cn --arg id "$1" --argjson resolved "$2" \
        '{id:$id,isResolved:$resolved,isOutdated:false,path:"src/lib.rs",line:7,
          comments:{nodes:[{author:{login:"reviewer"},body:"note"}]}}'
}

threads=$(jq -sc '.' \
    <(mk_thread PRRT_done_a true) \
    <(mk_thread PRRT_done_b true) \
    <(mk_thread PRRT_open false))

# page BODY HAS_NEXT CURSOR — one GraphQL thread page, built with the real
# jq so the "byte for byte" assertion below compares like with like.
page() {
    "$REAL_JQ" -cn --argjson nodes "$1" --argjson next "$2" --arg cursor "$3" \
        '{data:{repository:{pullRequest:{reviewThreads:{nodes:$nodes,
          pageInfo:{hasNextPage:$next,endCursor:(if $cursor == "" then null else $cursor end)}}}}}}'
}

# Page two is keyed on the cursor appearing in the call's argv, not on the
# call being the second one: a code path that stopped sending the cursor
# would otherwise still be handed page two and the merge would look right.
run_threads() {
    : >"$jq_log"
    gh_stub_reset
    if [ -n "$page2" ]; then
        gh_stub_answer api-graphql "$(page "$threads" true cursor-page-2)"
        gh_stub_answer 'api-graphql:cursor=cursor-page-2' "$(page "$page2" false '')"
    else
        gh_stub_answer api-graphql "$(page "$threads" false '')"
    fi
    (cd "$TMP_ROOT/repo" && PATH="$TMP_ROOT/bin:$PATH" env -u GH_TOKEN -u GITHUB_TOKEN \
        STUB_JQ_LOG="$jq_log" \
        "$PR_THREADS" 123 "$@")
}

filter_passes() { # count jq runs that rewrite the thread node array
    grep -c -- 'reviewThreads.nodes |=' "$jq_log" || true
}

page2=""

echo "=== pr-threads --format=raw honors the resolution filters ==="

out=$(run_threads --unresolved --format=raw)
assert_eq "$(jq '.repository.pullRequest.reviewThreads.nodes | length' <<<"$out")" "1" \
    "raw --unresolved returns only the unresolved node"
assert_eq "$(jq '[.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == true)] | length' <<<"$out")" "0" \
    "raw --unresolved emits no resolved node"
assert_eq "$(jq -r '.repository.pullRequest.reviewThreads.nodes[0].id' <<<"$out")" "PRRT_open" \
    "raw --unresolved keeps the matching thread's id"

out=$(run_threads --resolved --format=raw)
assert_eq "$(jq '.repository.pullRequest.reviewThreads.nodes | length' <<<"$out")" "2" \
    "raw --resolved returns only resolved nodes"
assert_eq "$(jq '[.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false)] | length' <<<"$out")" "0" \
    "raw --resolved emits no unresolved node"

assert_eq "$(filter_passes)" "1" "raw --resolved runs exactly one filter pass"

out=$(run_threads --format=raw)
assert_eq "$(jq '.repository.pullRequest.reviewThreads.nodes | length' <<<"$out")" "3" \
    "raw without a filter still returns every thread"
assert_eq "$out" \
    "$("$REAL_JQ" -cn --argjson nodes "$threads" \
        '{repository:{pullRequest:{reviewThreads:{nodes:$nodes,pageInfo:{hasNextPage:false,endCursor:null}}}}}')" \
    "unfiltered raw is the API payload byte for byte"
assert_eq "$(filter_passes)" "0" "unfiltered raw is never re-serialized through a filter pass"

echo
echo "=== raw structure is preserved for callers that walk it ==="

out=$(run_threads --unresolved --format=raw)
assert_eq "$(jq '[.. | objects | select(has("isResolved"))] | length' <<<"$out")" "1" \
    "raw --unresolved counts one thread through the generic object walk"
assert_eq "$(jq -r '.repository.pullRequest.reviewThreads.pageInfo.hasNextPage' <<<"$out")" "false" \
    "raw --unresolved keeps the pageInfo envelope"
assert_eq "$(jq -r '.repository.pullRequest.reviewThreads.nodes[0].comments.nodes[0].author.login' <<<"$out")" "reviewer" \
    "raw --unresolved keeps the untouched GitHub node shape"

echo
echo "=== the filter applies across every fetched page ==="

page2=$(jq -sc '.' <(mk_thread PRRT_page2_open false) <(mk_thread PRRT_page2_done true))
out=$(run_threads --unresolved --format=raw)
assert_eq "$(jq '.repository.pullRequest.reviewThreads.nodes | length' <<<"$out")" "2" \
    "raw --unresolved filters the merged multi-page node list"
assert_eq "$(jq -r '[.repository.pullRequest.reviewThreads.nodes[].id] | sort | join(",")' <<<"$out")" \
    "PRRT_open,PRRT_page2_open" \
    "raw --unresolved keeps unresolved threads from both pages"
assert_eq "$(jq -r '.repository.pullRequest.reviewThreads.pageInfo.hasNextPage' <<<"$out")" "false" \
    "raw pagination stays complete after filtering"
page2=""

echo
echo "=== safe format counts are unchanged ==="

out=$(run_threads --unresolved)
assert_eq "$(jq '.count' <<<"$out")" "1" "safe --unresolved counts the filtered set"
assert_eq "$(jq '.unresolved_count' <<<"$out")" "1" "safe --unresolved reports the PR's unresolved total"
assert_eq "$(jq '.threads | length' <<<"$out")" "1" "safe --unresolved lists only unresolved threads"

out=$(run_threads --resolved)
assert_eq "$(jq '.count' <<<"$out")" "2" "safe --resolved counts the filtered set"
assert_eq "$(jq '.unresolved_count' <<<"$out")" "1" "safe --resolved still reports the PR's unresolved total"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
