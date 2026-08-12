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

# 2018-style parent file: src/scan.rs gates `mod fixtures;` resolving to
# src/scan/fixtures.rs.
parent_repo="$SANDBOX/parent-style"
init_repo "$parent_repo"
mkdir -p "$parent_repo/src/scan"
cat > "$parent_repo/src/scan.rs" <<'RUST'
pub fn scan() -> u32 {
    1
}

#[cfg(test)]
mod fixtures;
RUST
git -C "$parent_repo" add src
git -C "$parent_repo" commit -q -m modules
cat > "$parent_repo/src/scan/fixtures.rs" <<'RUST'
pub fn fixture() -> u32 {
    "7".parse().unwrap()
}
RUST
git -C "$parent_repo" add src/scan/fixtures.rs
parent_json="$($SUMMARY -C "$parent_repo" --staged)"
assert_eq "2018-style parent-file gated mod classifies as test_panic_path_added" \
    '["test_panic_path_added"]' "$(jq -c '.risk_flags' <<<"$parent_json")"
assert_eq "2018-style parent-file gated mod is not production scope" \
    "support" "$(jq -r '.scope' <<<"$parent_json")"

# --head mode resolves declaring modules from tracked files. The gated
# declaration is committed; the fixture file is staged but uncommitted.
head_repo="$SANDBOX/head-mode"
init_repo "$head_repo"
mkdir -p "$head_repo/src/module_scan"
cat > "$head_repo/src/module_scan/mod.rs" <<'RUST'
#[cfg(test)]
#[path = "scan_fixtures.rs"]
mod scan_fixtures;
RUST
git -C "$head_repo" add src
git -C "$head_repo" commit -q -m modules
cat > "$head_repo/src/module_scan/scan_fixtures.rs" <<'RUST'
pub fn fixture() -> u32 {
    "7".parse().unwrap()
}
RUST
git -C "$head_repo" add src/module_scan/scan_fixtures.rs
head_json="$($SUMMARY -C "$head_repo" --head)"
assert_eq "--head gated #[path] sibling classifies as test_panic_path_added" \
    '["test_panic_path_added"]' "$(jq -c '.risk_flags' <<<"$head_json")"

# An UNTRACKED sibling carrying a gated declaration must not reclassify a
# tracked production change (git diff HEAD never surfaces untracked files).
untracked_repo="$SANDBOX/untracked-decl"
init_repo "$untracked_repo"
mkdir -p "$untracked_repo/src"
cat > "$untracked_repo/src/util.rs" <<'RUST'
pub fn parse(s: &str) -> u32 {
    s.parse().unwrap()
}
RUST
cat > "$untracked_repo/src/scratch.rs" <<'RUST'
#[cfg(test)]
#[path = "util.rs"]
mod util_fixtures;
RUST
git -C "$untracked_repo" add src/util.rs
untracked_json="$($SUMMARY -C "$untracked_repo" --head)"
assert_eq "untracked gated declaration does not downgrade tracked change" \
    '["panic_path_added"]' "$(jq -c '.risk_flags' <<<"$untracked_json")"
assert_eq "untracked gated declaration keeps production scope" \
    "production" "$(jq -r '.scope' <<<"$untracked_json")"

# bin/ path segments are crate roots: reachable without any mod declaration,
# so a gated declaration does not make them test-only.
bin_repo="$SANDBOX/bin-root"
init_repo "$bin_repo"
mkdir -p "$bin_repo/src/bin"
cat > "$bin_repo/src/bin/cli.rs" <<'RUST'
#[cfg(test)]
#[path = "extra.rs"]
mod extra;

fn main() {}
RUST
git -C "$bin_repo" add src
git -C "$bin_repo" commit -q -m bins
cat > "$bin_repo/src/bin/extra.rs" <<'RUST'
fn main() {
    let _v: u32 = "7".parse().unwrap();
}
RUST
git -C "$bin_repo" add src/bin/extra.rs
bin_json="$($SUMMARY -C "$bin_repo" --staged)"
assert_eq "bin/ crate root keeps panic_path_added despite gated declaration" \
    '["panic_path_added"]' "$(jq -c '.risk_flags' <<<"$bin_json")"
assert_eq "bin/ crate root stays production scope" \
    "production" "$(jq -r '.scope' <<<"$bin_json")"

# A gated declaration inside a /* block comment */ is not a declaration —
# commented-out text must not downgrade production code.
comment_repo="$SANDBOX/block-comment"
init_repo "$comment_repo"
mkdir -p "$comment_repo/src"
cat > "$comment_repo/src/lib.rs" <<'RUST'
/*
#[cfg(test)]
#[path = "shadow.rs"]
mod shadow;
*/
pub fn real() -> u32 {
    1
}
RUST
git -C "$comment_repo" add src
git -C "$comment_repo" commit -q -m lib
cat > "$comment_repo/src/shadow.rs" <<'RUST'
pub fn parse(s: &str) -> u32 {
    s.parse().unwrap()
}
RUST
git -C "$comment_repo" add src/shadow.rs
comment_json="$($SUMMARY -C "$comment_repo" --staged)"
assert_eq "block-commented gated declaration keeps panic_path_added" \
    '["panic_path_added"]' "$(jq -c '.risk_flags' <<<"$comment_json")"
assert_eq "block-commented gated declaration stays production scope" \
    "production" "$(jq -r '.scope' <<<"$comment_json")"

# include! of the candidate is an ungated production route: the content
# compiles in the includer's cfg context, so it outweighs a gated #[path].
include_repo="$SANDBOX/include-route"
init_repo "$include_repo"
mkdir -p "$include_repo/src"
cat > "$include_repo/src/lib.rs" <<'RUST'
include!("shared_impl.rs");

#[cfg(test)]
#[path = "shared_impl.rs"]
mod shared_fixtures;
RUST
git -C "$include_repo" add src
git -C "$include_repo" commit -q -m lib
cat > "$include_repo/src/shared_impl.rs" <<'RUST'
pub fn parse(s: &str) -> u32 {
    s.parse().unwrap()
}
RUST
git -C "$include_repo" add src/shared_impl.rs
include_json="$($SUMMARY -C "$include_repo" --staged)"
assert_eq "include! route keeps panic_path_added despite gated #[path]" \
    '["panic_path_added"]' "$(jq -c '.risk_flags' <<<"$include_json")"
assert_eq "include! route stays production scope" \
    "production" "$(jq -r '.scope' <<<"$include_json")"

# A read failure while scanning declaring modules fails closed: the
# unreadable file could have held an ungated route, so the candidate keeps
# production classification. Needs non-root (root reads through chmod 000).
if [ "$(id -u)" -ne 0 ]; then
    unreadable_repo="$SANDBOX/unreadable"
    init_repo "$unreadable_repo"
    mkdir -p "$unreadable_repo/src/x"
    cat > "$unreadable_repo/src/x/mod.rs" <<'RUST'
#[cfg(test)]
#[path = "cand.rs"]
mod cand_fixtures;
RUST
    cat > "$unreadable_repo/src/x/other.rs" <<'RUST'
#[path = "cand.rs"]
mod cand;
RUST
    git -C "$unreadable_repo" add src
    git -C "$unreadable_repo" commit -q -m modules
    cat > "$unreadable_repo/src/x/cand.rs" <<'RUST'
pub fn parse(s: &str) -> u32 {
    s.parse().unwrap()
}
RUST
    git -C "$unreadable_repo" add src/x/cand.rs
    chmod 000 "$unreadable_repo/src/x/other.rs"
    # Keep the unreadable file out of the diff itself: chmod invalidates its
    # cached stat, and a pre-existing (unguarded) `git diff -- <prod paths>`
    # pipeline dies on unreadable diff members. This case targets the
    # declaration scanner's fail-closed read, not that pipeline.
    git -C "$unreadable_repo" update-index --assume-unchanged src/x/other.rs
    unreadable_json="$($SUMMARY -C "$unreadable_repo" --head)"
    chmod 644 "$unreadable_repo/src/x/other.rs"
    assert_eq "unreadable declaring module fails closed to panic_path_added" \
        '["panic_path_added"]' "$(jq -c '.risk_flags' <<<"$unreadable_json")"
    assert_eq "unreadable declaring module fails closed to production scope" \
        "production" "$(jq -r '.scope' <<<"$unreadable_json")"
else
    printf '  SKIP: unreadable-module cases (running as root)\n'
fi

# --head content reads are tracked-only, like the sibling listing: an
# UNTRACKED 2018-style parent file carrying a gated declaration must not
# reclassify a tracked candidate.
untracked_parent_repo="$SANDBOX/untracked-parent"
init_repo "$untracked_parent_repo"
mkdir -p "$untracked_parent_repo/src/scan"
cat > "$untracked_parent_repo/src/scan/fixtures.rs" <<'RUST'
pub fn parse(s: &str) -> u32 {
    s.parse().unwrap()
}
RUST
cat > "$untracked_parent_repo/src/scan.rs" <<'RUST'
#[cfg(test)]
mod fixtures;
RUST
git -C "$untracked_parent_repo" add src/scan/fixtures.rs
untracked_parent_json="$($SUMMARY -C "$untracked_parent_repo" --head)"
assert_eq "untracked parent-file gated declaration does not downgrade in --head" \
    '["panic_path_added"]' "$(jq -c '.risk_flags' <<<"$untracked_parent_json")"
assert_eq "untracked parent-file gated declaration keeps production scope" \
    "production" "$(jq -r '.scope' <<<"$untracked_parent_json")"

# Line comments take precedence over block-comment openers: `// ... /*` must
# not open block state and swallow a following real ungated declaration.
line_comment_repo="$SANDBOX/line-comment-precedence"
init_repo "$line_comment_repo"
mkdir -p "$line_comment_repo/src/m"
cat > "$line_comment_repo/src/m/mod.rs" <<'RUST'
// docs: /* example opener inside a line comment
pub mod cand;
/* a real block comment */
#[cfg(test)]
#[path = "cand.rs"]
mod cand_fixtures;
RUST
git -C "$line_comment_repo" add src
git -C "$line_comment_repo" commit -q -m modules
cat > "$line_comment_repo/src/m/cand.rs" <<'RUST'
pub fn parse(s: &str) -> u32 {
    s.parse().unwrap()
}
RUST
git -C "$line_comment_repo" add src/m/cand.rs
line_comment_json="$($SUMMARY -C "$line_comment_repo" --staged)"
assert_eq "ungated decl after a line-commented /* keeps panic_path_added" \
    '["panic_path_added"]' "$(jq -c '.risk_flags' <<<"$line_comment_json")"
assert_eq "ungated decl after a line-commented /* stays production scope" \
    "production" "$(jq -r '.scope' <<<"$line_comment_json")"

# Rust block comments nest: an inner */ must not close the outer comment and
# expose a commented-out gated declaration as real.
nested_comment_repo="$SANDBOX/nested-comment"
init_repo "$nested_comment_repo"
mkdir -p "$nested_comment_repo/src"
cat > "$nested_comment_repo/src/lib.rs" <<'RUST'
/*
/* nested */
#[cfg(test)]
#[path = "shadow.rs"]
mod shadow;
*/
pub fn real() -> u32 {
    1
}
RUST
git -C "$nested_comment_repo" add src
git -C "$nested_comment_repo" commit -q -m lib
cat > "$nested_comment_repo/src/shadow.rs" <<'RUST'
pub fn parse(s: &str) -> u32 {
    s.parse().unwrap()
}
RUST
git -C "$nested_comment_repo" add src/shadow.rs
nested_comment_json="$($SUMMARY -C "$nested_comment_repo" --staged)"
assert_eq "nested-comment gated declaration keeps panic_path_added" \
    '["panic_path_added"]' "$(jq -c '.risk_flags' <<<"$nested_comment_json")"
assert_eq "nested-comment gated declaration stays production scope" \
    "production" "$(jq -r '.scope' <<<"$nested_comment_json")"

# A commented-out include! is not a production route: the real gated
# declaration must still classify the candidate as test.
commented_include_repo="$SANDBOX/commented-include"
init_repo "$commented_include_repo"
mkdir -p "$commented_include_repo/src"
cat > "$commented_include_repo/src/lib.rs" <<'RUST'
// include!("shared_impl.rs");

#[cfg(test)]
#[path = "shared_impl.rs"]
mod shared_fixtures;
RUST
git -C "$commented_include_repo" add src
git -C "$commented_include_repo" commit -q -m lib
cat > "$commented_include_repo/src/shared_impl.rs" <<'RUST'
pub fn sample() -> u32 {
    "3".parse().unwrap()
}
RUST
git -C "$commented_include_repo" add src/shared_impl.rs
commented_include_json="$($SUMMARY -C "$commented_include_repo" --staged)"
assert_eq "commented-out include! still classifies as test_panic_path_added" \
    '["test_panic_path_added"]' "$(jq -c '.risk_flags' <<<"$commented_include_json")"
assert_eq "commented-out include! is not production scope" \
    "support" "$(jq -r '.scope' <<<"$commented_include_json")"

# A formatted include! whose string literal sits on a later line is still an
# ungated production route — it must not be lost to line-based scanning.
multiline_include_repo="$SANDBOX/multiline-include"
init_repo "$multiline_include_repo"
mkdir -p "$multiline_include_repo/src"
cat > "$multiline_include_repo/src/lib.rs" <<'RUST'
include!(
    "shared_impl.rs"
);

#[cfg(test)]
#[path = "shared_impl.rs"]
mod shared_fixtures;
RUST
git -C "$multiline_include_repo" add src
git -C "$multiline_include_repo" commit -q -m lib
cat > "$multiline_include_repo/src/shared_impl.rs" <<'RUST'
pub fn parse(s: &str) -> u32 {
    s.parse().unwrap()
}
RUST
git -C "$multiline_include_repo" add src/shared_impl.rs
multiline_include_json="$($SUMMARY -C "$multiline_include_repo" --staged)"
assert_eq "multiline include! route keeps panic_path_added" \
    '["panic_path_added"]' "$(jq -c '.risk_flags' <<<"$multiline_include_json")"
assert_eq "multiline include! route stays production scope" \
    "production" "$(jq -r '.scope' <<<"$multiline_include_json")"

# include! matches on its RESOLVED target, not a basename substring: an
# include of a different file whose name merely contains the candidate's
# basename is not a route to the candidate.
substr_include_repo="$SANDBOX/substr-include"
init_repo "$substr_include_repo"
mkdir -p "$substr_include_repo/src"
cat > "$substr_include_repo/src/lib.rs" <<'RUST'
include!("gen_shared_impl.rs");

#[cfg(test)]
#[path = "shared_impl.rs"]
mod shared_fixtures;
RUST
cat > "$substr_include_repo/src/gen_shared_impl.rs" <<'RUST'
pub const GENERATED: u32 = 1;
RUST
git -C "$substr_include_repo" add src
git -C "$substr_include_repo" commit -q -m lib
cat > "$substr_include_repo/src/shared_impl.rs" <<'RUST'
pub fn sample() -> u32 {
    "3".parse().unwrap()
}
RUST
git -C "$substr_include_repo" add src/shared_impl.rs
substr_include_json="$($SUMMARY -C "$substr_include_repo" --staged)"
assert_eq "basename-substring include! still classifies as test_panic_path_added" \
    '["test_panic_path_added"]' "$(jq -c '.risk_flags' <<<"$substr_include_json")"
assert_eq "basename-substring include! is not production scope" \
    "support" "$(jq -r '.scope' <<<"$substr_include_json")"

# An ungated out-of-directory #[path] declaration from an ancestor (here the
# crate root) outweighs a gated same-directory one.
crossdir_repo="$SANDBOX/cross-directory"
init_repo "$crossdir_repo"
mkdir -p "$crossdir_repo/src/m"
cat > "$crossdir_repo/src/lib.rs" <<'RUST'
#[path = "m/cand.rs"]
pub mod cand;
RUST
cat > "$crossdir_repo/src/m/mod.rs" <<'RUST'
#[cfg(test)]
#[path = "cand.rs"]
mod cand_fixtures;
RUST
git -C "$crossdir_repo" add src
git -C "$crossdir_repo" commit -q -m modules
cat > "$crossdir_repo/src/m/cand.rs" <<'RUST'
pub fn parse(s: &str) -> u32 {
    s.parse().unwrap()
}
RUST
git -C "$crossdir_repo" add src/m/cand.rs
crossdir_json="$($SUMMARY -C "$crossdir_repo" --staged)"
assert_eq "ancestor ungated #[path] outweighs local gated declaration" \
    '["panic_path_added"]' "$(jq -c '.risk_flags' <<<"$crossdir_json")"
assert_eq "ancestor ungated #[path] keeps production scope" \
    "production" "$(jq -r '.scope' <<<"$crossdir_json")"

# Candidate paths containing whitespace survive the scan iteration (word
# splitting must not shred them). The gated declaration lives in the crate
# root; the candidate sits in a directory with a space.
space_repo="$SANDBOX/space-path"
init_repo "$space_repo"
mkdir -p "$space_repo/src/sub dir"
cat > "$space_repo/src/lib.rs" <<'RUST'
#[cfg(test)]
#[path = "sub dir/cand.rs"]
mod fixtures;
RUST
git -C "$space_repo" add src
git -C "$space_repo" commit -q -m lib
cat > "$space_repo/src/sub dir/cand.rs" <<'RUST'
pub fn parse(s: &str) -> u32 {
    s.parse().unwrap()
}
RUST
git -C "$space_repo" add "src/sub dir/cand.rs"
space_json="$($SUMMARY -C "$space_repo" --staged)"
assert_eq "whitespace path with gated declaration is not production scope" \
    "support" "$(jq -r '.scope' <<<"$space_json")"
assert_eq "whitespace path still carries test_panic_path_added" \
    '["test_panic_path_added"]' "$(jq -c '.risk_flags' <<<"$space_json")"

# Lexically equivalent #[path] spellings resolve to the same target: an
# ungated "./shared.rs" must cancel a gated "shared.rs".
dotpath_repo="$SANDBOX/dot-path"
init_repo "$dotpath_repo"
mkdir -p "$dotpath_repo/src"
cat > "$dotpath_repo/src/lib.rs" <<'RUST'
#[path = "./shared.rs"]
pub mod shared;

#[cfg(test)]
#[path = "shared.rs"]
mod shared_fixtures;
RUST
git -C "$dotpath_repo" add src
git -C "$dotpath_repo" commit -q -m lib
cat > "$dotpath_repo/src/shared.rs" <<'RUST'
pub fn parse(s: &str) -> u32 {
    s.parse().unwrap()
}
RUST
git -C "$dotpath_repo" add src/shared.rs
dotpath_json="$($SUMMARY -C "$dotpath_repo" --staged)"
assert_eq "dot-prefixed ungated #[path] cancels gated declaration" \
    '["panic_path_added"]' "$(jq -c '.risk_flags' <<<"$dotpath_json")"
assert_eq "dot-prefixed ungated #[path] keeps production scope" \
    "production" "$(jq -r '.scope' <<<"$dotpath_json")"

# The directory form of a bare declaration: #[cfg(test)] mod helpers;
# resolving through helpers/mod.rs classifies the mod.rs as test.
dirform_repo="$SANDBOX/dir-form"
init_repo "$dirform_repo"
mkdir -p "$dirform_repo/src/helpers"
cat > "$dirform_repo/src/lib.rs" <<'RUST'
pub fn add(a: u32, b: u32) -> u32 {
    a + b
}

#[cfg(test)]
mod helpers;
RUST
git -C "$dirform_repo" add src
git -C "$dirform_repo" commit -q -m lib
cat > "$dirform_repo/src/helpers/mod.rs" <<'RUST'
pub fn sample() -> u32 {
    "3".parse().unwrap()
}
RUST
git -C "$dirform_repo" add src/helpers/mod.rs
dirform_json="$($SUMMARY -C "$dirform_repo" --staged)"
assert_eq "gated directory-form mod.rs classifies as test_panic_path_added" \
    '["test_panic_path_added"]' "$(jq -c '.risk_flags' <<<"$dirform_json")"
assert_eq "gated directory-form mod.rs is not production scope" \
    "support" "$(jq -r '.scope' <<<"$dirform_json")"

# Control: an ungated directory-form module stays production.
dirform_prod_repo="$SANDBOX/dir-form-prod"
init_repo "$dirform_prod_repo"
mkdir -p "$dirform_prod_repo/src/util"
cat > "$dirform_prod_repo/src/lib.rs" <<'RUST'
pub mod util;
RUST
git -C "$dirform_prod_repo" add src
git -C "$dirform_prod_repo" commit -q -m lib
cat > "$dirform_prod_repo/src/util/mod.rs" <<'RUST'
pub fn parse(s: &str) -> u32 {
    s.parse().unwrap()
}
RUST
git -C "$dirform_prod_repo" add src/util/mod.rs
dirform_prod_json="$($SUMMARY -C "$dirform_prod_repo" --staged)"
assert_eq "ungated directory-form mod.rs keeps panic_path_added" \
    '["panic_path_added"]' "$(jq -c '.risk_flags' <<<"$dirform_prod_json")"
assert_eq "ungated directory-form mod.rs stays production scope" \
    "production" "$(jq -r '.scope' <<<"$dirform_prod_json")"

# include! resolves in the containing FILE's directory, not the module
# directory: include!("shared_impl.rs") in src/outer.rs reaches
# src/shared_impl.rs and must cancel a gated declaration of that file.
filedir_include_repo="$SANDBOX/filedir-include"
init_repo "$filedir_include_repo"
mkdir -p "$filedir_include_repo/src"
cat > "$filedir_include_repo/src/outer.rs" <<'RUST'
include!("shared_impl.rs");
RUST
cat > "$filedir_include_repo/src/lib.rs" <<'RUST'
pub mod outer;

#[cfg(test)]
#[path = "shared_impl.rs"]
mod shared_fixtures;
RUST
git -C "$filedir_include_repo" add src
git -C "$filedir_include_repo" commit -q -m lib
cat > "$filedir_include_repo/src/shared_impl.rs" <<'RUST'
pub fn parse(s: &str) -> u32 {
    s.parse().unwrap()
}
RUST
git -C "$filedir_include_repo" add src/shared_impl.rs
filedir_include_json="$($SUMMARY -C "$filedir_include_repo" --staged)"
assert_eq "include! from a non-mod-rs file resolves in the file's directory" \
    '["panic_path_added"]' "$(jq -c '.risk_flags' <<<"$filedir_include_json")"
assert_eq "include! from a non-mod-rs file keeps production scope" \
    "production" "$(jq -r '.scope' <<<"$filedir_include_json")"

# An include! that CLOSES without a string literal (computed path) must not
# leave pending state that swallows a later unrelated literal as its target.
stale_include_repo="$SANDBOX/stale-include"
init_repo "$stale_include_repo"
mkdir -p "$stale_include_repo/src"
cat > "$stale_include_repo/src/lib.rs" <<'RUST'
include!(GENERATED_PATH);
const NOTE: &str = "shared_impl.rs";

#[cfg(test)]
#[path = "shared_impl.rs"]
mod shared_fixtures;
RUST
git -C "$stale_include_repo" add src
git -C "$stale_include_repo" commit -q -m lib
cat > "$stale_include_repo/src/shared_impl.rs" <<'RUST'
pub fn sample() -> u32 {
    "3".parse().unwrap()
}
RUST
git -C "$stale_include_repo" add src/shared_impl.rs
stale_include_json="$($SUMMARY -C "$stale_include_repo" --staged)"
assert_eq "closed computed include! leaves no stale route; gated decl wins" \
    '["test_panic_path_added"]' "$(jq -c '.risk_flags' <<<"$stale_include_json")"
assert_eq "closed computed include! is not production scope" \
    "support" "$(jq -r '.scope' <<<"$stale_include_json")"

# A #[path] attribute split across lines (rustc accepts the split) is still
# an ungated production route — it must not be discarded and lose to a
# conventional gated declaration of the same file.
multiline_attr_repo="$SANDBOX/multiline-attr"
init_repo "$multiline_attr_repo"
mkdir -p "$multiline_attr_repo/src"
cat > "$multiline_attr_repo/src/lib.rs" <<'RUST'
#[path =
"shared.rs"] pub mod production_alias;

#[cfg(test)]
#[path = "shared.rs"]
mod shared_fixtures;
RUST
git -C "$multiline_attr_repo" add src
git -C "$multiline_attr_repo" commit -q -m lib
cat > "$multiline_attr_repo/src/shared.rs" <<'RUST'
pub fn parse(s: &str) -> u32 {
    s.parse().unwrap()
}
RUST
git -C "$multiline_attr_repo" add src/shared.rs
multiline_attr_json="$($SUMMARY -C "$multiline_attr_repo" --staged)"
assert_eq "multiline #[path] ungated declaration keeps panic_path_added" \
    '["panic_path_added"]' "$(jq -c '.risk_flags' <<<"$multiline_attr_json")"
assert_eq "multiline #[path] ungated declaration stays production scope" \
    "production" "$(jq -r '.scope' <<<"$multiline_attr_json")"

# include! needs a token boundary: my_include!("...") is a different macro
# and must not fabricate an ungated route.
tokenboundary_repo="$SANDBOX/token-boundary"
init_repo "$tokenboundary_repo"
mkdir -p "$tokenboundary_repo/src"
cat > "$tokenboundary_repo/src/lib.rs" <<'RUST'
my_include!("shared_impl.rs");

#[cfg(test)]
#[path = "shared_impl.rs"]
mod shared_fixtures;
RUST
git -C "$tokenboundary_repo" add src
git -C "$tokenboundary_repo" commit -q -m lib
cat > "$tokenboundary_repo/src/shared_impl.rs" <<'RUST'
pub fn sample() -> u32 {
    "3".parse().unwrap()
}
RUST
git -C "$tokenboundary_repo" add src/shared_impl.rs
tokenboundary_json="$($SUMMARY -C "$tokenboundary_repo" --staged)"
assert_eq "my_include! is not an include! route; gated decl wins" \
    '["test_panic_path_added"]' "$(jq -c '.risk_flags' <<<"$tokenboundary_json")"
assert_eq "my_include! candidate is not production scope" \
    "support" "$(jq -r '.scope' <<<"$tokenboundary_json")"

# Per the Rust reference, #[path] on a module NOT inside an inline block
# resolves relative to the SOURCE FILE's directory — also for non-mod-rs
# files. An ungated #[path = "target.rs"] in src/outer.rs reaches
# src/target.rs and must cancel a gated declaration of that file.
filedir_path_repo="$SANDBOX/filedir-path"
init_repo "$filedir_path_repo"
mkdir -p "$filedir_path_repo/src"
cat > "$filedir_path_repo/src/outer.rs" <<'RUST'
#[path = "target.rs"]
pub mod t;
RUST
cat > "$filedir_path_repo/src/lib.rs" <<'RUST'
pub mod outer;

#[cfg(test)]
#[path = "target.rs"]
mod target_fixtures;
RUST
git -C "$filedir_path_repo" add src
git -C "$filedir_path_repo" commit -q -m lib
cat > "$filedir_path_repo/src/target.rs" <<'RUST'
pub fn parse(s: &str) -> u32 {
    s.parse().unwrap()
}
RUST
git -C "$filedir_path_repo" add src/target.rs
filedir_path_json="$($SUMMARY -C "$filedir_path_repo" --staged)"
assert_eq "non-mod-rs #[path] resolves in the file's directory" \
    '["panic_path_added"]' "$(jq -c '.risk_flags' <<<"$filedir_path_json")"
assert_eq "non-mod-rs #[path] keeps production scope" \
    "production" "$(jq -r '.scope' <<<"$filedir_path_json")"

# Raw-string #[path = r"target.rs"] is valid Rust; the attribute must not be
# dropped (which would resolve the module by alias and lose the ungated
# route to a gated declaration).
rawstring_repo="$SANDBOX/raw-string"
init_repo "$rawstring_repo"
mkdir -p "$rawstring_repo/src"
cat > "$rawstring_repo/src/lib.rs" <<'RUST'
#[path = r"target.rs"]
pub mod t;

#[cfg(test)]
#[path = "target.rs"]
mod target_fixtures;
RUST
git -C "$rawstring_repo" add src
git -C "$rawstring_repo" commit -q -m lib
cat > "$rawstring_repo/src/target.rs" <<'RUST'
pub fn parse(s: &str) -> u32 {
    s.parse().unwrap()
}
RUST
git -C "$rawstring_repo" add src/target.rs
rawstring_json="$($SUMMARY -C "$rawstring_repo" --staged)"
assert_eq "raw-string #[path] ungated declaration keeps panic_path_added" \
    '["panic_path_added"]' "$(jq -c '.risk_flags' <<<"$rawstring_json")"
assert_eq "raw-string #[path] ungated declaration stays production scope" \
    "production" "$(jq -r '.scope' <<<"$rawstring_json")"

# Declarations inside inline module blocks resolve into the inline chain
# (mod outer { mod cand; } reaches outer/cand.rs) — the scanner skips them
# rather than mis-resolving. Direction one: a gated inline declaration must
# not fabricate a gated route for an unrelated same-name file.
inline_gated_repo="$SANDBOX/inline-gated"
init_repo "$inline_gated_repo"
mkdir -p "$inline_gated_repo/src"
cat > "$inline_gated_repo/src/lib.rs" <<'RUST'
mod outer {
    #[cfg(test)]
    mod cand;
}
RUST
git -C "$inline_gated_repo" add src
git -C "$inline_gated_repo" commit -q -m lib
cat > "$inline_gated_repo/src/cand.rs" <<'RUST'
pub fn parse(s: &str) -> u32 {
    s.parse().unwrap()
}
RUST
git -C "$inline_gated_repo" add src/cand.rs
inline_gated_json="$($SUMMARY -C "$inline_gated_repo" --staged)"
assert_eq "inline gated declaration does not downgrade an unrelated file" \
    '["panic_path_added"]' "$(jq -c '.risk_flags' <<<"$inline_gated_json")"
assert_eq "inline gated declaration keeps production scope" \
    "production" "$(jq -r '.scope' <<<"$inline_gated_json")"

# Direction two: an ungated inline declaration must not fabricate an
# ungated route that destroys a real gated one.
inline_ungated_repo="$SANDBOX/inline-ungated"
init_repo "$inline_ungated_repo"
mkdir -p "$inline_ungated_repo/src"
cat > "$inline_ungated_repo/src/lib.rs" <<'RUST'
mod outer {
    pub mod cand;
}

#[cfg(test)]
#[path = "cand.rs"]
mod cand_fixtures;
RUST
git -C "$inline_ungated_repo" add src
git -C "$inline_ungated_repo" commit -q -m lib
cat > "$inline_ungated_repo/src/cand.rs" <<'RUST'
pub fn sample() -> u32 {
    "3".parse().unwrap()
}
RUST
git -C "$inline_ungated_repo" add src/cand.rs
inline_ungated_json="$($SUMMARY -C "$inline_ungated_repo" --staged)"
assert_eq "inline ungated declaration does not destroy the real gated route" \
    '["test_panic_path_added"]' "$(jq -c '.risk_flags' <<<"$inline_ungated_json")"
assert_eq "inline ungated declaration is not production scope" \
    "support" "$(jq -r '.scope' <<<"$inline_ungated_json")"

# Hash-raw #[path = r#"target.rs"#] is valid Rust: the attribute must be
# parsed, not dropped into bare-mod alias resolution that loses the
# ungated route.
hashraw_repo="$SANDBOX/hash-raw"
init_repo "$hashraw_repo"
mkdir -p "$hashraw_repo/src"
cat > "$hashraw_repo/src/lib.rs" <<'RUST'
#[path = r#"target.rs"#]
pub mod t;

#[cfg(test)]
#[path = "target.rs"]
mod target_fixtures;
RUST
git -C "$hashraw_repo" add src
git -C "$hashraw_repo" commit -q -m lib
cat > "$hashraw_repo/src/target.rs" <<'RUST'
pub fn parse(s: &str) -> u32 {
    s.parse().unwrap()
}
RUST
git -C "$hashraw_repo" add src/target.rs
hashraw_json="$($SUMMARY -C "$hashraw_repo" --staged)"
assert_eq "hash-raw #[path] ungated declaration keeps panic_path_added" \
    '["panic_path_added"]' "$(jq -c '.risk_flags' <<<"$hashraw_json")"
assert_eq "hash-raw #[path] ungated declaration stays production scope" \
    "production" "$(jq -r '.scope' <<<"$hashraw_json")"

# An attribute-prefixed inline opener on one line (#[cfg(test)] mod outer {)
# must still enter the skip region: its inner ungated declaration must not
# fabricate a route that cancels the real gated one.
attr_opener_repo="$SANDBOX/attr-opener"
init_repo "$attr_opener_repo"
mkdir -p "$attr_opener_repo/src"
cat > "$attr_opener_repo/src/lib.rs" <<'RUST'
#[cfg(test)] mod outer {
    pub mod cand;
}

#[cfg(test)]
#[path = "cand.rs"]
mod cand_fixtures;
RUST
git -C "$attr_opener_repo" add src
git -C "$attr_opener_repo" commit -q -m lib
cat > "$attr_opener_repo/src/cand.rs" <<'RUST'
pub fn sample() -> u32 {
    "3".parse().unwrap()
}
RUST
git -C "$attr_opener_repo" add src/cand.rs
attr_opener_json="$($SUMMARY -C "$attr_opener_repo" --staged)"
assert_eq "attribute-prefixed inline opener still skips its block" \
    '["test_panic_path_added"]' "$(jq -c '.risk_flags' <<<"$attr_opener_json")"
assert_eq "attribute-prefixed inline opener is not production scope" \
    "support" "$(jq -r '.scope' <<<"$attr_opener_json")"

# Every include! on a line is a route, not just the first.
multi_include_repo="$SANDBOX/multi-include"
init_repo "$multi_include_repo"
mkdir -p "$multi_include_repo/src"
cat > "$multi_include_repo/src/lib.rs" <<'RUST'
include!("first.rs"); include!("shared_impl.rs");

#[cfg(test)]
#[path = "shared_impl.rs"]
mod shared_fixtures;
RUST
cat > "$multi_include_repo/src/first.rs" <<'RUST'
pub const FIRST: u32 = 1;
RUST
git -C "$multi_include_repo" add src
git -C "$multi_include_repo" commit -q -m lib
cat > "$multi_include_repo/src/shared_impl.rs" <<'RUST'
pub fn parse(s: &str) -> u32 {
    s.parse().unwrap()
}
RUST
git -C "$multi_include_repo" add src/shared_impl.rs
multi_include_json="$($SUMMARY -C "$multi_include_repo" --staged)"
assert_eq "second include! on a line keeps panic_path_added" \
    '["panic_path_added"]' "$(jq -c '.risk_flags' <<<"$multi_include_json")"
assert_eq "second include! on a line keeps production scope" \
    "production" "$(jq -r '.scope' <<<"$multi_include_json")"

# Every declaration on a line is recorded, not just the first.
multi_decl_repo="$SANDBOX/multi-decl"
init_repo "$multi_decl_repo"
mkdir -p "$multi_decl_repo/src"
cat > "$multi_decl_repo/src/lib.rs" <<'RUST'
mod first; pub mod shared;

#[cfg(test)]
#[path = "shared.rs"]
mod shared_fixtures;
RUST
cat > "$multi_decl_repo/src/first.rs" <<'RUST'
pub const FIRST: u32 = 1;
RUST
git -C "$multi_decl_repo" add src
git -C "$multi_decl_repo" commit -q -m lib
cat > "$multi_decl_repo/src/shared.rs" <<'RUST'
pub fn parse(s: &str) -> u32 {
    s.parse().unwrap()
}
RUST
git -C "$multi_decl_repo" add src/shared.rs
multi_decl_json="$($SUMMARY -C "$multi_decl_repo" --staged)"
assert_eq "second declaration on a line keeps panic_path_added" \
    '["panic_path_added"]' "$(jq -c '.risk_flags' <<<"$multi_decl_json")"
assert_eq "second declaration on a line keeps production scope" \
    "production" "$(jq -r '.scope' <<<"$multi_decl_json")"

# A single-line inline block (mod m { include!("cand.rs") }) emits nothing:
# the include inside must not cancel the real gated route.
oneline_inline_repo="$SANDBOX/oneline-inline"
init_repo "$oneline_inline_repo"
mkdir -p "$oneline_inline_repo/src"
cat > "$oneline_inline_repo/src/lib.rs" <<'RUST'
mod m { include!("cand.rs") }

#[cfg(test)]
#[path = "cand.rs"]
mod cand_fixtures;
RUST
git -C "$oneline_inline_repo" add src
git -C "$oneline_inline_repo" commit -q -m lib
cat > "$oneline_inline_repo/src/cand.rs" <<'RUST'
pub fn sample() -> u32 {
    "3".parse().unwrap()
}
RUST
git -C "$oneline_inline_repo" add src/cand.rs
oneline_inline_json="$($SUMMARY -C "$oneline_inline_repo" --staged)"
assert_eq "single-line inline block include! emits no route" \
    '["test_panic_path_added"]' "$(jq -c '.risk_flags' <<<"$oneline_inline_json")"
assert_eq "single-line inline block is not production scope" \
    "support" "$(jq -r '.scope' <<<"$oneline_inline_json")"

# Torture line: several declarations, an attributed inline block, and two
# include! calls share ONE line; gated twins exist for each interesting
# target. shared.rs and inc_b.rs have ungated routes on that line
# (production), onlygated.rs has only its gated route (test).
torture_repo="$SANDBOX/torture"
init_repo "$torture_repo"
mkdir -p "$torture_repo/src"
cat > "$torture_repo/src/lib.rs" <<'RUST'
mod first; pub mod shared; #[cfg(test)] mod outer { mod inner; } include!("inc_a.rs"); include!("inc_b.rs");

#[cfg(test)]
#[path = "shared.rs"]
mod shared_fx;

#[cfg(test)]
#[path = "inc_b.rs"]
mod inc_fx;

#[cfg(test)]
#[path = "onlygated.rs"]
mod og;
RUST
cat > "$torture_repo/src/first.rs" <<'RUST'
pub const FIRST: u32 = 1;
RUST
cat > "$torture_repo/src/inc_a.rs" <<'RUST'
pub const INC_A: u32 = 1;
RUST
git -C "$torture_repo" add src
git -C "$torture_repo" commit -q -m lib
cat > "$torture_repo/src/shared.rs" <<'RUST'
pub fn parse(s: &str) -> u32 {
    s.parse().unwrap()
}
RUST
cat > "$torture_repo/src/inc_b.rs" <<'RUST'
pub fn decode(s: &str) -> u32 {
    s.parse().unwrap()
}
RUST
cat > "$torture_repo/src/onlygated.rs" <<'RUST'
pub fn fixture() -> u32 {
    "7".parse().unwrap()
}
RUST
git -C "$torture_repo" add src/shared.rs src/inc_b.rs src/onlygated.rs
torture_json="$($SUMMARY -C "$torture_repo" --staged)"
assert_eq "torture line: ungated routes win for shared/inc_b, gated for onlygated" \
    '["panic_path_added","test_panic_path_added"]' "$(jq -c '.risk_flags' <<<"$torture_json")"
assert_eq "torture line: scope is production" \
    "production" "$(jq -r '.scope' <<<"$torture_json")"

printf '\nPASS=%d FAIL=%d\n' "$PASS" "$FAIL"
if [ "$FAIL" -ne 0 ]; then exit 1; fi
