#!/usr/bin/env bash
# Pins what tools/guard still judges once the shipped packages judge the
# rest: new test fixtures take their canonical root at creation, and that is
# nearly all of it.
# It also pins the absence — a size cap, an undeclared size-ratchet row, a
# work marker, a blanket allow, an oversized file, a malformed fragment, an
# over-long changelog entry and a hand edit under [Unreleased] all pass here;
# size-ratchet, todo-ban, suppression-ban, byte-ceiling and changelog-entries
# are the judges of those, and each delegation carries the control that proves
# its judge still refuses what guard let by. The failing direction runs first
# so a green pass is evidence, not a check that cannot fail.
set -euo pipefail

# Hermetic: the size-ratchet lane and the bare ratchet control below both read
# RATCHET_RAISE from the environment, and an exported one turns the undeclared
# row this suite refuses into a declared row it accepts.
unset SIZE_RATCHET_THRESHOLD SIZE_RATCHET_CLASSES SIZE_RATCHET_DEFAULT_CLASSES SIZE_RATCHET_FROZEN_CLASSES SIZE_RATCHET_BASELINE SIZE_RATCHET_EXCLUDES SIZE_RATCHET_SETTINGS_FILE RATCHET_RAISE 2>/dev/null || true

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$(cd "$TEST_DIR/.." && pwd)/guard"
REPO="$(cd "$TEST_DIR/../.." && pwd)"
CHANGELOG_ENTRIES="$REPO/.agents/skills/growth-guards/scripts/changelog-entries"
RATCHET="$REPO/.agents/skills/size-ratchet/scripts/size-ratchet"
REAL_GIT="$(command -v git)"
REAL_AWK="$(command -v awk)"
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

TAB="$(printf '\t')"

echo "=== new temporary fixtures derive their canonical root at creation ==="
mkdir -p "$R/crates/core/tests"
temp_case() { # pass|refuse LABEL SOURCE-LINE...
  local expected=$1 label=$2
  shift 2
  printf '%s\n' "$@" >"$R/crates/core/tests/temp_path.rs"
  git -C "$R" add -A
  run_guard
  if [ "$expected" = pass ] && [ "$RC" -eq 0 ]; then
    ok "$label"
  elif [ "$expected" = refuse ] && [ "$RC" -ne 0 ] && [[ "$OUT" == *"temporary fixture bypasses rooted()"* ]]; then
    ok "$label"
  else
    bad "$label" "rc=$RC out=$OUT"
  fi
}

temp_case refuse "tempfile::tempdir without rooted is refused" \
  'fn fixture() {' ' let tmp = tempfile::tempdir().unwrap();' ' drop(tmp);' '}'
temp_case refuse "TempDir::new without rooted is refused" \
  'fn fixture() {' ' let tmp = tempfile::TempDir::new().unwrap();' ' drop(tmp);' '}'
temp_case pass "a bound rooted fixture passes" \
  'fn fixture() {' ' let tmp = tempfile::tempdir().unwrap();' ' let home = &rooted(&tmp);' ' drop(home);' '}'
temp_case refuse "later raw access after rooted is refused" \
  'fn fixture() {' ' let tmp = tempfile::tempdir().unwrap();' ' let home = rooted(&tmp);' ' use_fixture(home);' ' use_fixture(tmp.path());' '}'
temp_case pass "later canonical binding use passes" \
  'fn fixture() {' ' let tmp = tempfile::tempdir().unwrap();' ' let home = rooted(&tmp);' ' use_fixture(home.join("project"));' '}'
temp_case pass "comments may sit between construction and rooted" \
  'fn fixture() {' ' let tmp = tempfile::tempdir().unwrap();' ' // The root enters here.' ' let home = rooted(&tmp);' ' drop(home);' '}'
temp_case pass "same-name non-temporary path owners do not trigger" \
  'fn fixture() {' ' let tmp = ProjectFixture::new();' ' let root = tmp.path();' ' drop(root);' '}'
temp_case pass "comments and strings that mention tempfile constructors pass" \
  'fn prose() {' ' // let tmp = tempfile::tempdir().unwrap();' ' let shown = "tempfile::TempDir::new()";' ' drop(shown);' '}'
temp_case refuse "a line-comment glob cannot hide a later unrooted fixture" \
  'fn fixture() {' ' // fixtures live under crates/*/tests' ' let _tmp = tempfile::tempdir().unwrap();' '}'

git -C "$R" config color.diff always
temp_case refuse "colored diff output cannot hide an unrooted fixture" \
  'fn fixture() {' ' let tmp = tempfile::tempdir().unwrap();' ' drop(tmp);' '}'
git -C "$R" config --unset color.diff

mkdir -p "$R/fake-bin"
cat >"$R/fake-bin/git" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
is_temp_diff=0
if [ "${1:-}" = diff ]; then
  for arg in "$@"; do
    [ "$arg" = "--unified=100000" ] && is_temp_diff=$((is_temp_diff + 1))
    [ "$arg" = "crates/*/tests/*.rs" ] && is_temp_diff=$((is_temp_diff + 1))
  done
fi
[ "${FAIL_TEMP_DIFF:-0}" -eq 1 ] && [ "$is_temp_diff" -eq 2 ] && exit 2
exec "$REAL_GIT" "$@"
SH
cat >"$R/fake-bin/awk" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [ "${FAIL_TEMP_AWK:-0}" -eq 1 ] && [[ "${1:-}" == *pending_text* ]]; then
  exit 2
fi
exec "$REAL_AWK" "$@"
SH
chmod +x "$R/fake-bin/git" "$R/fake-bin/awk"
run_guard PATH="$R/fake-bin:$PATH" REAL_GIT="$REAL_GIT" REAL_AWK="$REAL_AWK" FAIL_TEMP_DIFF=1
[ "$RC" -ne 0 ] && case "$OUT" in *"test fixture changes could not be read"*) true ;; *) false ;; esac \
  && ok "a failed fixture diff blocks guard" \
  || bad "a failed fixture diff blocks guard" "rc=$RC out=$OUT"
run_guard PATH="$R/fake-bin:$PATH" REAL_GIT="$REAL_GIT" REAL_AWK="$REAL_AWK" FAIL_TEMP_AWK=1
[ "$RC" -ne 0 ] && case "$OUT" in *"temporary fixture declarations could not be checked"*) true ;; *) false ;; esac \
  && ok "a failed fixture parser blocks guard" \
  || bad "a failed fixture parser blocks guard" "rc=$RC out=$OUT"
rm -f "$R/fake-bin/git" "$R/fake-bin/awk"
git -C "$R" reset -q HEAD -- crates/core/tests/temp_path.rs
rm -f "$R/crates/core/tests/temp_path.rs"

echo "=== every cross target's test targets compile before the host suite ==="
mkdir -p "$R/fake-bin"
cat >"$R/fake-bin/rustup" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[ "$*" = "target list --installed" ]
[ "${RUSTUP_LIST_RESULT:-0}" -eq 0 ]
# Space-separated in, one target per line out, the shape guard greps.
for t in ${RUSTUP_INSTALLED_TARGETS:-}; do printf '%s\n' "$t"; done
SH
cat >"$R/fake-bin/cargo" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$CARGO_CALL_LOG"
for t in ${CROSS_CHECK_FAIL:-}; do
  if [ "$*" = "check -p kendex-core -p kendex-cli --all-targets --target $t" ]; then
    exit 1
  fi
done
SH
chmod +x "$R/fake-bin/rustup" "$R/fake-bin/cargo"
printf '[workspace]\n' >"$R/Cargo.toml"
git -C "$R" add Cargo.toml
CARGO_CALL_LOG="$TMP/cargo-calls"
# The platforms the release builds and this host does not run. Written out
# here on purpose: a list read back from guard would pass whatever guard
# named.
APPLE=aarch64-apple-darwin
WINDOWS=x86_64-pc-windows-msvc
BOTH="$APPLE $WINDOWS"
check_call() { # TARGET — the one cargo line guard is allowed to run for it
  printf 'check -p kendex-core -p kendex-cli --all-targets --target %s' "$1"
}
: >"$CARGO_CALL_LOG"
run_guard PATH="$R/fake-bin:$PATH" CARGO_CALL_LOG="$CARGO_CALL_LOG" RUSTUP_LIST_RESULT=1
[ "$RC" -ne 0 ] && case "$OUT" in *"rustup could not list installed targets"*) true ;; *) false ;; esac \
  && ok "a failed installed-target lookup blocks guard" \
  || bad "a failed installed-target lookup blocks guard" "rc=$RC out=$OUT"
run_guard PATH="$R/fake-bin:$PATH" CARGO_CALL_LOG="$CARGO_CALL_LOG" RUSTUP_INSTALLED_TARGETS=x86_64-unknown-linux-gnu
[ "$RC" -ne 0 ] &&
  case "$OUT" in *"Rust target $APPLE is not installed"*) true ;; *) false ;; esac &&
  case "$OUT" in *"Rust target $WINDOWS is not installed"*) true ;; *) false ;; esac \
  && ok "every missing target is refused with its own install command" \
  || bad "every missing target is refused with its own install command" "rc=$RC out=$OUT"
if grep -qE -- "--target ($APPLE|$WINDOWS)\$" "$CARGO_CALL_LOG"; then
  bad "a missing target is not handed to cargo" "$(cat "$CARGO_CALL_LOG")"
else
  ok "a missing target is not handed to cargo"
fi
: >"$CARGO_CALL_LOG"
run_guard PATH="$R/fake-bin:$PATH" CARGO_CALL_LOG="$CARGO_CALL_LOG" RUSTUP_INSTALLED_TARGETS="$WINDOWS"
[ "$RC" -ne 0 ] && case "$OUT" in *"Rust target $APPLE is not installed"*) true ;; *) false ;; esac &&
  [ "$(grep -cFx "$(check_call "$WINDOWS")" "$CARGO_CALL_LOG")" -eq 1 ] \
  && ok "a missing target does not stop the targets after it" \
  || bad "a missing target does not stop the targets after it" "rc=$RC out=$OUT log=$(cat "$CARGO_CALL_LOG")"
for failing in "$APPLE" "$WINDOWS"; do
  : >"$CARGO_CALL_LOG"
  run_guard PATH="$R/fake-bin:$PATH" CARGO_CALL_LOG="$CARGO_CALL_LOG" RUSTUP_INSTALLED_TARGETS="$BOTH" CROSS_CHECK_FAIL="$failing"
  [ "$RC" -ne 0 ] && case "$OUT" in *"$failing core and CLI test targets failed to compile"*) true ;; *) false ;; esac \
    && ok "a failing $failing compiler verdict blocks guard, naming it" \
    || bad "a failing $failing compiler verdict blocks guard, naming it" "rc=$RC out=$OUT"
done
: >"$CARGO_CALL_LOG"
run_guard PATH="$R/fake-bin:$PATH" CARGO_CALL_LOG="$CARGO_CALL_LOG" RUSTUP_INSTALLED_TARGETS="$BOTH"
[ "$RC" -eq 0 ] \
  && ok "installed targets that all compile reach the host suite" \
  || bad "installed targets that all compile reach the host suite" "rc=$RC out=$OUT"
[ "$(grep -cFx "$(check_call "$APPLE")" "$CARGO_CALL_LOG")" -eq 1 ] &&
  [ "$(grep -cFx "$(check_call "$WINDOWS")" "$CARGO_CALL_LOG")" -eq 1 ] \
  && ok "guard asks cargo once for every cross target's core and CLI tests" \
  || bad "guard asks cargo once for every cross target's core and CLI tests" "$(cat "$CARGO_CALL_LOG")"
git -C "$R" reset -q HEAD -- Cargo.toml
rm -f "$R/Cargo.toml"

echo "=== the shipped packages' verdicts are not twinned here ==="
# HEAD has to carry a row set for the ratchet's added-row verdict to have
# anything to compare against: against an empty baseline every row reads as a
# bootstrap one, and the control below would pass without judging anything.
mkfile crates/existing.rs 401
baseline "crates/existing.rs${TAB}401"
git -C "$R" add -A
git -C "$R" commit -q -m "chore: a baseline with a row in it"
mkfile crates/uncapped.rs 401
# Both over the deciding threshold, in both of the repo's languages: the
# shipped list carries no ui entry, so a TypeScript file is judged by the 400
# default like any other unclassed path.
mkfile ui/uncapped.ts 401
printf '// %s: unfinished\n' "TO""DO" >"$R/crates/marker.rs" # split, or todo-ban fails this file
printf '#![allow(dead_code)]\n' >"$R/crates/blanket.rs"
head -c 300000 /dev/zero | tr '\0' 'x' >"$R/crates/huge.bin"
mkdir -p "$R/changelog.d/fixed"
LONG="$(head -c 260 /dev/zero | tr '\0' 'e')"
printf -- '- %s\n' "$LONG" >"$R/changelog.d/fixed/ken-long.md"
printf -- '- One entry.\n- A second entry.\n' >"$R/changelog.d/fixed/ken-two.md"
# The record rule compares the index against HEAD, so HEAD has to carry it —
# and this commit lands before the baseline row below, whose own verdict is
# "added since HEAD" and would read as carried if HEAD already had it.
printf '# Changelog\n\n## [Unreleased]\n\n### Fixed\n\n- One line.\n' >"$R/CHANGELOG.md"
git -C "$R" add -A
git -C "$R" commit -q -m "chore: land the changelog"
printf '# Changelog\n\n## [Unreleased]\n\n### Fixed\n\n- One line.\n- A hand-written line.\n' >"$R/CHANGELOG.md"
mkfile crates/rowed.rs 401
baseline "crates/existing.rs${TAB}401" "crates/rowed.rs${TAB}401"
git -C "$R" add -A
run_guard
[ "$RC" -eq 0 ] \
  && ok "an over-cap file, an undeclared baseline row, a work marker, a blanket allow, a 300 KB file, a malformed and an over-long fragment and a hand edit under [Unreleased] all pass — the packages judge those" \
  || bad "an over-cap file, an undeclared baseline row, a work marker, a blanket allow, a 300 KB file, a malformed and an over-long fragment and a hand edit under [Unreleased] all pass — the packages judge those" "rc=$RC out=$OUT"
case "$OUT" in *Unreleased* | *changelog* | *fragment*) bad "guard names neither changelog scope" "$OUT" ;; *) ok "guard names neither changelog scope" ;; esac
# The control for the row: size-ratchet itself refuses the same undeclared
# row, so guard's silence about baseline rows is a delegation and not a gap.
SR_OUT=""
SR_RC=0
SR_OUT="$(cd "$R" && "$RATCHET" 2>&1)" || SR_RC=$?
[ "$SR_RC" -eq 1 ] && case "$SR_OUT" in *"baseline row added: crates/rowed.rs"*) true ;; *) false ;; esac \
  && ok "control: size-ratchet refuses the undeclared row guard passed" \
  || bad "control: size-ratchet refuses the undeclared row guard passed" "rc=$SR_RC out=$SR_OUT"
# The control for the changelog: the package lane that owns both scopes
# refuses all three of those, so that silence is a delegation too.
CE_OUT=""
CE_RC=0
CE_OUT="$(cd "$R" && "$CHANGELOG_ENTRIES" 2>&1)" || CE_RC=$?
[ "$CE_RC" -eq 1 ] \
  && case "$CE_OUT" in *ken-long.md*) true ;; *) false ;; esac \
  && case "$CE_OUT" in *ken-two.md*) true ;; *) false ;; esac \
  && case "$CE_OUT" in *"gained lines under [Unreleased]"*) true ;; *) false ;; esac \
  && ok "control: changelog-entries refuses the long entry, the two-entry fragment and the hand edit guard passed" \
  || bad "control: changelog-entries refuses the long entry, the two-entry fragment and the hand edit guard passed" "rc=$CE_RC out=$CE_OUT"
rm -f "$R/crates/uncapped.rs" "$R/ui/uncapped.ts" "$R/crates/marker.rs" "$R/crates/blanket.rs" "$R/crates/huge.bin" "$R/changelog.d/fixed/ken-long.md" "$R/changelog.d/fixed/ken-two.md"
git -C "$R" checkout -q -- CHANGELOG.md
git -C "$R" add -A

echo "=== this suite isolates every RATCHET_ key the gate reads ==="
# The shipped package sweeps its OWN tests directory for this, and cannot
# reach a file outside it — so the one suite here that runs the gate (through
# guard's size-ratchet lane, and again as the control above) asserts it where
# it lives. The keys are derived from the script this suite actually runs, so
# a key added there is covered without anyone remembering this list.
ratchet_keys="$(grep -rhoE '[A-Z_]*RATCHET_[A-Z][A-Z_]*' "$(dirname "$RATCHET")" | LC_ALL=C sort -u)"
missing_keys=""
for key in $ratchet_keys; do
  grep -q "^unset .*$key" "${BASH_SOURCE[0]}" || missing_keys="$missing_keys $key"
done
[ -n "$ratchet_keys" ] && [ -z "$missing_keys" ] \
  && ok "this file's unset line names every RATCHET_ key the gate reads" \
  || bad "this file isolates the whole key set" "missing:$missing_keys derived:$ratchet_keys"
# Anti-vacuous: a derivation that found nothing, or one that missed the key
# outside the SIZE_RATCHET_ prefix, would pass the check above silently.
case "$ratchet_keys" in
  *RATCHET_RAISE*) ok "control: the derivation reaches RATCHET_RAISE, the key with no SIZE_ prefix" ;;
  *) bad "the derivation reaches RATCHET_RAISE" "derived:$ratchet_keys" ;;
esac

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
