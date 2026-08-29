#!/usr/bin/env bash
# Pins what tools/guard still judges once the shipped packages judge the
# rest: the size-ratchet baseline may only tighten unless RATCHET_RAISE=1
# says otherwise, the fragment format the collator refuses is refused at
# commit too, and the [Unreleased] list gains lines only under
# CHANGELOG_COLLATE=1 — a verdict that must not turn on the caller's
# collation.
# It also pins the absence — a line cap, a work marker, a blanket allow, an
# oversized file and an over-long changelog entry all pass here, because
# size-ratchet, todo-ban, suppression-ban, byte-ceiling and changelog-entries
# are the judges of those. The failing direction runs first so a green pass is
# evidence, not a check that cannot fail.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$(cd "$TEST_DIR/.." && pwd)/guard"
REPO="$(cd "$TEST_DIR/../.." && pwd)"
RATCHET="$REPO/.agents/skills/size-ratchet/scripts/size-ratchet"
CHANGELOG_ENTRIES="$REPO/.agents/skills/growth-guards/scripts/changelog-entries"
REAL_GIT="$(command -v git)"
REAL_CARGO="$(command -v cargo)"
# Enforcement in this repo rests on this key, and a glob matching no tracked
# file is a documented clean pass — so a hardcoded copy here would stay green
# after the key stopped reaching the fragment tree.
CHANGELOG_PATHS="$(sed -n 's/^GROWTH_GUARDS_CHANGELOG_PATHS = "\(.*\)"$/\1/p' "$REPO/kendex.settings.toml")"
# The repo's own classes line, read where it lives: the seam pinned below is
# between two judges reading one policy, so the test may not restate it.
CLASSES="$(sed -n 's/^SIZE_RATCHET_CLASSES = "\(.*\)"$/\1/p' "$REPO/kendex.settings.toml")"
TMP="$(mktemp -d)"
mkdir -p "$TMP/nohooks"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }

R="$TMP/repo"
mkdir -p "$R/.claude" "$R/tools"
mkdir -p "$R/crates/core/tests"
git -C "$R" init -q
git -C "$R" symbolic-ref HEAD refs/heads/main
git -C "$R" config user.email test@example.com
git -C "$R" config user.name test
git -C "$R" config core.hooksPath "$TMP/nohooks"
echo '# fixture' >"$R/AGENTS.md"
ln -s ../AGENTS.md "$R/.claude/CLAUDE.md"
: >"$R/tools/size-ratchet-baseline.tsv"
printf '%s\n' \
  'fn existing_fixture() {' \
  '    let tmp = tempfile::tempdir().unwrap();' \
  '    drop(tmp);' \
  '}' >"$R/crates/core/tests/existing_temp.rs"
# The fragment format is changelog-collate's verdict and guard runs it, so
# the fixture carries the collator the way a clone does.
cp "$(cd "$TEST_DIR/.." && pwd)/changelog-collate" "$R/tools/changelog-collate"
git -C "$R" add -A
git -C "$R" commit -q -m fixture

mkfile() { # PATH LINES
  mkdir -p "$R/$(dirname "$1")"
  awk -v n="$2" 'BEGIN { for (i = 1; i <= n; i++) print "// line " i }' >"$R/$1"
}

baseline() { # ROW...
  printf '%s\n' "$@" >"$R/tools/size-ratchet-baseline.tsv"
}

run_guard() { # [VAR=VALUE...] — sets OUT and RC
  OUT=""
  RC=0
  OUT="$(cd "$R" && env "$@" "$GUARD" 2>&1)" || RC=$?
}

run_ratchet() { # sets OUT and RC — the repo's classes, nothing else
  OUT=""
  RC=0
  OUT="$(cd "$R" && env SIZE_RATCHET_CLASSES="$CLASSES" "$RATCHET" 2>&1)" || RC=$?
}

TAB="$(printf '\t')"

echo "=== new temporary fixtures derive their canonical root at creation ==="
mkdir -p "$R/crates/core/tests"
temp_case() { # pass|refuse LABEL SOURCE-LINE...
  local expected=$1 label=$2
  shift 2
  printf '%s\n' "$@" >"$R/crates/core/tests/temp_path.rs"
  git -C "$R" add -A
  run_guard RATCHET_RAISE=
  if [ "$expected" = pass ] && [ "$RC" -eq 0 ]; then
    ok "$label"
  elif [ "$expected" = refuse ] && [ "$RC" -ne 0 ] && [[ "$OUT" == *"direct tempfile constructor added"* ]]; then
    ok "$label"
  else
    bad "$label" "rc=$RC out=$OUT"
  fi
}

for constructor in \
  'tempfile::tempdir().unwrap()' \
  'tempfile::TempDir::new().unwrap()' \
  'tempfile::tempdir_in(".").unwrap()' \
  'tempfile::TempDir::with_prefix("fixture").unwrap()' \
  'tempfile::TempDir::with_prefix_in("fixture", ".").unwrap()' \
  'tempfile::Builder::new().tempdir().unwrap()' \
  'tempfile::Builder::new().tempdir_in(".").unwrap()'; do
  temp_case refuse "direct fixture ownership is refused for $constructor" \
    'fn fixture() {' " let _tmp = $constructor;" '}'
done
temp_case refuse "an imported tempdir function is refused" \
  'use tempfile::tempdir;' 'fn fixture() {' ' let _tmp = tempdir().unwrap();' '}'
temp_case refuse "an imported TempDir constructor is refused" \
  'use tempfile::TempDir;' 'fn fixture() {' ' let _tmp = TempDir::new_in(".").unwrap();' '}'
temp_case refuse "a multiline Builder constructor is refused" \
  'fn fixture() {' ' let _tmp = tempfile::Builder::new()' ' .prefix("fixture")' ' .tempdir()' ' .unwrap();' '}'
temp_case refuse "a split free-function call is refused" \
  'fn fixture() {' ' let _tmp = tempfile::tempdir' ' ();' '}'
temp_case refuse "an aliased tempfile import is refused" \
  'use tempfile::tempdir as make_fixture;' 'fn fixture() {' ' let _tmp = make_fixture();' '}'
temp_case pass "RootedTempDir owns and exposes the canonical fixture root" \
  'struct World { fixture: kendex_test_support::RootedTempDir }' 'fn fixture() {' ' let world = World { fixture: kendex_test_support::RootedTempDir::new().unwrap() };' ' let root = world.fixture.path();' ' drop(root);' '}'
temp_case pass "same-name non-temporary path owners do not trigger" \
  'fn fixture() {' ' let tmp = ProjectFixture::new();' ' let root = tmp.path();' ' drop(root);' '}'
temp_case pass "comments and strings that mention tempfile constructors pass" \
  'fn prose() {' ' // let tmp = tempfile::tempdir().unwrap();' ' let shown = "tempfile::TempDir::new()";' ' drop(shown);' '}'
temp_case pass "multiline raw strings that mention constructors pass" \
  'fn prose() {' ' let shown = r#"' ' tempfile::tempdir()' ' tempfile::TempDir::new()' ' "#;' ' drop(shown);' '}'
temp_case refuse "a line-comment glob cannot hide a later constructor" \
  'fn fixture() {' ' // fixtures live under crates/*/tests' ' let _tmp = tempfile::tempdir().unwrap();' '}'
temp_case refuse "an imported path sink cannot make a raw owner compliant" \
  'use helpers::accepts_path;' 'fn fixture() {' ' let tmp = tempfile::tempdir().unwrap();' ' accepts_path(&tmp);' '}'

mkdir -p "$R/crates/core/tests/split_fixture"
printf '%s\n' 'pub struct World { pub tmp: tempfile::TempDir }' 'pub fn world() -> World { World { tmp: tempfile::tempdir().unwrap() } }' >"$R/crates/core/tests/split_fixture/main.rs"
printf '%s\n' 'use super::*;' 'fn raw(world: &World) { let _ = world.tmp.path(); }' >"$R/crates/core/tests/split_fixture/uses.rs"
git -C "$R" add -A
run_guard RATCHET_RAISE=
[ "$RC" -ne 0 ] && case "$OUT" in *"split_fixture/main.rs"*"direct tempfile constructor added"*) true ;; *) false ;; esac \
  && ok "a split-module raw TempDir owner is refused" \
  || bad "a split-module raw TempDir owner is refused" "rc=$RC out=$OUT"
git -C "$R" reset -q HEAD -- crates/core/tests/split_fixture/main.rs crates/core/tests/split_fixture/uses.rs
rm -f "$R/crates/core/tests/split_fixture/main.rs" "$R/crates/core/tests/split_fixture/uses.rs"
rmdir "$R/crates/core/tests/split_fixture"

git -C "$R" config color.diff always
temp_case refuse "colored diff output cannot hide a direct constructor" \
  'fn fixture() {' ' let _tmp = tempfile::tempdir().unwrap();' '}'
git -C "$R" config --unset color.diff

mkdir -p "$R/fake-bin"
cat >"$R/fake-bin/git" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
is_temp_diff=0
if [ "${1:-}" = diff ]; then
  for arg in "$@"; do
    [ "$arg" = "--unified=0" ] && is_temp_diff=$((is_temp_diff + 1))
    [ "$arg" = "crates/*/tests/*.rs" ] && is_temp_diff=$((is_temp_diff + 1))
  done
fi
[ "${FAIL_TEMP_DIFF:-0}" -eq 1 ] && [ "$is_temp_diff" -eq 2 ] && exit 2
exec "$REAL_GIT" "$@"
SH
cat >"$R/fake-bin/cargo" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [ "${FAIL_TEMP_CHECK:-0}" -eq 1 ] && [[ "$*" == *temp-fixture-check* ]]; then
  exit 2
fi
exec "$REAL_CARGO" "$@"
SH
chmod +x "$R/fake-bin/git" "$R/fake-bin/cargo"
run_guard RATCHET_RAISE= PATH="$R/fake-bin:$PATH" REAL_GIT="$REAL_GIT" REAL_CARGO="$REAL_CARGO" FAIL_TEMP_DIFF=1
[ "$RC" -ne 0 ] && case "$OUT" in *"test fixture changes could not be read"*) true ;; *) false ;; esac \
  && ok "a failed fixture diff blocks guard" \
  || bad "a failed fixture diff blocks guard" "rc=$RC out=$OUT"
run_guard RATCHET_RAISE= PATH="$R/fake-bin:$PATH" REAL_GIT="$REAL_GIT" REAL_CARGO="$REAL_CARGO" FAIL_TEMP_CHECK=1
[ "$RC" -ne 0 ] && case "$OUT" in *"temporary fixture constructors could not be checked"*) true ;; *) false ;; esac \
  && ok "a failed fixture parser blocks guard" \
  || bad "a failed fixture parser blocks guard" "rc=$RC out=$OUT"
rm -f "$R/fake-bin/git" "$R/fake-bin/cargo"
git -C "$R" reset -q HEAD -- crates/core/tests/temp_path.rs
rm -f "$R/crates/core/tests/temp_path.rs"

echo "=== Apple test targets compile before the host suite ==="
mkdir -p "$R/fake-bin"
cat >"$R/fake-bin/rustup" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[ "$*" = "target list --installed" ]
[ "${RUSTUP_LIST_RESULT:-0}" -eq 0 ]
printf '%s\n' "${RUSTUP_INSTALLED_TARGETS:-}"
SH
cat >"$R/fake-bin/cargo" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$CARGO_CALL_LOG"
if [ "$*" = "check -p kendex-core -p kendex-cli --all-targets --target aarch64-apple-darwin" ]; then
  [ "${APPLE_CHECK_RESULT:-0}" -eq 0 ]
fi
SH
chmod +x "$R/fake-bin/rustup" "$R/fake-bin/cargo"
printf '[workspace]\n' >"$R/Cargo.toml"
git -C "$R" add Cargo.toml
CARGO_CALL_LOG="$TMP/cargo-calls"
: >"$CARGO_CALL_LOG"
run_guard RATCHET_RAISE= PATH="$R/fake-bin:$PATH" CARGO_CALL_LOG="$CARGO_CALL_LOG" RUSTUP_LIST_RESULT=1
[ "$RC" -ne 0 ] && case "$OUT" in *"rustup could not list installed targets"*) true ;; *) false ;; esac \
  && ok "a failed installed-target lookup blocks guard" \
  || bad "a failed installed-target lookup blocks guard" "rc=$RC out=$OUT"
run_guard RATCHET_RAISE= PATH="$R/fake-bin:$PATH" CARGO_CALL_LOG="$CARGO_CALL_LOG" RUSTUP_INSTALLED_TARGETS=x86_64-unknown-linux-gnu
[ "$RC" -ne 0 ] && case "$OUT" in *"Rust target aarch64-apple-darwin is not installed"*) true ;; *) false ;; esac \
  && ok "a missing Apple target is refused with the install command" \
  || bad "a missing Apple target is refused with the install command" "rc=$RC out=$OUT"
if grep -qF -- '--target aarch64-apple-darwin' "$CARGO_CALL_LOG"; then
  bad "a missing target is not handed to cargo" "$(cat "$CARGO_CALL_LOG")"
else
  ok "a missing target is not handed to cargo"
fi
: >"$CARGO_CALL_LOG"
run_guard RATCHET_RAISE= PATH="$R/fake-bin:$PATH" CARGO_CALL_LOG="$CARGO_CALL_LOG" RUSTUP_INSTALLED_TARGETS=aarch64-apple-darwin APPLE_CHECK_RESULT=1
[ "$RC" -ne 0 ] && case "$OUT" in *"Apple core and CLI test targets failed to compile"*) true ;; *) false ;; esac \
  && ok "a failing Apple compiler verdict blocks guard" \
  || bad "a failing Apple compiler verdict blocks guard" "rc=$RC out=$OUT"
[ "$(grep -cFx 'check -p kendex-core -p kendex-cli --all-targets --target aarch64-apple-darwin' "$CARGO_CALL_LOG")" -eq 1 ] \
  && ok "guard asks cargo for every core and CLI test target" \
  || bad "guard asks cargo for every core and CLI test target" "$(cat "$CARGO_CALL_LOG")"
run_guard RATCHET_RAISE= PATH="$R/fake-bin:$PATH" CARGO_CALL_LOG="$CARGO_CALL_LOG" RUSTUP_INSTALLED_TARGETS=aarch64-apple-darwin APPLE_CHECK_RESULT=0
[ "$RC" -eq 0 ] \
  && ok "an installed target and passing Apple check reach the host suite" \
  || bad "an installed target and passing Apple check reach the host suite" "rc=$RC out=$OUT"
git -C "$R" reset -q HEAD -- Cargo.toml
rm -f "$R/Cargo.toml"

echo "=== a baseline row this change adds is a raise ==="
mkfile crates/big.rs 401
baseline "crates/big.rs${TAB}401"
git -C "$R" add -A
run_guard RATCHET_RAISE=
[ "$RC" -ne 0 ] && case "$OUT" in *"baseline rows went up"*"new row: crates/big.rs"*) true ;; *) false ;; esac \
  && ok "a new baseline row fails, naming the path" \
  || bad "a new baseline row fails, naming the path" "rc=$RC out=$OUT"
run_guard RATCHET_RAISE=1
[ "$RC" -eq 0 ] && ok "RATCHET_RAISE=1 declares the new row" \
  || bad "RATCHET_RAISE=1 declares the new row" "rc=$RC out=$OUT"
git -C "$R" commit -q -m "chore: baseline the file"

echo "=== a row that goes up is a raise; one that goes down is not ==="
mkfile crates/big.rs 450
baseline "crates/big.rs${TAB}450"
git -C "$R" add -A
run_guard RATCHET_RAISE=
[ "$RC" -ne 0 ] && case "$OUT" in *"baseline rows went up"*"crates/big.rs: 401 -> 450"*) true ;; *) false ;; esac \
  && ok "a raised row fails, naming both counts" \
  || bad "a raised row fails, naming both counts" "rc=$RC out=$OUT"
run_guard RATCHET_RAISE=1
[ "$RC" -eq 0 ] && ok "RATCHET_RAISE=1 declares the raise" \
  || bad "RATCHET_RAISE=1 declares the raise" "rc=$RC out=$OUT"
baseline "crates/big.rs${TAB}380"
git -C "$R" add -A
run_guard RATCHET_RAISE=
[ "$RC" -eq 0 ] && ok "a tightened row passes without declaring anything" \
  || bad "a tightened row passes without declaring anything" "rc=$RC out=$OUT"

echo "=== the shipped packages' verdicts are not twinned here ==="
mkfile crates/uncapped.rs 401
mkfile ui/uncapped.ts 300
printf '// %s: unfinished\n' "TO""DO" >"$R/crates/marker.rs" # split, or todo-ban fails this file
printf '#![allow(dead_code)]\n' >"$R/crates/blanket.rs"
head -c 300000 /dev/zero | tr '\0' 'x' >"$R/crates/huge.bin"
mkdir -p "$R/changelog.d/fixed"
LONG="$(head -c 260 /dev/zero | tr '\0' 'e')"
printf -- '- %s\n' "$LONG" >"$R/changelog.d/fixed/ken-long.md"
git -C "$R" add -A
run_guard RATCHET_RAISE=
[ "$RC" -eq 0 ] \
  && ok "an over-cap file, a work marker, a blanket allow, a 300 KB file and an over-long changelog entry all pass — the packages judge those" \
  || bad "an over-cap file, a work marker, a blanket allow, a 300 KB file and an over-long changelog entry all pass — the packages judge those" "rc=$RC out=$OUT"
# The control for the entry: the package lane that owns it does refuse the
# same fragment under THIS repository's configured paths, so guard's silence
# is a delegation and not a gap, and the key is proven to reach the tree
# entries are written in.
CE_RC=0
(cd "$R" && env "GROWTH_GUARDS_CHANGELOG_PATHS=$CHANGELOG_PATHS" "$CHANGELOG_ENTRIES") >/dev/null 2>&1 || CE_RC=$?
[ "$CE_RC" -eq 1 ] \
  && ok "control: under the repo's own configured paths, changelog-entries refuses the fragment guard passed" \
  || bad "control: under the repo's own configured paths, changelog-entries refuses the fragment guard passed" "rc=$CE_RC paths=$CHANGELOG_PATHS"
rm -f "$R/crates/uncapped.rs" "$R/ui/uncapped.ts" "$R/crates/marker.rs" "$R/crates/blanket.rs" "$R/crates/huge.bin" "$R/changelog.d/fixed/ken-long.md"
git -C "$R" add -A

echo "=== the fragment format is the collator's verdict, carried by guard ==="
# Entry length belongs to the growth-guards changelog-entries lane, which runs
# before this one; the format is changelog-collate --check. One tool answers
# what a fragment is, another how long it may run.
mkdir -p "$R/changelog.d/fixed"
printf -- '- A fragment.\n' >"$R/changelog.d/fixed/ken-1.md"
git -C "$R" add -A
run_guard RATCHET_RAISE=
[ "$RC" -eq 0 ] && ok "a well-formed fragment passes" \
  || bad "a well-formed fragment passes" "rc=$RC out=$OUT"
# Keep a Changelog's six sections, written out rather than read from the
# accepted set: a list derived from the subject cannot catch that set being
# narrowed, which is the way this rule fails silently.
SECTION_DIRS="added changed deprecated removed fixed security"
for s in $SECTION_DIRS; do
  mkdir -p "$R/changelog.d/$s"
  printf -- '- An entry filed under %s.\n' "$s" >"$R/changelog.d/$s/ken-2.md"
done
git -C "$R" add -A
run_guard RATCHET_RAISE=
[ "$RC" -eq 0 ] && ok "a fragment under each of the six sections passes" \
  || bad "a fragment under each of the six sections passes" "rc=$RC out=$OUT"
for s in $SECTION_DIRS; do
  rm -f "$R/changelog.d/$s/ken-2.md"
  rmdir "$R/changelog.d/$s" 2>/dev/null || true
done
mkdir -p "$R/changelog.d/fixed"
printf -- '- A fragment.\n' >"$R/changelog.d/fixed/ken-1.md"
git -C "$R" add -A

printf -- '- Stray.\n' >"$R/changelog.d/loose.md"
git -C "$R" add -A
run_guard RATCHET_RAISE=
[ "$RC" -ne 0 ] && case "$OUT" in *"the collator refuses"*"changelog.d/loose.md is not a changelog fragment"*) true ;; *) false ;; esac \
  && ok "guard carries the collator's refusal, naming the file" \
  || bad "guard carries the collator's refusal, naming the file" "rc=$RC out=$OUT"
rm -f "$R/changelog.d/loose.md"
printf -- '- One entry.\n- A second entry.\n' >"$R/changelog.d/fixed/ken-3.md"
git -C "$R" add -A
run_guard RATCHET_RAISE=
[ "$RC" -ne 0 ] && case "$OUT" in *"changelog.d/fixed/ken-3.md holds more than the one entry"*) true ;; *) false ;; esac \
  && ok "a two-entry fragment is refused at commit, not at release" \
  || bad "a two-entry fragment is refused at commit, not at release" "rc=$RC out=$OUT"
rm -f "$R/changelog.d/fixed/ken-3.md"
git -C "$R" add -A
mv "$R/tools/changelog-collate" "$R/tools/changelog-collate.away"
run_guard RATCHET_RAISE=
mv "$R/tools/changelog-collate.away" "$R/tools/changelog-collate"
[ "$RC" -ne 0 ] && case "$OUT" in *"tools/changelog-collate is missing or not executable"*) true ;; *) false ;; esac \
  && ok "a missing collator fails closed, naming the check that could not run" \
  || bad "a missing collator fails closed, naming the check that could not run" "rc=$RC out=$OUT"
printf '# changelog.d\n\nNot a list item either.\n' >"$R/changelog.d/README.md"
git -C "$R" add -A
run_guard RATCHET_RAISE=
[ "$RC" -eq 0 ] && ok "the README is not judged as a fragment" \
  || bad "the README is not judged as a fragment" "rc=$RC out=$OUT"

echo "=== the [Unreleased] list is the collator's to write ==="
# The rule compares the work tree against HEAD, so HEAD has to carry the file.
printf '# Changelog\n\n## [Unreleased]\n\n### Fixed\n\n- A wrapped entry\n  second line\n  third line.\n- One line.\n' >"$R/CHANGELOG.md"
git -C "$R" add -A
git -C "$R" commit -q -m "chore: land the changelog"
printf '# Changelog\n\n## [Unreleased]\n\n### Fixed\n\n- A wrapped entry\n  second line\n  third line.\n- One line.\n- A hand-written line.\n' >"$R/CHANGELOG.md"
git -C "$R" add -A
run_guard RATCHET_RAISE=
[ "$RC" -ne 0 ] && case "$OUT" in *"gained lines under [Unreleased]"*"- A hand-written line."*) true ;; *) false ;; esac \
  && ok "a hand-written [Unreleased] line fails, quoting the line" \
  || bad "a hand-written [Unreleased] line fails, quoting the line" "rc=$RC out=$OUT"
run_guard RATCHET_RAISE= CHANGELOG_COLLATE=1
[ "$RC" -eq 0 ] && ok "CHANGELOG_COLLATE=1 declares the collator's write" \
  || bad "CHANGELOG_COLLATE=1 declares the collator's write" "rc=$RC out=$OUT"
printf '# Changelog\n\n## [Unreleased]\n\n## [1.0.0] - 2026-01-01\n\n### Fixed\n\n- A wrapped entry\n  second line\n  third line.\n- One line.\n' >"$R/CHANGELOG.md"
git -C "$R" add -A
run_guard RATCHET_RAISE=
[ "$RC" -eq 0 ] && ok "rotating [Unreleased] into a released version adds no line" \
  || bad "rotating [Unreleased] into a released version adds no line" "rc=$RC out=$OUT"
if [ "$(id -u)" -ne 0 ]; then
  chmod 000 "$R/CHANGELOG.md"
  run_guard RATCHET_RAISE=
  chmod 644 "$R/CHANGELOG.md"
  [ "$RC" -ne 0 ] && case "$OUT" in *"could not be compared against HEAD"*) true ;; *) false ;; esac \
    && ok "an unreadable CHANGELOG fails the [Unreleased] rule closed too" \
    || bad "an unreadable CHANGELOG fails the [Unreleased] rule closed too" "rc=$RC out=$OUT"
fi
# Blank lines are not content. Padding alone cannot refuse — a blank-only
# result strips to the empty string before the test that quotes it — so what
# keeping blanks out of the compared sets holds is the diagnostic: the lines
# it quotes are the lines an author has to act on.
printf '# Changelog\n\n## [Unreleased]\n\n### Fixed\n\n- One line.\n\n- Another line.\n\n## [1.0.0] - 2026-01-01\n' >"$R/CHANGELOG.md"
git -C "$R" add -A
git -C "$R" commit -q -m "chore: rotate the changelog"
printf '# Changelog\n\n## [Unreleased]\n\n### Fixed\n\n- One line.\n\n\n\n- Another line.\n\n- A real new line.\n\n## [1.0.0] - 2026-01-01\n' >"$R/CHANGELOG.md"
git -C "$R" add -A
run_guard RATCHET_RAISE=
[ "$RC" -ne 0 ] && case "$OUT" in *"gained lines under [Unreleased]"*"- A real new line."*) true ;; *) false ;; esac \
  && ok "an entry added beside blank padding is refused, quoting the entry" \
  || bad "an entry added beside blank padding is refused, quoting the entry" "rc=$RC out=$OUT"
[ "$(printf '%s\n' "$OUT" | grep -c '^  $')" -eq 0 ] \
  && ok "the padding itself is not quoted back as a gained line" \
  || bad "the padding itself is not quoted back as a gained line" "$OUT"

echo "=== the [Unreleased] verdict does not turn on the caller's collation ==="
# comm and its inputs must agree on one order. These lines sort one way by
# byte and another under a locale that folds punctuation, so a mismatch makes
# comm call a sorted file unsorted and name lines nobody wrote.
UR='# Changelog\n\n## [Unreleased]\n\n### Fixed\n\n- **Breaking:** alpha.\n- plain beta.\n- `code` gamma.\n- Zeta delta.\n'
printf "$UR" >"$R/CHANGELOG.md"
git -C "$R" add -A
git -C "$R" commit -q -m "chore: a changelog that sorts two ways"
# The locale is discovered from the file under test: any installed one whose
# order over these very lines differs from byte order will do.
COLLATE_LOCALE=""
for cand in $(locale -a 2>/dev/null); do
  case "$cand" in C | C.* | POSIX) continue ;; esac
  LC_ALL="$cand" sort "$R/CHANGELOG.md" >"$TMP/loc" 2>/dev/null || continue
  LC_ALL=C sort "$R/CHANGELOG.md" >"$TMP/byte"
  cmp -s "$TMP/loc" "$TMP/byte" && continue
  COLLATE_LOCALE="$cand"
  break
done
if [ -z "$COLLATE_LOCALE" ]; then
  echo "  note  no installed locale orders these lines differently from C — the collation pair cannot run here"
else
  printf '# Changelog\n\n## [Unreleased]\n\n### Fixed\n\n- **Breaking:** alpha.\n- plain beta.\n- `code` gamma.\n' >"$R/CHANGELOG.md"
  git -C "$R" add -A
  run_guard RATCHET_RAISE= LC_ALL="$COLLATE_LOCALE"
  [ "$RC" -eq 0 ] && ok "a deletion-only edit passes under $COLLATE_LOCALE" \
    || bad "a deletion-only edit passes under $COLLATE_LOCALE" "rc=$RC out=$OUT"
  printf "$UR"'- A hand-written line.\n' >"$R/CHANGELOG.md"
  git -C "$R" add -A
  run_guard RATCHET_RAISE= LC_ALL="$COLLATE_LOCALE"
  [ "$RC" -ne 0 ] && case "$OUT" in *"gained lines under [Unreleased]"*"- A hand-written line."*) true ;; *) false ;; esac \
    && ok "under $COLLATE_LOCALE the one added line is the only one named" \
    || bad "under $COLLATE_LOCALE the one added line is the only one named" "rc=$RC out=$OUT"
  case "$OUT" in *Breaking*) bad "no untouched line is named as gained" "$OUT" ;; *) ok "no untouched line is named as gained" ;; esac
fi

echo "=== a second copy of an entry is a line the tree gained ==="
printf "$UR"'- Zeta delta.\n' >"$R/CHANGELOG.md"
git -C "$R" add -A
run_guard RATCHET_RAISE=
[ "$RC" -ne 0 ] && case "$OUT" in *"gained lines under [Unreleased]"*"- Zeta delta."*) true ;; *) false ;; esac \
  && ok "a duplicated [Unreleased] line fails, quoting it" \
  || bad "a duplicated [Unreleased] line fails, quoting it" "rc=$RC out=$OUT"
printf "$UR" >"$R/CHANGELOG.md"
git -C "$R" add -A
run_guard RATCHET_RAISE=
[ "$RC" -eq 0 ] && ok "control: the same file with no duplicate passes" \
  || bad "control: the same file with no duplicate passes" "rc=$RC out=$OUT"

echo "=== a test row RATCHET_RAISE declares is still refused by the ratchet ==="
# Guard judges the declaration; the ratchet judges the row. A test is never
# raised, so the declaration does not carry it — and the seam only holds if
# the two are asked in the same repo state.
mkfile crates/big.rs 450
mkfile ui/x.test.ts 800
baseline "crates/big.rs${TAB}450"
git -C "$R" add -A
run_ratchet
[ "$RC" -eq 0 ] && ok "control: a test exactly at its class threshold needs no row" \
  || bad "control: a test exactly at its class threshold needs no row" "rc=$RC out=$OUT"
mkfile ui/x.test.ts 801
baseline "crates/big.rs${TAB}450" "ui/x.test.ts${TAB}801"
git -C "$R" add -A
run_guard RATCHET_RAISE=1
[ "$RC" -eq 0 ] && ok "guard takes the declaration for both new rows" \
  || bad "guard takes the declaration for both new rows" "rc=$RC out=$OUT"
run_ratchet
[ "$RC" -eq 1 ] && case "$OUT" in *"test baseline row added: ui/x.test.ts"*) true ;; *) false ;; esac \
  && ok "the ratchet refuses the test row the declaration would have carried" \
  || bad "the ratchet refuses the test row the declaration would have carried" "rc=$RC out=$OUT"
case "$OUT" in *"crates/big.rs"*) bad "the non-test row raised in the same diff is not refused" "$OUT" ;; *) ok "the non-test row raised in the same diff is not refused" ;; esac

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
