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

# Stub gh: auth passes, repo resolves, GraphQL serves one or two thread pages.
cat >"$TMP_ROOT/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-} ${2:-}" in
    "auth status")
        echo "Logged in"
        exit 0
        ;;
    "repo view")
        echo '{"owner":{"login":"owner"},"name":"repo"}'
        exit 0
        ;;
    "api graphql")
        if [[ "$*" == *"cursor=cursor-page-2"* ]]; then
            jq -cn --argjson nodes "${STUB_THREADS_PAGE2_JSON:-[]}" \
                '{data:{repository:{pullRequest:{reviewThreads:{nodes:$nodes,pageInfo:{hasNextPage:false,endCursor:null}}}}}}'
            exit 0
        fi
        if [[ -n "${STUB_THREADS_PAGE2_JSON:-}" ]]; then
            jq -cn --argjson nodes "${STUB_THREADS_JSON:-[]}" \
                '{data:{repository:{pullRequest:{reviewThreads:{nodes:$nodes,pageInfo:{hasNextPage:true,endCursor:"cursor-page-2"}}}}}}'
            exit 0
        fi
        jq -cn --argjson nodes "${STUB_THREADS_JSON:-[]}" \
            '{data:{repository:{pullRequest:{reviewThreads:{nodes:$nodes,pageInfo:{hasNextPage:false,endCursor:null}}}}}}'
        exit 0
        ;;
esac

printf 'unexpected gh call: %s\n' "$*" >&2
exit 1
EOF
chmod +x "$TMP_ROOT/bin/gh"

mk_thread() { # id isResolved
    jq -cn --arg id "$1" --argjson resolved "$2" \
        '{id:$id,isResolved:$resolved,isOutdated:false,path:"src/lib.rs",line:7,
          comments:{nodes:[{author:{login:"reviewer"},body:"note"}]}}'
}

threads=$(jq -sc '.' \
    <(mk_thread PRRT_done_a true) \
    <(mk_thread PRRT_done_b true) \
    <(mk_thread PRRT_open false))

run_threads() {
    (cd "$TMP_ROOT/repo" && PATH="$TMP_ROOT/bin:$PATH" env -u GH_TOKEN -u GITHUB_TOKEN \
        STUB_THREADS_JSON="$threads" "${STUB_PAGE2_ENV[@]+"${STUB_PAGE2_ENV[@]}"}" \
        "$PR_THREADS" 123 "$@")
}

STUB_PAGE2_ENV=()

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

out=$(run_threads --format=raw)
assert_eq "$(jq '.repository.pullRequest.reviewThreads.nodes | length' <<<"$out")" "3" \
    "raw without a filter still returns every thread"

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
STUB_PAGE2_ENV=(STUB_THREADS_PAGE2_JSON="$page2")
out=$(run_threads --unresolved --format=raw)
assert_eq "$(jq '.repository.pullRequest.reviewThreads.nodes | length' <<<"$out")" "2" \
    "raw --unresolved filters the merged multi-page node list"
assert_eq "$(jq -r '[.repository.pullRequest.reviewThreads.nodes[].id] | sort | join(",")' <<<"$out")" \
    "PRRT_open,PRRT_page2_open" \
    "raw --unresolved keeps unresolved threads from both pages"
assert_eq "$(jq -r '.repository.pullRequest.reviewThreads.pageInfo.hasNextPage' <<<"$out")" "false" \
    "raw pagination stays complete after filtering"
STUB_PAGE2_ENV=()

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
