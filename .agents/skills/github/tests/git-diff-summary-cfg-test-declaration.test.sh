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

# run_case NAME DECLARATION FLAG SCOPE [CANDIDATE_PATH]
# CANDIDATE_PATH defaults to src/candidate.rs; the directory form of a bare
# declaration needs src/candidate/mod.rs instead.
run_case() {
    local name="$1" declaration="$2" expected_flag="$3" expected_scope="$4"
    local candidate="${5:-src/candidate.rs}"
    local repo="$SANDBOX/$name" result

    mkdir -p "$repo/src" "$repo/${candidate%/*}"
    git -C "$repo" init -q -b main
    git -C "$repo" config user.email test@example.com
    git -C "$repo" config user.name test
    git -C "$repo" config commit.gpgsign false
    printf '%s\n' "$declaration" >"$repo/src/lib.rs"
    git -C "$repo" add src/lib.rs
    git -C "$repo" commit -q -m declaration

    cat >"$repo/$candidate" <<'RUST'
pub fn parse(value: &str) -> u32 {
    value.parse().unwrap()
}
RUST
    git -C "$repo" add "$candidate"
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

# The gate need not be the last attribute: a run of column-zero outer
# attributes carries it to the declaration. crates/core has two files written
# this way (engine/desired/hold.rs, quality/rules/content/fetch/tokens.rs).
run_case attribute-run \
    $'#[cfg(test)]\n#[allow(clippy::unwrap_used)]\nmod candidate;' \
    test_panic_path_added support

# The gate need not lead the run: it is read wherever it sits in it. The
# TRAILING attribute is what makes this discriminating — it is the line the
# attribute-carry rule has to carry a pending gate across. With the gate
# leading instead, there is no gate yet to carry and the case proves nothing.
run_case attribute-run-gate-sandwiched \
    $'#[allow(dead_code)]\n#[cfg(test)]\n#[allow(unused)]\nmod candidate;' \
    test_panic_path_added support

# pub and pub(...) declarations are read, and a bare declaration resolves to
# the directory form as well as the file form.
run_case gated-pub \
    $'#[cfg(test)]\npub mod candidate;' \
    test_panic_path_added support

run_case gated-pub-crate \
    $'#[cfg(test)]\npub(crate) mod candidate;' \
    test_panic_path_added support

run_case gated-dir-form \
    $'#[cfg(test)]\nmod candidate;' \
    test_panic_path_added support \
    src/candidate/mod.rs

run_case ungated-bare \
    'mod candidate;' \
    panic_path_added production

run_case gated-and-ungated \
    $'#[cfg(test)]\n#[path = "candidate.rs"]\nmod candidate_test;\nmod candidate;' \
    panic_path_added production

# An attribute binds to the next line only: a #[cfg(test)] left behind on an
# unrelated item must not gate the declaration further down the file.
run_case stale-gate \
    $'#[cfg(test)]\nfn helper() {}\n\nmod candidate;' \
    panic_path_added production

# The scan is line-based: a declaration written flush left inside a block
# comment is read as a real one. Documented in DEVELOPMENT.md and the
# git-diff-summary header; pinned here so the claim reds if it stops holding.
run_case commented-out \
    $'/*\n#[cfg(test)]\nmod candidate;\n*/' \
    test_panic_path_added support

run_case no-declaration \
    $'pub fn unrelated() -> u32 {\n    1\n}' \
    panic_path_added production

# Nested: the gate sits in an ancestor directory's module, reached through a
# #[path] that walks down into the candidate's directory.
nested="$SANDBOX/nested"
mkdir -p "$nested/src/inner"
git -C "$nested" init -q -b main
git -C "$nested" config user.email test@example.com
git -C "$nested" config user.name test
git -C "$nested" config commit.gpgsign false
printf '%s\n' $'#[cfg(test)]\n#[path = "inner/candidate.rs"]\nmod candidate_test;' >"$nested/src/lib.rs"
git -C "$nested" add src/lib.rs
git -C "$nested" commit -q -m declaration
cat >"$nested/src/inner/candidate.rs" <<'RUST'
pub fn parse(value: &str) -> u32 {
    value.parse().unwrap()
}
RUST
git -C "$nested" add src/inner/candidate.rs
nested_result="$($SUMMARY -C "$nested" --staged)"
assert_eq "nested risk flag" '["test_panic_path_added"]' \
    "$(jq -c '.risk_flags' <<<"$nested_result")"
assert_eq "nested scope" "support" "$(jq -r '.scope' <<<"$nested_result")"

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
