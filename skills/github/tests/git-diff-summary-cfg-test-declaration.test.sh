#!/usr/bin/env bash
# vstack#1217: a .rs file with no file-local test markers is still test scope
# when its gate lives at the declaration site in the declaring module:
#
#     #[cfg(test)]
#     #[path = "scan_fixtures.rs"]
#     mod scan_fixtures;
#
# File-local heuristics (tests/ dirs, *_tests.rs, in-file #[cfg(test)]) cannot
# see that, so the classifier reads the declaring module on the diff's new
# side: a file whose every found declaration is #[cfg(test)]-gated classifies
# as test (test_panic_path_added, support scope); any ungated declaration, or
# none found, keeps production classification.
#
# Run: bash skills/github/tests/git-diff-summary-cfg-test-declaration.test.sh
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
SUMMARY="$REPO_ROOT/skills/github/scripts/git-diff-summary"

SANDBOX="$(mktemp -d -t gh-diff-summary-cfgdecl-XXXXXX)"
PASS=0
FAIL=0

cleanup() { rm -rf "$SANDBOX" 2>/dev/null || true; }
trap cleanup EXIT

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        printf '  PASS: %s\n' "$label"
        PASS=$((PASS + 1))
    else
        printf '  FAIL: %s\n    expected: %s\n    actual:   %s\n' "$label" "$expected" "$actual" >&2
        FAIL=$((FAIL + 1))
    fi
}

init_repo() {
    local repo="$1"
    mkdir -p "$repo"
    git -C "$repo" init -q -b main
    git -C "$repo" config user.email test@example.com
    git -C "$repo" config user.name test
    git -C "$repo" config commit.gpgsign false
    printf 'base\n' > "$repo/README.md"
    git -C "$repo" add README.md
    git -C "$repo" commit -q -m init
}

# The reported shape: #[cfg(test)]-gated #[path] sibling (D010 shared-fixture
# pattern). The declaring mod.rs is committed at base; only the fixture file
# is in the diff.
path_sibling_repo="$SANDBOX/path-sibling"
init_repo "$path_sibling_repo"
mkdir -p "$path_sibling_repo/src/module_scan"
cat > "$path_sibling_repo/src/module_scan/mod.rs" <<'RUST'
pub fn scan() -> u32 {
    1
}

#[cfg(test)]
#[path = "scan_fixtures.rs"]
mod scan_fixtures;
RUST
git -C "$path_sibling_repo" add src
git -C "$path_sibling_repo" commit -q -m modules
cat > "$path_sibling_repo/src/module_scan/scan_fixtures.rs" <<'RUST'
pub fn fixture() -> u32 {
    let v: u32 = "7".parse().unwrap();
    if v == 0 {
        panic!("unreachable");
    }
    v
}
RUST
git -C "$path_sibling_repo" add src/module_scan/scan_fixtures.rs
path_sibling_json="$($SUMMARY -C "$path_sibling_repo" --staged)"
assert_eq "cfg(test)-gated #[path] sibling panic classifies as test_panic_path_added" \
    '["test_panic_path_added"]' "$(jq -c '.risk_flags' <<<"$path_sibling_json")"
assert_eq "cfg(test)-gated #[path] sibling is not production scope" \
    "support" "$(jq -r '.scope' <<<"$path_sibling_json")"

# Bare `#[cfg(test)] mod name;` gate (no #[path]) from a declaring lib.rs.
bare_mod_repo="$SANDBOX/bare-mod"
init_repo "$bare_mod_repo"
mkdir -p "$bare_mod_repo/src"
cat > "$bare_mod_repo/src/lib.rs" <<'RUST'
pub fn add(a: u32, b: u32) -> u32 {
    a + b
}

#[cfg(test)] mod helpers;
RUST
git -C "$bare_mod_repo" add src
git -C "$bare_mod_repo" commit -q -m lib
cat > "$bare_mod_repo/src/helpers.rs" <<'RUST'
pub fn sample() -> u32 {
    "3".parse().unwrap()
}
RUST
git -C "$bare_mod_repo" add src/helpers.rs
bare_mod_json="$($SUMMARY -C "$bare_mod_repo" --staged)"
assert_eq "cfg(test)-gated bare mod sibling panic classifies as test_panic_path_added" \
    '["test_panic_path_added"]' "$(jq -c '.risk_flags' <<<"$bare_mod_json")"
assert_eq "cfg(test)-gated bare mod sibling is not production scope" \
    "support" "$(jq -r '.scope' <<<"$bare_mod_json")"

# Control: an ungated declaration keeps production classification — the
# declaration-site check must not over-classify.
ungated_repo="$SANDBOX/ungated"
init_repo "$ungated_repo"
mkdir -p "$ungated_repo/src"
cat > "$ungated_repo/src/lib.rs" <<'RUST'
pub mod util;
RUST
git -C "$ungated_repo" add src
git -C "$ungated_repo" commit -q -m lib
cat > "$ungated_repo/src/util.rs" <<'RUST'
pub fn parse(s: &str) -> u32 {
    s.parse().unwrap()
}
RUST
git -C "$ungated_repo" add src/util.rs
ungated_json="$($SUMMARY -C "$ungated_repo" --staged)"
assert_eq "ungated mod sibling keeps panic_path_added" \
    '["panic_path_added"]' "$(jq -c '.risk_flags' <<<"$ungated_json")"
assert_eq "ungated mod sibling stays production scope" \
    "production" "$(jq -r '.scope' <<<"$ungated_json")"

# Control: a file reachable both through a gated #[path] declaration and an
# ungated one is production — any ungated route wins.
dual_repo="$SANDBOX/dual"
init_repo "$dual_repo"
mkdir -p "$dual_repo/src"
cat > "$dual_repo/src/lib.rs" <<'RUST'
pub mod shared;

#[cfg(test)]
#[path = "shared.rs"]
mod shared_fixtures;
RUST
git -C "$dual_repo" add src
git -C "$dual_repo" commit -q -m lib
cat > "$dual_repo/src/shared.rs" <<'RUST'
pub fn parse(s: &str) -> u32 {
    s.parse().unwrap()
}
RUST
git -C "$dual_repo" add src/shared.rs
dual_json="$($SUMMARY -C "$dual_repo" --staged)"
assert_eq "gated + ungated dual declaration stays panic_path_added" \
    '["panic_path_added"]' "$(jq -c '.risk_flags' <<<"$dual_json")"
assert_eq "gated + ungated dual declaration stays production scope" \
    "production" "$(jq -r '.scope' <<<"$dual_json")"

# The base...HEAD diff path resolves declaring modules from HEAD, not the
# index or worktree.
branch_repo="$SANDBOX/branch"
init_repo "$branch_repo"
mkdir -p "$branch_repo/src/module_scan"
cat > "$branch_repo/src/module_scan/mod.rs" <<'RUST'
pub fn scan() -> u32 {
    1
}

#[cfg(test)]
#[path = "scan_fixtures.rs"]
mod scan_fixtures;
RUST
git -C "$branch_repo" add src
git -C "$branch_repo" commit -q -m modules
git -C "$branch_repo" checkout -q -b feature
cat > "$branch_repo/src/module_scan/scan_fixtures.rs" <<'RUST'
pub fn fixture() -> u32 {
    "7".parse().unwrap()
}
RUST
git -C "$branch_repo" add src/module_scan/scan_fixtures.rs
git -C "$branch_repo" commit -q -m fixtures
branch_json="$($SUMMARY -C "$branch_repo" main)"
assert_eq "committed gated #[path] sibling classifies as test_panic_path_added" \
    '["test_panic_path_added"]' "$(jq -c '.risk_flags' <<<"$branch_json")"
assert_eq "committed gated #[path] sibling is not production scope" \
    "support" "$(jq -r '.scope' <<<"$branch_json")"

printf '\nPASS=%d FAIL=%d\n' "$PASS" "$FAIL"
if [ "$FAIL" -ne 0 ]; then exit 1; fi
