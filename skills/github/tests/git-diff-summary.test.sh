#!/usr/bin/env bash
# git-diff-summary: the risk flags a staged diff earns and the scope it lands
# in. Rust-only flags never fire on prose that mentions the tokens; a panic
# pattern is production or test by its context (a #[cfg(test)] module, a
# tests/ dir, a *_tests.rs file, or a file reachable only through a
# #[cfg(test)]-gated declaration in a committed sibling); an early match
# survives a diff larger than the pipe. The base-resolution suite is
# git-diff-summary-default-base.test.sh.
#
# A row is `label|world|flags|scope`:
#   world  `decl:<name>` the declaration committed as src/lib.rs (see decl_of),
#          `add:<path>:<body>` a staged new file with that body (see body_of);
#          a README is committed first in every world
#   flags  the .risk_flags list joined by `,`, `-` when empty
#   scope  the .scope field
set -euo pipefail

# A suite running from inside a git hook inherits GIT_DIR, GIT_COMMON_DIR,
# GIT_WORK_TREE and GIT_INDEX_FILE, which take precedence over `git -C` and
# would stage fixture blobs into the real repository.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
SUMMARY="$REPO_ROOT/skills/github/scripts/git-diff-summary"

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/git-diff-summary.XXXXXX")"
PASS=0
FAIL=0
trap 'rm -rf -- "$SANDBOX"' EXIT

assert_eq() {
  local got="$1" want="$2" label="$3"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$label"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        want: %s\n        got:  %s\n' "$label" "$want" "$got"
  fi
}

# --- the declarations ------------------------------------------------------------
# What src/lib.rs holds in the commit the staged candidate is read against.
decl_of() {
  case "$1" in
    gated-path) printf '#[cfg(test)]\n#[path = "candidate.rs"]\nmod candidate_test;\n' ;;
    gated-bare) printf '#[cfg(test)]\nmod candidate;\n' ;;
    # The gate need not be the last attribute: a run of column-zero outer
    # attributes carries it to the declaration. crates/core has two files
    # written this way (engine/desired/hold.rs, quality/rules/content/fetch/tokens.rs).
    attribute-run) printf '#[cfg(test)]\n#[allow(clippy::unwrap_used)]\nmod candidate;\n' ;;
    # Nor lead it. The TRAILING attribute is what makes this discriminating:
    # it is the line the attribute-carry rule has to carry a pending gate
    # across; with the gate leading, there is no gate yet to carry.
    gate-sandwiched) printf '#[allow(dead_code)]\n#[cfg(test)]\n#[allow(unused)]\nmod candidate;\n' ;;
    gated-pub) printf '#[cfg(test)]\npub mod candidate;\n' ;;
    gated-pub-crate) printf '#[cfg(test)]\npub(crate) mod candidate;\n' ;;
    ungated-bare) printf 'mod candidate;\n' ;;
    gated-and-ungated) printf '#[cfg(test)]\n#[path = "candidate.rs"]\nmod candidate_test;\nmod candidate;\n' ;;
    # An attribute binds to the next line only.
    stale-gate) printf '#[cfg(test)]\nfn helper() {}\n\nmod candidate;\n' ;;
    # The scan is line-based: a declaration written flush left inside a block
    # comment is read as a real one. Documented in DEVELOPMENT.md and the
    # git-diff-summary header; pinned here so the claim reds if it stops holding.
    commented-out) printf '/*\n#[cfg(test)]\nmod candidate;\n*/\n' ;;
    none) printf 'pub fn unrelated() -> u32 {\n    1\n}\n' ;;
    # The gate sits in an ancestor directory's module, reached through a
    # #[path] that walks down into the candidate's directory.
    nested-path) printf '#[cfg(test)]\n#[path = "inner/candidate.rs"]\nmod candidate_test;\n' ;;
    *) echo "UNKNOWN-DECL: $1" >&2; exit 2 ;;
  esac
}

# --- the staged bodies -------------------------------------------------------------
body_of() {
  case "$1" in
    unwrap) printf 'pub fn parse(value: &str) -> u32 {\n    value.parse().unwrap()\n}\n' ;;
    # every Rust-only flag at once
    ffi) printf 'use std::sync::atomic::AtomicUsize;\n\n#[repr(C)]\npub struct Packet {\n    value: AtomicUsize,\n}\n\nextern "C" {\n    fn ffi_entry();\n}\n\npub unsafe fn call_ffi() {\n    ffi_entry();\n}\n' ;;
    # a panic and an unwrap inside the #[cfg(test)] module of a production file
    cfg-test-mod) printf 'pub fn add(a: u32, b: u32) -> u32 {\n    a + b\n}\n\n#[cfg(test)]\nmod tests {\n    use super::*;\n\n    #[test]\n    fn adds() {\n        let sum: u32 = "3".parse().unwrap();\n        assert_eq!(add(1, 2), sum);\n        if sum == 0 {\n            panic!("unreachable");\n        }\n    }\n}\n' ;;
    # a production unwrap beside a #[cfg(test)] one
    mixed) printf 'pub fn parse(s: &str) -> u32 {\n    s.parse().unwrap()\n}\n\n#[cfg(test)]\nmod tests {\n    #[test]\n    fn parses() {\n        assert_eq!(super::parse("3"), "3".parse::<u32>().unwrap());\n    }\n}\n' ;;
    # the attribute consumed by a braceless item, so the fn below it is production
    braceless-gate) printf '#[cfg(test)]\nuse std::fmt;\n\npub fn parse(s: &str) -> u32 {\n    s.parse().unwrap()\n}\n' ;;
    test-unwrap) printf '#[test]\nfn roundtrip() {\n    let v: u32 = "7".parse().unwrap();\n    assert_eq!(v, 7);\n}\n' ;;
    test-panic) printf '#[test]\nfn api() {\n    panic!("not yet implemented");\n}\n' ;;
    # the Rust-looking tokens as prose in a script and a document
    script) printf '#!/usr/bin/env bash\n# Detect unsafe changes in scripts; this is prose/regex text, not Rust code.\n# Other Rust-looking tokens in non-Rust files: #[repr(C)], extern "C", AtomicUsize.\necho unsafe change marker\n' ;;
    doc) printf 'Document unsafe migration notes, #[repr(C)] examples, extern "C" examples, and Atomic types.\n' ;;
    # Every flag on the first lines, then more than two 64 KB pipe buffers of
    # comment: an early `grep -q` closes its pipe while the shell is still
    # writing the captured diff, and the match must survive that (the
    # precondition on its size is asserted below the table).
    large) printf 'use std::sync::atomic::AtomicUsize;\n#[repr(C)]\npub struct Early { value: AtomicUsize }\nextern "C" { fn ffi_entry(); }\npub unsafe fn first() { panic!("boom"); }\n'
      awk 'BEGIN { line = "// "; for (i = 0; i < 500; i++) line = line "x"; for (i = 0; i < 264; i++) print line }' ;;
    *) echo "UNKNOWN-BODY: $1" >&2; exit 2 ;;
  esac
}

# --- the world ------------------------------------------------------------------------
REPO=""
ROW=0
build() {
  local w path body
  ROW=$((ROW + 1))
  REPO="$SANDBOX/$ROW"
  mkdir -p "$REPO"
  git -C "$REPO" init -q -b main
  git -C "$REPO" config user.email test@example.com
  git -C "$REPO" config user.name test
  git -C "$REPO" config commit.gpgsign false
  printf 'base\n' >"$REPO/README.md"
  git -C "$REPO" add README.md
  for w in "$@"; do
    case "$w" in
      decl:*) mkdir -p "$REPO/src"; decl_of "${w#decl:}" >"$REPO/src/lib.rs"; git -C "$REPO" add src/lib.rs ;;
      add:*) ;;
      *) echo "UNKNOWN-WORD: $w" >&2; exit 2 ;;
    esac
  done
  git -C "$REPO" commit -q -m base
  for w in "$@"; do
    [[ "$w" == add:* ]] || continue
    path="${w#add:}"; body="${path##*:}"; path="${path%:*}"
    mkdir -p "$REPO/${path%/*}"
    body_of "$body" >"$REPO/$path"
    git -C "$REPO" add "$path"
  done
}

run() {
  local json
  json="$("$SUMMARY" -C "$REPO" --staged)"
  printf 'flags=%s scope=%s' "$(jq -r '.risk_flags | if length == 0 then "-" else join(",") end' <<<"$json")" "$(jq -r '.scope' <<<"$json")"
}

run_table() {
  local title="$1" rows="$2" label world flags scope got row field before=$((PASS + FAIL))
  echo "=== $title ==="
  while IFS= read -r row; do
    [[ "$row" != "" ]] || continue
    IFS='|' read -r label world flags scope <<<"$row"
    for field in "$label" "$world" "$flags" "$scope"; do
      [[ "$field" != "" ]] || { printf 'a row with an empty field asserts nothing: %s\n' "$row" >&2; exit 1; }
    done
    # shellcheck disable=SC2086
    build $world
    got="$(run)"
    # A rendering aid for writing rows; the run is refused after the loop.
    if [[ "${GITHUB_TABLE_PROBE:-}" == 1 ]]; then
      printf '%s => %s\n' "$label" "$got"
      continue
    fi
    assert_eq "$got" "flags=$flags scope=$scope" "$label"
  done <<<"$rows"
  [[ "$((PASS + FAIL))" -gt "$before" ]] || { echo "no row was asserted (a probe run renders rows instead)" >&2; exit 2; }
}

RUST_FLAGS=unsafe_code_added,repr_c_struct_changed,extern_c_changed,atomics_modified

run_table "the risk flags and the scope" "\
the Rust-only tokens in a script and a document are prose: no flag|add:tools/validate:script add:docs/risk.md:doc|-|support
a Rust file earns every Rust-only flag, in the scanner's order|add:src/lib.rs:ffi|$RUST_FLAGS|production
a match on the first lines survives a diff larger than two pipe buffers|add:mycrate/tests/large.rs:large|$RUST_FLAGS,test_panic_path_added|support
a production unwrap is a panic path|add:src/lib.rs:unwrap|panic_path_added|production
a panic in the #[cfg(test)] module of a production file is a test panic path|add:src/lib.rs:cfg-test-mod|test_panic_path_added|production
a production unwrap beside a #[cfg(test)] one carries both flags|add:src/lib.rs:mixed|panic_path_added,test_panic_path_added|production
a #[cfg(test)] consumed by a braceless item does not reach the fn below it|add:src/lib.rs:braceless-gate|panic_path_added|production
a tests/ dir and a *_tests.rs file are test context by path|add:mycrate/tests/integration.rs:test-unwrap add:mycrate/src/api_tests.rs:test-panic|test_panic_path_added|support
a file reached only through a #[cfg(test)] #[path] declaration is test scope|decl:gated-path add:src/candidate.rs:unwrap|test_panic_path_added|support
through a gated bare declaration|decl:gated-bare add:src/candidate.rs:unwrap|test_panic_path_added|support
the gate is carried across a following attribute|decl:attribute-run add:src/candidate.rs:unwrap|test_panic_path_added|support
and read wherever it sits in the run|decl:gate-sandwiched add:src/candidate.rs:unwrap|test_panic_path_added|support
a pub declaration is read|decl:gated-pub add:src/candidate.rs:unwrap|test_panic_path_added|support
a pub(crate) declaration is read|decl:gated-pub-crate add:src/candidate.rs:unwrap|test_panic_path_added|support
a bare declaration resolves to the directory form too|decl:gated-bare add:src/candidate/mod.rs:unwrap|test_panic_path_added|support
the gate in an ancestor module's #[path] reaches down a directory|decl:nested-path add:src/inner/candidate.rs:unwrap|test_panic_path_added|support
an ungated declaration is production|decl:ungated-bare add:src/candidate.rs:unwrap|panic_path_added|production
one ungated declaration beside a gated one is production|decl:gated-and-ungated add:src/candidate.rs:unwrap|panic_path_added|production
a #[cfg(test)] on an unrelated item does not gate the declaration below it|decl:stale-gate add:src/candidate.rs:unwrap|panic_path_added|production
a declaration flush left inside a block comment is read as real (line-based scan)|decl:commented-out add:src/candidate.rs:unwrap|test_panic_path_added|support
no declaration at all is production|decl:none add:src/candidate.rs:unwrap|panic_path_added|production
"

# The large body must outrun two 64 KB pipe buffers for its row to test the
# early close: git is not the producer, scan_diff drains git diff into a shell
# variable and the writer is the shell replaying that string, so under one
# buffer it never blocks and the bug cannot appear. wc -c measures the file, a
# lower bound on the piped string, which carries a + per line on top of it.
large_bytes="$(body_of large | wc -c | tr -d ' ')"
[[ "$large_bytes" -ge $((2 * 65536)) ]] && large_size=ok || large_size="$large_bytes bytes"
assert_eq "$large_size" ok "the large body is a fixture that outruns two 64 KB pipe buffers"

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
