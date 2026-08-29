#!/usr/bin/env bash
# Coverage for clearing issue estimates (kendex#461):
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
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
ISSUES_SH="$SCRIPT_DIR/../scripts/commands/issues.sh"
assert_tmpdir TMP
export TMP
# Isolate CACHE_DIR resolution (git rev-parse --show-toplevel, from CWD — the
# common.sh PROJECT_ROOT recompute overrides any inherited PROJECT_ROOT env
# var) to this throwaway root. Without this, update_issue's cache
# write-through lands in the real project's `.cache/linear` (kendex#43).
git -C "$TMP" init -q -b main

# Run update_issue with a fully mocked API. The mocked graphql_query captures
# the mutation variables (which carry the built input object) to $1; update_issue
# stdout is discarded and stderr goes to "$1.err". Echoes update_issue's rc.
run_update() {
    local capture="$1"
    shift
    CAPTURE_FILE="$capture" LINEAR_API_KEY_OVERRIDE=test-token \
        bash -uo pipefail -c '
            cd "$TMP"
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
assert_eq "--clear-estimate exits zero" "$rc" 0
assert "--clear-estimate builds estimate: null" \
    jq -e '.input | has("estimate") and .estimate == null' "$cap"

# --- --estimate 0 aliases to clear ----------------------------------------
cap="$TMP/zero.json"
rc="$(run_update "$cap" CC-1 --estimate 0)"
assert_eq "--estimate 0 exits zero" "$rc" 0
assert "--estimate 0 aliases to estimate: null" \
    jq -e '.input | has("estimate") and .estimate == null' "$cap"

# --- --estimate=0 (equals syntax) aliases to clear ------------------------
cap="$TMP/zero-eq.json"
rc="$(run_update "$cap" CC-1 --estimate=0)"
assert_eq "--estimate=0 exits zero" "$rc" 0
assert "--estimate=0 aliases to estimate: null" jq -e '.input.estimate == null' "$cap"

# --- valid 1-5 estimate still passes through ------------------------------
cap="$TMP/three.json"
rc="$(run_update "$cap" CC-1 --estimate 3)"
assert_eq "--estimate 3 exits zero" "$rc" 0
assert "--estimate 3 passes through unchanged" jq -e '.input.estimate == 3' "$cap"

# --- out-of-range / malformed estimates are rejected ----------------------
for bad in 6 -2 2.5 abc; do
    cap="$TMP/bad-$bad.json"
    rc="$(run_update "$cap" CC-1 --estimate "$bad")"
    assert_ne "--estimate $bad is rejected" "$rc" 0
    assert_not "--estimate $bad builds no mutation" test -f "$cap"
    assert_file_contains "--estimate $bad names the invalid value" "$cap.err" "Invalid --estimate"
done

# --- --clear-estimate + --estimate <1-5> is mutually exclusive ------------
cap="$TMP/conflict.json"
rc="$(run_update "$cap" CC-1 --clear-estimate --estimate 3)"
assert_ne "--clear-estimate with --estimate 3 is refused" "$rc" 0
assert_not "--clear-estimate with --estimate 3 builds no mutation" test -f "$cap"
assert_file_contains "the refusal says the two flags are not both allowed" "$cap.err" "not both"

# --- --clear-estimate + --estimate 0 is allowed (both mean clear) ---------
cap="$TMP/both-clear.json"
rc="$(run_update "$cap" CC-1 --clear-estimate --estimate 0)"
assert_eq "--clear-estimate with --estimate 0 exits zero" "$rc" 0
assert "--clear-estimate with --estimate 0 builds estimate: null" \
    jq -e '.input.estimate == null' "$cap"

# --- cache write-through reflects the cleared value -----------------------
cache_dir="$TMP/cache"
mkdir -p "$cache_dir"
printf '%s' '[{"id":"uuid-1","identifier":"CC-1","title":"t","estimate":3,"state":{"name":"Todo","type":"unstarted"},"relations":{"nodes":[]},"inverseRelations":{"nodes":[]}}]' >"$cache_dir/issues.json"
LINEAR_API_KEY_OVERRIDE=test-token \
    bash -uo pipefail -c '
        cd "$TMP"
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
assert "the cache write-through stores the cleared estimate as null, not a stale 3" \
    jq -e '.[] | select(.id == "uuid-1") | .estimate == null' "$cache_dir/issues.json"

# --- bulk-update forwards --clear-estimate to the mutation ----------------
cap="$TMP/bulk-clear.json"
out="$(
    CAPTURE_FILE="$cap" LINEAR_API_KEY_OVERRIDE=test-token \
        bash -uo pipefail -c '
            cd "$TMP"
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
assert_jq "bulk-update --clear-estimate reports one update" "$out" '.updated == 1'
assert "bulk-update forwards --clear-estimate as estimate: null" \
    jq -e '.input.estimate == null' "$cap"

# --- bulk-update rejects an out-of-range estimate per item ----------------
out="$(
    LINEAR_API_KEY_OVERRIDE=test-token \
        bash -uo pipefail -c '
            cd "$TMP"
            issues_sh="$1"
            # shellcheck disable=SC1090
            source "$issues_sh"
            get_issue() { printf "%s" "{\"issue\":{\"team\":{\"name\":\"Test\"}}}"; }
            attach_download_from_text() { :; }
            graphql_query() { printf "%s" "{\"issueUpdate\":{\"success\":true,\"issue\":{}}}"; }
            bulk_update_issues CC-1 --estimate 6
        ' _ "$ISSUES_SH" 2>/dev/null
)"
assert_jq "bulk-update reports an out-of-range estimate as a failed item" \
    "$out" '.failed == 1 and (.results[0].error | contains("Invalid --estimate"))' 
