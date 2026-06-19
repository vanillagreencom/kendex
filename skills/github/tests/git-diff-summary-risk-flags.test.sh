#!/usr/bin/env bash
# vstack#328: git-diff-summary Rust-specific risk flags must only scan
# Rust diffs. Non-Rust docs/scripts that mention unsafe/repr(C)/extern C/Atomic
# are descriptive text, not Rust code risk.
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

printf '\nPASS=%d FAIL=%d\n' "$PASS" "$FAIL"
if [ "$FAIL" -ne 0 ]; then exit 1; fi
