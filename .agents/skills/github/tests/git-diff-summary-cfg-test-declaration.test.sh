#!/usr/bin/env bash
# Without a test path, name, or file-local marker, every declaration route
# must be cfg(test)-gated for a Rust file to have test scope.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$TEST_DIR" rev-parse --show-toplevel)"
SUMMARY="$TEST_DIR/../scripts/git-diff-summary"
mkdir -p "$REPO_ROOT/tmp"
SANDBOX="$(mktemp -d "$REPO_ROOT/tmp/git-diff-summary-cfg.XXXXXX")"
PASS=0
FAIL=0

trap 'rm -rf -- "$SANDBOX"' EXIT

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        printf '  PASS: %s\n' "$label"
        PASS=$((PASS + 1))
    else
        printf '  FAIL: %s\n    expected: %s\n    actual:   %s\n' \
            "$label" "$expected" "$actual" >&2
        FAIL=$((FAIL + 1))
    fi
}

run_case() {
    local name="$1" declaration="$2" expected_flag="$3" expected_scope="$4"
    local repo="$SANDBOX/$name" result

    mkdir -p "$repo/src"
    git -C "$repo" init -q -b main
    git -C "$repo" config user.email test@example.com
    git -C "$repo" config user.name test
    git -C "$repo" config commit.gpgsign false
    printf '%s\n' "$declaration" >"$repo/src/lib.rs"
    git -C "$repo" add src/lib.rs
    git -C "$repo" commit -q -m declaration

    cat >"$repo/src/candidate.rs" <<'RUST'
pub fn parse(value: &str) -> u32 {
    value.parse().unwrap()
}
RUST
    git -C "$repo" add src/candidate.rs
    result="$($SUMMARY -C "$repo" --staged)"

    assert_eq "$name risk flag" "[\"$expected_flag\"]" \
        "$(jq -c '.risk_flags' <<<"$result")"
    assert_eq "$name scope" "$expected_scope" \
        "$(jq -r '.scope' <<<"$result")"
}

run_case gated-path \
    $'#[cfg(test)]\n#[path = "candidate.rs"]\nmod candidate_test;' \
    test_panic_path_added support

run_case gated-bare \
    $'#[cfg(test)]\nmod candidate;' \
    test_panic_path_added support

run_case ungated-bare \
    'mod candidate;' \
    panic_path_added production

run_case gated-and-ungated \
    $'#[cfg(test)]\n#[path = "candidate.rs"]\nmod candidate_test;\nmod candidate;' \
    panic_path_added production

run_case no-declaration \
    $'pub fn unrelated() -> u32 {\n    1\n}' \
    panic_path_added production

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
