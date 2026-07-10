#!/usr/bin/env bash
# Coverage for clearing issue estimates (vstack#461):
#   - `--clear-estimate` builds an `estimate: null` mutation input
#   - `--estimate 0` is a compatibility alias for clearing (maps 0 -> null)
#   - real estimates 1-5 still pass through; 6+/negative/non-int are rejected
#   - `--clear-estimate` + `--estimate <1-5>` together is a hard error
#   - the local cache write-through reflects the cleared (null) value
#   - `bulk-update` forwards --clear-estimate / --estimate 0 to the mutation
#
# Self-contained: the Linear API is fully mocked, no network calls.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ISSUES_SH="$SCRIPT_DIR/../scripts/commands/issues.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
pass() { echo "PASS $*"; }
fail() {
    echo "FAIL $*"
    fails=$((fails + 1))
}

# Run update_issue with a fully mocked API. The mocked graphql_query captures
# the mutation variables (which carry the built input object) to $1; update_issue
# stdout is discarded and stderr goes to "$1.err". Echoes update_issue's rc.
run_update() {
    local capture="$1"
    shift
    CAPTURE_FILE="$capture" LINEAR_API_KEY=test-token \
        bash -uo pipefail -c '
            capture="$CAPTURE_FILE"
            issues_sh="$1"
            shift
            # shellcheck disable=SC1090
            source "$issues_sh"
            get_issue() { printf "%s" "{\"issue\":{\"team\":{\"name\":\"Test\"}}}"; }
            attach_download_from_text() { :; }
            graphql_query() {
                printf "%s" "$2" >"$capture"
                printf "%s" "{\"issueUpdate\":{\"success\":true,\"issue\":{\"id\":\"uuid-1\",\"identifier\":\"CC-1\",\"title\":\"t\",\"estimate\":null,\"state\":{\"name\":\"Todo\",\"type\":\"unstarted\"}}}}"
            }
            update_issue "$@"
        ' _ "$ISSUES_SH" "$@" >/dev/null 2>"$capture.err"
    echo "$?"
}

# --- --clear-estimate builds estimate: null -------------------------------
cap="$TMP/clear.json"
rc="$(run_update "$cap" CC-1 --clear-estimate)"
if [ "$rc" -eq 0 ] && jq -e '.input | has("estimate") and .estimate == null' "$cap" >/dev/null 2>&1; then
    pass "--clear-estimate -> estimate: null"
else
    fail "--clear-estimate (rc=$rc, input=$(cat "$cap" 2>/dev/null))"
fi

# --- --estimate 0 aliases to clear ----------------------------------------
cap="$TMP/zero.json"
rc="$(run_update "$cap" CC-1 --estimate 0)"
if [ "$rc" -eq 0 ] && jq -e '.input | has("estimate") and .estimate == null' "$cap" >/dev/null 2>&1; then
    pass "--estimate 0 -> estimate: null"
else
    fail "--estimate 0 (rc=$rc, input=$(cat "$cap" 2>/dev/null))"
fi

# --- --estimate=0 (equals syntax) aliases to clear ------------------------
cap="$TMP/zero-eq.json"
rc="$(run_update "$cap" CC-1 --estimate=0)"
if [ "$rc" -eq 0 ] && jq -e '.input.estimate == null' "$cap" >/dev/null 2>&1; then
    pass "--estimate=0 -> estimate: null"
else
    fail "--estimate=0 (rc=$rc, input=$(cat "$cap" 2>/dev/null))"
fi

# --- valid 1-5 estimate still passes through ------------------------------
cap="$TMP/three.json"
rc="$(run_update "$cap" CC-1 --estimate 3)"
if [ "$rc" -eq 0 ] && jq -e '.input.estimate == 3' "$cap" >/dev/null 2>&1; then
    pass "--estimate 3 -> estimate: 3"
else
    fail "--estimate 3 (rc=$rc, input=$(cat "$cap" 2>/dev/null))"
fi

# --- out-of-range / malformed estimates are rejected ----------------------
for bad in 6 -2 2.5 abc; do
    cap="$TMP/bad-$bad.json"
    rc="$(run_update "$cap" CC-1 --estimate "$bad")"
    if [ "$rc" -ne 0 ] && [ ! -f "$cap" ] && grep -q "Invalid --estimate" "$cap.err" 2>/dev/null; then
        pass "--estimate $bad rejected (no mutation built)"
    else
        fail "--estimate $bad should be rejected (rc=$rc, err=$(cat "$cap.err" 2>/dev/null))"
    fi
done

# --- --clear-estimate + --estimate <1-5> is mutually exclusive ------------
cap="$TMP/conflict.json"
rc="$(run_update "$cap" CC-1 --clear-estimate --estimate 3)"
if [ "$rc" -ne 0 ] && [ ! -f "$cap" ] && grep -q "not both" "$cap.err" 2>/dev/null; then
    pass "--clear-estimate + --estimate 3 errors"
else
    fail "--clear-estimate + --estimate 3 should error (rc=$rc, err=$(cat "$cap.err" 2>/dev/null))"
fi

# --- --clear-estimate + --estimate 0 is allowed (both mean clear) ---------
cap="$TMP/both-clear.json"
rc="$(run_update "$cap" CC-1 --clear-estimate --estimate 0)"
if [ "$rc" -eq 0 ] && jq -e '.input.estimate == null' "$cap" >/dev/null 2>&1; then
    pass "--clear-estimate + --estimate 0 -> estimate: null"
else
    fail "--clear-estimate + --estimate 0 (rc=$rc, input=$(cat "$cap" 2>/dev/null))"
fi

# --- cache write-through reflects the cleared value -----------------------
cache_dir="$TMP/cache"
mkdir -p "$cache_dir"
printf '%s' '[{"id":"uuid-1","identifier":"CC-1","title":"t","estimate":3,"state":{"name":"Todo","type":"unstarted"},"relations":{"nodes":[]},"inverseRelations":{"nodes":[]}}]' >"$cache_dir/issues.json"
LINEAR_API_KEY=test-token \
    bash -uo pipefail -c '
        issues_sh="$1"
        cache_dir="$2"
        # shellcheck disable=SC1090
        source "$issues_sh"
        # cache.sh fixes CACHE_DIR at source time; point it at the test cache.
        CACHE_DIR="$cache_dir"
        get_issue() { printf "%s" "{\"issue\":{\"team\":{\"name\":\"Test\"}}}"; }
        attach_download_from_text() { :; }
        graphql_query() {
            printf "%s" "{\"issueUpdate\":{\"success\":true,\"issue\":{\"id\":\"uuid-1\",\"identifier\":\"CC-1\",\"title\":\"t\",\"estimate\":null,\"state\":{\"name\":\"Todo\",\"type\":\"unstarted\"},\"relations\":{\"nodes\":[]},\"inverseRelations\":{\"nodes\":[]}}}}"
        }
        update_issue CC-1 --clear-estimate
    ' _ "$ISSUES_SH" "$cache_dir" >/dev/null 2>&1
if jq -e '.[] | select(.id == "uuid-1") | .estimate == null' "$cache_dir/issues.json" >/dev/null 2>&1; then
    pass "cache write-through stores cleared estimate as null (not stale 3)"
else
    fail "cache still holds stale estimate: $(jq -c '.[] | {id, estimate}' "$cache_dir/issues.json" 2>/dev/null)"
fi

# --- bulk-update forwards --clear-estimate to the mutation ----------------
cap="$TMP/bulk-clear.json"
out="$(
    CAPTURE_FILE="$cap" LINEAR_API_KEY=test-token \
        bash -uo pipefail -c '
            capture="$CAPTURE_FILE"
            issues_sh="$1"
            # shellcheck disable=SC1090
            source "$issues_sh"
            get_issue() { printf "%s" "{\"issue\":{\"team\":{\"name\":\"Test\"}}}"; }
            attach_download_from_text() { :; }
            graphql_query() {
                printf "%s" "$2" >"$capture"
                printf "%s" "{\"issueUpdate\":{\"success\":true,\"issue\":{\"id\":\"uuid-1\",\"identifier\":\"CC-1\",\"title\":\"t\",\"estimate\":null,\"state\":{\"name\":\"Todo\",\"type\":\"unstarted\"}}}}"
            }
            bulk_update_issues CC-1 --clear-estimate
        ' _ "$ISSUES_SH" 2>/dev/null
)"
if jq -e '.updated == 1' <<<"$out" >/dev/null 2>&1 && jq -e '.input.estimate == null' "$cap" >/dev/null 2>&1; then
    pass "bulk-update --clear-estimate -> estimate: null"
else
    fail "bulk-update --clear-estimate (out=$out, input=$(cat "$cap" 2>/dev/null))"
fi

# --- bulk-update rejects an out-of-range estimate per item ----------------
out="$(
    LINEAR_API_KEY=test-token \
        bash -uo pipefail -c '
            issues_sh="$1"
            # shellcheck disable=SC1090
            source "$issues_sh"
            get_issue() { printf "%s" "{\"issue\":{\"team\":{\"name\":\"Test\"}}}"; }
            attach_download_from_text() { :; }
            graphql_query() { printf "%s" "{\"issueUpdate\":{\"success\":true,\"issue\":{}}}"; }
            bulk_update_issues CC-1 --estimate 6
        ' _ "$ISSUES_SH" 2>/dev/null
)"
if jq -e '.failed == 1 and (.results[0].error | contains("Invalid --estimate"))' <<<"$out" >/dev/null 2>&1; then
    pass "bulk-update --estimate 6 reported as failed"
else
    fail "bulk-update --estimate 6 (out=$out)"
fi

if [ "$fails" -ne 0 ]; then
    echo "$fails test(s) failed"
    exit 1
fi
echo "all pass"
