#!/usr/bin/env bash
# `gh_graphql_threads` is the one reviewThreads pager in this skill. pr-data,
# pr-threads and bot_review_status all read threads through it, so the paging
# and the fail-closed rules are proven once, here, against a two-page stub.
#
# Every caller decides whether a PR is clean, so a page that cannot be
# verified must produce no output at all: a partial list read as a complete
# one is an unresolved thread nobody sees.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
LIB="$REPO_ROOT/skills/github/scripts/lib/github-api.sh"
PR_DATA="$REPO_ROOT/skills/github/scripts/commands/pr-data.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }
eq()  { [[ "$1" == "$2" ]] && ok "$3" || bad "$3" "expected: $2  got: $1"; }

mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/repo"
git -C "$TMP_ROOT/repo" init -q

# The stub serves page 1 from STUB_PAGE1 and page 2 from STUB_PAGE2, keyed on
# the cursor the pager sends. STUB_PAGE1 is the whole `data` object, so a case
# can hand back any malformed shape it wants to see refused.
cat >"$TMP_ROOT/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-} ${2:-}" in
    "auth status") echo "Logged in"; exit 0 ;;
    "repo view")   echo '{"owner":{"login":"owner"},"name":"repo"}'; exit 0 ;;
    "api graphql")
        if [[ "$*" == *"cursor=CURSOR2"* ]]; then
            printf '{"data":%s}\n' "${STUB_PAGE2:?}"
        else
            printf '{"data":%s}\n' "${STUB_PAGE1:?}"
        fi
        exit 0
        ;;
esac
printf 'unexpected gh call: %s\n' "$*" >&2
exit 1
EOF
chmod +x "$TMP_ROOT/bin/gh"

page() { # $1 = nodes JSON, $2 = hasNextPage, $3 = endCursor JSON
    jq -cn --argjson nodes "$1" --argjson next "$2" --argjson cur "$3" \
        '{repository:{pullRequest:{reviewThreads:{nodes:$nodes,pageInfo:{hasNextPage:$next,endCursor:$cur}}}}}'
}

P1_NODES='[{"id":"T1","isResolved":false},{"id":"T2","isResolved":true}]'
P2_NODES='[{"id":"T3","isResolved":false}]'

# Call the helper in a subshell with the lib sourced, so a case's environment
# never leaks into the next one.
call() {
    ( set +e
      export PATH="$TMP_ROOT/bin:$PATH"
      cd "$TMP_ROOT/repo" || exit 9
      # shellcheck source=/dev/null
      . "$LIB" >/dev/null 2>&1
      gh_graphql_threads owner repo 7 'id isResolved' 2>/dev/null
      exit $? )
}

echo "=== gh_graphql_threads: two-page walk ==="

STUB_PAGE1="$(page "$P1_NODES" true '"CURSOR2"')"
STUB_PAGE2="$(page "$P2_NODES" false null)"
export STUB_PAGE1 STUB_PAGE2
rc=0; out="$(call)" || rc=$?
eq "$rc" "0" "a complete two-page walk succeeds"
eq "$(jq 'length' <<<"$out")" "3" "both pages' nodes are merged"
eq "$(jq -r '[.[].id] | join(",")' <<<"$out")" "T1,T2,T3" "page order is preserved"

STUB_PAGE1="$(page "$P1_NODES" false null)"
out="$(call)"
eq "$(jq 'length' <<<"$out")" "2" "a single page needs no second call"

STUB_PAGE1="$(page '[]' false null)"
out="$(call)"
eq "$out" "[]" "no threads reads as an empty array, not as a failure"

echo
echo "--- fail-closed: an unverifiable page prints nothing ---"

# Each case is a must-fail control for one rule of the validation: without
# that rule the helper would emit a partial list a caller reads as clean.
fails_closed() { # $1 = case name, $2 = page-1 body
    STUB_PAGE1="$2"
    STUB_PAGE2="$(page "$P2_NODES" false null)"
    local out rc=0
    out="$(call)" || rc=$?
    if [[ "$rc" -ne 0 && -z "$out" ]]; then
        ok "$1"
    else
        bad "$1" "rc=$rc out=$out"
    fi
}

fails_closed "a null reviewThreads is refused" \
    '{"repository":{"pullRequest":{"reviewThreads":null}}}'
fails_closed "nodes that are not an array is refused" \
    '{"repository":{"pullRequest":{"reviewThreads":{"nodes":{},"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}'
fails_closed "a non-boolean hasNextPage is refused" \
    '{"repository":{"pullRequest":{"reviewThreads":{"nodes":[],"pageInfo":{"hasNextPage":"no","endCursor":null}}}}}'
fails_closed "hasNextPage with a null cursor is refused" \
    "$(page "$P1_NODES" true null)"
fails_closed "hasNextPage with an empty cursor is refused" \
    "$(page "$P1_NODES" true '""')"

# A cursor that repeats forever: the walk must stop rather than spin.
STUB_PAGE1="$(page "$P1_NODES" true '"CURSOR2"')"
STUB_PAGE2="$(page "$P2_NODES" true '"CURSOR2"')"
rc=0; out="$(call)" || rc=$?
[[ "$rc" -ne 0 && -z "$out" ]] && ok "a cursor that does not advance is refused" \
  || bad "a cursor that does not advance is refused" "rc=$rc out=$out"

echo
echo "=== pr-data reads its threads through the same pager ==="

STUB_PAGE1="$(page "$P1_NODES" true '"CURSOR2"')"
STUB_PAGE2="$(page "$P2_NODES" false null)"
out="$(PATH="$TMP_ROOT/bin:$PATH" GH_TOKEN=stub bash "$PR_DATA" 7 --format=raw 2>"$TMP_ROOT/pr-data.err")" || true
eq "$(jq '.repository.pullRequest.reviewThreads.nodes | length' <<<"$out")" "3" \
  "pr-data merges both thread pages"
eq "$(jq -r '.repository.pullRequest.reviewThreads.pageInfo.hasNextPage' <<<"$out")" "false" \
  "pr-data reports a complete walk"

# The must-fail control: a second page the pager cannot verify must not let
# pr-data print a PR whose unresolved thread sits on it.
STUB_PAGE2='{"repository":{"pullRequest":{"reviewThreads":null}}}'
rc=0
out="$(PATH="$TMP_ROOT/bin:$PATH" GH_TOKEN=stub bash "$PR_DATA" 7 --format=raw 2>/dev/null)" || rc=$?
[[ "$rc" -ne 0 && -z "$out" ]] && ok "pr-data prints nothing when a later page cannot be verified" \
  || bad "pr-data prints nothing when a later page cannot be verified" "rc=$rc out=$out"

printf '\npass: %s   fail: %s\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
