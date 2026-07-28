#!/usr/bin/env bash
# vstack#328: git-diff-summary Rust-specific risk flags must only scan
# Rust diffs. Non-Rust docs/scripts that mention unsafe/repr(C)/extern C/Atomic
# are descriptive text, not Rust code risk.
#
# vstack#944: panic patterns whose enclosing context is a test surface
# (#[cfg(test)] modules, tests/ dirs, *_tests.rs) classify as the distinct
# informational `test_panic_path_added` flag, never `panic_path_added` — a
# test assertion is not a production panic path. Production panic paths keep
# the existing flag.
#
# Run: bash skills/github/tests/git-diff-summary-risk-flags.test.sh
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
SUMMARY="$REPO_ROOT/skills/github/scripts/git-diff-summary"

SANDBOX="$(mktemp -d -t gh-diff-summary-risk-XXXXXX)"
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

non_rust_repo="$SANDBOX/non-rust"
init_repo "$non_rust_repo"
mkdir -p "$non_rust_repo/tools" "$non_rust_repo/docs"
cat > "$non_rust_repo/tools/validate" <<'SCRIPT'
#!/usr/bin/env bash
# Detect unsafe changes in scripts; this is prose/regex text, not Rust code.
# Other Rust-looking tokens in non-Rust files: #[repr(C)], extern "C", AtomicUsize.
printf '%s\n' 'unsafe change marker'
SCRIPT
cat > "$non_rust_repo/docs/risk.md" <<'DOC'
Document unsafe migration notes, #[repr(C)] examples, extern "C" examples, and Atomic types.
DOC
git -C "$non_rust_repo" add tools/validate docs/risk.md
non_rust_json="$($SUMMARY -C "$non_rust_repo" --staged)"
assert_eq "non-Rust unsafe/repr/extern/Atomic text has no risk flags" "[]" "$(jq -c '.risk_flags' <<<"$non_rust_json")"
assert_eq "non-Rust scripts/docs remain support scope" "support" "$(jq -r '.scope' <<<"$non_rust_json")"

rust_repo="$SANDBOX/rust"
init_repo "$rust_repo"
mkdir -p "$rust_repo/src"
cat > "$rust_repo/src/lib.rs" <<'RUST'
use std::sync::atomic::AtomicUsize;

#[repr(C)]
pub struct Packet {
    value: AtomicUsize,
}

extern "C" {
    fn ffi_entry();
}

pub unsafe fn call_ffi() {
    ffi_entry();
}
RUST
git -C "$rust_repo" add src/lib.rs
rust_json="$($SUMMARY -C "$rust_repo" --staged)"
assert_eq "Rust source still emits Rust risk flags" '["unsafe_code_added","repr_c_struct_changed","extern_c_changed","atomics_modified"]' "$(jq -c '.risk_flags' <<<"$rust_json")"
assert_eq "Rust source is production scope" "production" "$(jq -r '.scope' <<<"$rust_json")"

# vstack#944: panic patterns in #[cfg(test)] modules inside production files
cfg_test_repo="$SANDBOX/cfg-test"
init_repo "$cfg_test_repo"
mkdir -p "$cfg_test_repo/src"
cat > "$cfg_test_repo/src/lib.rs" <<'RUST'
pub fn add(a: u32, b: u32) -> u32 {
    a + b
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn adds() {
        let sum: u32 = "3".parse().unwrap();
        assert_eq!(add(1, 2), sum);
        if sum == 0 {
            panic!("unreachable");
        }
    }
}
RUST
git -C "$cfg_test_repo" add src/lib.rs
cfg_test_json="$($SUMMARY -C "$cfg_test_repo" --staged)"
assert_eq "cfg(test) panic/unwrap classifies as test_panic_path_added" '["test_panic_path_added"]' "$(jq -c '.risk_flags' <<<"$cfg_test_json")"

# Production panic paths keep the existing flag
prod_panic_repo="$SANDBOX/prod-panic"
init_repo "$prod_panic_repo"
mkdir -p "$prod_panic_repo/src"
cat > "$prod_panic_repo/src/lib.rs" <<'RUST'
pub fn parse(s: &str) -> u32 {
    s.parse().unwrap()
}
RUST
git -C "$prod_panic_repo" add src/lib.rs
prod_panic_json="$($SUMMARY -C "$prod_panic_repo" --staged)"
assert_eq "production unwrap keeps panic_path_added" '["panic_path_added"]' "$(jq -c '.risk_flags' <<<"$prod_panic_json")"

# A file with both a production panic path and a cfg(test) assertion carries both flags
mixed_repo="$SANDBOX/mixed"
init_repo "$mixed_repo"
mkdir -p "$mixed_repo/src"
cat > "$mixed_repo/src/lib.rs" <<'RUST'
pub fn parse(s: &str) -> u32 {
    s.parse().unwrap()
}

#[cfg(test)]
mod tests {
    #[test]
    fn parses() {
        assert_eq!(super::parse("3"), "3".parse::<u32>().unwrap());
    }
}
RUST
git -C "$mixed_repo" add src/lib.rs
mixed_json="$($SUMMARY -C "$mixed_repo" --staged)"
assert_eq "mixed prod + cfg(test) panic carries both flags" '["panic_path_added","test_panic_path_added"]' "$(jq -c '.risk_flags' <<<"$mixed_json")"

# tests/ dirs and *_tests.rs files classify as test context by path
test_dir_repo="$SANDBOX/test-dir"
init_repo "$test_dir_repo"
mkdir -p "$test_dir_repo/mycrate/tests" "$test_dir_repo/mycrate/src"
cat > "$test_dir_repo/mycrate/tests/integration.rs" <<'RUST'
#[test]
fn roundtrip() {
    let v: u32 = "7".parse().unwrap();
    assert_eq!(v, 7);
}
RUST
cat > "$test_dir_repo/mycrate/src/api_tests.rs" <<'RUST'
#[test]
fn api() {
    panic!("not yet implemented");
}
RUST
git -C "$test_dir_repo" add mycrate
test_dir_json="$($SUMMARY -C "$test_dir_repo" --staged)"
assert_eq "tests/ dir and *_tests.rs panic classifies as test_panic_path_added" '["test_panic_path_added"]' "$(jq -c '.risk_flags' <<<"$test_dir_json")"

printf '\nPASS=%d FAIL=%d\n' "$PASS" "$FAIL"
if [ "$FAIL" -ne 0 ]; then exit 1; fi
