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
# The symlink invariant reads .claude/CLAUDE.md's target, so the fixture
# carries the file that target names.
printf '# fixture\n' >"$R/AGENTS.md"
ln -s ../AGENTS.md "$R/.claude/CLAUDE.md"
: >"$R/tools/size-ratchet-baseline.tsv"
printf '%s\n' \
  'fn existing_fixture() {' \
  '    let tmp = tempfile::tempdir().unwrap();' \
  '    drop(tmp);' \
  '}' >"$R/crates/core/tests/existing_temp.rs"
# The bash32-lint lane runs on every pass and resolves its exception entries
# and its hand-named roster entries against the repository it runs in, so the
# fixture derives each rather than copying a list that goes stale with it. An
# exception directory holds no shell file; a roster one dies without one.
while IFS= read -r e; do
  mkdir -p "$R/$e" && printf 'not shell\n' >"$R/$e/README.md"
done < <(sed -n 's#^NO_\(SCAN\|SHELL\)="\(.*\)"$#\2#p' "$REPO/tools/bash32-lint" | tr ' ' '\n' | grep .)
while IFS= read -r e; do
  mkdir -p "$R/$e" && printf '#!/usr/bin/env bash\necho rostered\n' >"$R/$e/rostered.sh"
done < <(sed -n 's#^  set -- \(.*\)$#\1#p' "$REPO/tools/bash32-lint" | tr ' ' '\n' | grep -v '[*]')
mkdir -p "$R/skills/demo/scripts" "$R/skills/demo/tests" \
  "$R/.agents/skills/demo/scripts" "$R/.agents/skills/demo/tests" \
  "$R/agents" "$R/.claude/agents" "$R/.codex/agents" "$R/.pi/agents"
printf '#!/usr/bin/env bash\necho demo\n' >"$R/skills/demo/scripts/demo.sh"
printf '#!/usr/bin/env bash\necho tested\n' >"$R/skills/demo/tests/demo.test.sh"
printf '#!/usr/bin/env bash\necho accented\n' >"$R/skills/demo/scripts/frappé.sh"
cp "$R/skills/demo/scripts/demo.sh" "$R/.agents/skills/demo/scripts/demo.sh"
cp "$R/skills/demo/tests/demo.test.sh" "$R/.agents/skills/demo/tests/demo.test.sh"
cp "$R/skills/demo/scripts/frappé.sh" "$R/.agents/skills/demo/scripts/frappé.sh"
printf '# demo agent\n' >"$R/agents/demo.md"
printf '# demo agent render\n' >"$R/.claude/agents/demo.md"
printf 'name = "demo"\n' >"$R/.codex/agents/demo.toml"
printf '# demo agent render\n' >"$R/.pi/agents/demo.md"
# One hook rendered to two of the three harness directories and not the
# third, the way the real tree's hook sets differ, plus a hook test that
# renders nowhere.
mkdir -p "$R/hooks/tests" "$R/.claude/hooks" "$R/.codex/hooks" "$R/.pi/kendex/hooks"
printf '#!/usr/bin/env bash\necho hooked\n' >"$R/hooks/demo.sh"
printf '#!/usr/bin/env bash\necho hooked\n' >"$R/hooks/tests/demo.test.sh"
cp "$R/hooks/demo.sh" "$R/.claude/hooks/demo.sh"
cp "$R/hooks/demo.sh" "$R/.codex/hooks/demo.sh"
printf '#!/usr/bin/env bash\necho other\n' >"$R/.pi/kendex/hooks/other.sh"
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
temp_case pass "comments may sit between construction and rooted" \
  'fn fixture() {' ' let tmp = tempfile::tempdir().unwrap();' ' // The root enters here.' ' let home = rooted(&tmp);' ' drop(home);' '}'
temp_case pass "same-name non-temporary path owners do not trigger" \
  'fn fixture() {' ' let tmp = ProjectFixture::new();' ' let root = tmp.path();' ' drop(root);' '}'
temp_case pass "comments and strings that mention tempfile constructors pass" \
  'fn prose() {' ' // let tmp = tempfile::tempdir().unwrap();' ' let shown = "tempfile::TempDir::new()";' ' drop(shown);' '}'
temp_case refuse "a line-comment glob cannot hide a later unrooted fixture" \
  'fn fixture() {' ' // fixtures live under crates/*/tests' ' let _tmp = tempfile::tempdir().unwrap();' '}'
temp_case refuse "rooting a different binding does not clear the declaration" \
  'fn fixture() {' ' let tmp = tempfile::tempdir().unwrap();' ' let home = rooted(&other);' ' drop(home);' '}'
temp_case refuse "a string literal naming rooted does not clear the declaration" \
  'fn fixture() {' ' let tmp = tempfile::tempdir().unwrap();' ' let shown = "rooted(&tmp)";' ' drop(shown);' '}'

# A run of adjacent declarations is checked member by member: resolving one
# must not consume the line that declares the next.
printf '%s\n' 'fn fixture() {' ' let a = tempfile::tempdir().unwrap();' ' let b = tempfile::tempdir().unwrap();' ' let c = tempfile::tempdir().unwrap();' ' drop((a, b, c));' '}' >"$R/crates/core/tests/temp_path.rs"
git -C "$R" add -A
run_guard
if [ "$RC" -ne 0 ] && [[ "$OUT" == *"temp_path.rs:2"* ]] && [[ "$OUT" == *"temp_path.rs:3"* ]] && [[ "$OUT" == *"temp_path.rs:4"* ]]; then
  ok "every member of a run of unrooted declarations is named"
else
  bad "every member of a run of unrooted declarations is named" "rc=$RC out=$OUT"
fi

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

echo "=== the skill tree is 3.2-clean and renders land with their sources ==="
git -C "$R" checkout -q -- .
git -C "$R" clean -qfd
run_guard
[ "$RC" -eq 0 ] \
  && ok "a 3.2-clean skill tree with every render in step passes" \
  || bad "a 3.2-clean skill tree with every render in step passes" "rc=$RC out=$OUT"

# The controls below each remove one check from a copy of guard and expect
# the defect to pass, proving the red above it came from that check and not
# from a neighbour. The copy sits beside a copy of bash32-lint because guard
# resolves its sibling tools next to itself.
MUTANT_TOOLS="$TMP/mutant-tools"
mkdir -p "$MUTANT_TOOLS"
cp "$REPO/tools/bash32-lint" "$MUTANT_TOOLS/bash32-lint"
mutant_guard() { # SED-EXPR — stage a guard copy with that edit applied
  sed "$1" "$GUARD" >"$MUTANT_TOOLS/guard"
  chmod +x "$MUTANT_TOOLS/guard"
  ! cmp -s "$GUARD" "$MUTANT_TOOLS/guard"
}
run_mutant() { # — sets OUT and RC
  OUT=""
  RC=0
  OUT="$(cd "$R" && "$MUTANT_TOOLS/guard" 2>&1)" || RC=$?
}

BASH4_LINE='mapfile -t demo_lines <"$0"'
printf '%s\n' "$BASH4_LINE" >>"$R/skills/demo/tests/demo.test.sh"
printf '%s\n' "$BASH4_LINE" >>"$R/.agents/skills/demo/tests/demo.test.sh"
run_guard
[ "$RC" -ne 0 ] && [[ "$OUT" == *"tools/bash32-lint refused the tree"* ]] \
  && [[ "$OUT" == *"Bash 4+ constructs in shell that must run under Bash 3.2"* ]] \
  && [[ "$OUT" != *"without its tracked render"* ]] \
  && ok "a Bash 4 construct in a skill test reds the guard through the lint lane" \
  || bad "a Bash 4 construct in a skill test reds the guard through the lint lane" "rc=$RC out=$OUT"
if mutant_guard '/bash32-lint/d'; then
  run_mutant
  [ "$RC" -eq 0 ] \
    && ok "control: with the bash32-lint lane deleted the construct passes" \
    || bad "control: with the bash32-lint lane deleted the construct passes" "rc=$RC out=$OUT"
else
  bad "control: the bash32-lint lane could not be deleted from a guard copy"
fi
git -C "$R" checkout -q -- skills .agents

printf 'echo more\n' >>"$R/skills/demo/scripts/demo.sh"
run_guard
[ "$RC" -ne 0 ] && [[ "$OUT" == *"a render source changed without its tracked render"* ]] \
  && [[ "$OUT" == *"skills/demo/scripts/demo.sh -> .agents/skills/demo/scripts/demo.sh"* ]] \
  && ok "a source-only skill edit reds, naming the render left behind" \
  || bad "a source-only skill edit reds, naming the render left behind" "rc=$RC out=$OUT"
if mutant_guard '/\.agents\/\$f/d'; then
  run_mutant
  [ "$RC" -eq 0 ] \
    && ok "control: with the skills arm deleted the source-only edit passes" \
    || bad "control: with the skills arm deleted the source-only edit passes" "rc=$RC out=$OUT"
else
  bad "control: the skills render arm could not be deleted from a guard copy"
fi
printf 'echo more\n' >>"$R/.agents/skills/demo/scripts/demo.sh"
run_guard
[ "$RC" -eq 0 ] \
  && ok "the same edit with its render in the change passes" \
  || bad "the same edit with its render in the change passes" "rc=$RC out=$OUT"
git -C "$R" checkout -q -- skills .agents

# A deletion is in the changed set too, so a render removed beside a living
# source has to red; both gone together is a clean removal.
printf 'echo more\n' >>"$R/skills/demo/scripts/demo.sh"
rm -f "$R/.agents/skills/demo/scripts/demo.sh"
run_guard
[ "$RC" -ne 0 ] && [[ "$OUT" == *"skills/demo/scripts/demo.sh -> .agents/skills/demo/scripts/demo.sh"* ]] \
  && ok "a skill source edited with its render deleted reds, naming the render" \
  || bad "a skill source edited with its render deleted reds, naming the render" "rc=$RC out=$OUT"
if mutant_guard 's/ && { \[ ! -e "\$1" \] || \[ -e "\$2" \]; }//'; then
  run_mutant
  [ "$RC" -eq 0 ] \
    && ok "control: with the outlives clause deleted the deleted render passes" \
    || bad "control: with the outlives clause deleted the deleted render passes" "rc=$RC out=$OUT"
else
  bad "control: the outlives clause could not be deleted from a guard copy"
fi
rm -f "$R/skills/demo/scripts/demo.sh"
run_guard
[ "$RC" -eq 0 ] \
  && ok "a skill source deleted with its render passes" \
  || bad "a skill source deleted with its render passes" "rc=$RC out=$OUT"
git -C "$R" checkout -q -- skills .agents

# A path with a non-ASCII byte: git quotes it unless told not to, and the
# quoted spelling would slip past the case arm.
printf 'echo more\n' >>"$R/skills/demo/scripts/frappé.sh"
run_guard
[ "$RC" -ne 0 ] && [[ "$OUT" == *"skills/demo/scripts/frappé.sh -> .agents/skills/demo/scripts/frappé.sh"* ]] \
  && ok "a source-only edit to a non-ASCII path reds, naming the render left behind" \
  || bad "a source-only edit to a non-ASCII path reds, naming the render left behind" "rc=$RC out=$OUT"
if mutant_guard 's/-c core.quotePath=false //g'; then
  run_mutant
  [ "$RC" -eq 0 ] \
    && ok "control: with path quoting left on the non-ASCII edit passes" \
    || bad "control: with path quoting left on the non-ASCII edit passes" "rc=$RC out=$OUT"
else
  bad "control: path quoting could not be turned back on in a guard copy"
fi
git -C "$R" checkout -q -- skills .agents

# Rendered is judged at the tree, so a new file in a rendered skill owes a
# render the tree does not track yet.
printf '#!/usr/bin/env bash\necho added\n' >"$R/skills/demo/scripts/added.sh"
git -C "$R" add skills/demo/scripts/added.sh
run_guard
[ "$RC" -ne 0 ] && [[ "$OUT" == *"skills/demo/scripts/added.sh -> .agents/skills/demo/scripts/added.sh"* ]] \
  && ok "a new script in a rendered skill with no render reds, naming it" \
  || bad "a new script in a rendered skill with no render reds, naming it" "rc=$RC out=$OUT"
if mutant_guard '/\.agents\/\$f/d'; then
  run_mutant
  [ "$RC" -eq 0 ] \
    && ok "control: with the skills arm deleted the new script passes" \
    || bad "control: with the skills arm deleted the new script passes" "rc=$RC out=$OUT"
else
  bad "control: the skills render arm could not be deleted from a guard copy"
fi
cp "$R/skills/demo/scripts/added.sh" "$R/.agents/skills/demo/scripts/added.sh"
git -C "$R" add .agents/skills/demo/scripts/added.sh
run_guard
[ "$RC" -eq 0 ] \
  && ok "the new script with its render staged beside it passes" \
  || bad "the new script with its render staged beside it passes" "rc=$RC out=$OUT"
git -C "$R" reset -q HEAD -- skills .agents
rm -f "$R/skills/demo/scripts/added.sh" "$R/.agents/skills/demo/scripts/added.sh"

mkdir -p "$R/skills/other/scripts"
printf '#!/usr/bin/env bash\necho local\n' >"$R/skills/other/scripts/local-only.sh"
git -C "$R" add skills/other/scripts/local-only.sh
run_guard
[ "$RC" -eq 0 ] \
  && ok "a source in a skill with no tracked render passes" \
  || bad "a source in a skill with no tracked render passes" "rc=$RC out=$OUT"
git -C "$R" reset -q HEAD -- skills/other
rm -rf "$R/skills/other"

# A rendered skill whose name carries a regex metacharacter: the prefix test
# reads the name literally, or a bracket makes the match fail as not rendered.
mkdir -p "$R/skills/demo[1/scripts" "$R/.agents/skills/demo[1/scripts"
printf '#!/usr/bin/env bash\necho bracket\n' >"$R/skills/demo[1/scripts/b.sh"
cp "$R/skills/demo[1/scripts/b.sh" "$R/.agents/skills/demo[1/scripts/b.sh"
git -C "$R" add -A skills .agents
git -C "$R" commit -q -m "chore: a skill with a bracket in its name"
printf 'echo more\n' >>"$R/skills/demo[1/scripts/b.sh"
run_guard
[ "$RC" -ne 0 ] && [[ "$OUT" == *"skills/demo[1/scripts/b.sh -> .agents/skills/demo[1/scripts/b.sh"* ]] \
  && ok "a source-only edit in a skill named with a bracket reds, naming the render" \
  || bad "a source-only edit in a skill named with a bracket reds, naming the render" "rc=$RC out=$OUT"
if mutant_guard 's|^  case "\$NL\$render_tracked\$NL" in \*"\$NL\$1/"\*) return 0 ;; esac$|  grep -q -- "^$1/" <<<"$render_tracked" \&\& return 0|'; then
  run_mutant
  [ "$RC" -eq 0 ] \
    && ok "control: with the name read as a pattern the bracket edit passes" \
    || bad "control: with the name read as a pattern the bracket edit passes" "rc=$RC out=$OUT"
else
  bad "control: the literal prefix test could not be turned back into a pattern in a guard copy"
fi
git -C "$R" checkout -q -- skills .agents
git -C "$R" reset -q --hard HEAD~1

AGENT_RENDERS=(.claude/agents/demo.md .codex/agents/demo.toml .pi/agents/demo.md)
for r in "${AGENT_RENDERS[@]}"; do
  git -C "$R" checkout -q -- agents .claude/agents .codex .pi
  printf '# amended\n' >>"$R/agents/demo.md"
  for other in "${AGENT_RENDERS[@]}"; do
    [ "$other" = "$r" ] || printf '# amended\n' >>"$R/$other"
  done
  run_guard
  [ "$RC" -ne 0 ] && [[ "$OUT" == *"agents/demo.md -> $r"* ]] \
    && ok "an agent edit leaving $r behind reds, naming it" \
    || bad "an agent edit leaving $r behind reds, naming it" "rc=$RC out=$OUT"
done
git -C "$R" checkout -q -- agents .claude/agents .codex .pi
printf '# amended\n' >>"$R/agents/demo.md"
if mutant_guard '/^  agents\/\*\.md)$/,/^    ;;$/d'; then
  run_mutant
  [ "$RC" -eq 0 ] \
    && ok "control: with the agent render lines deleted the lone agent edit passes" \
    || bad "control: with the agent render lines deleted the lone agent edit passes" "rc=$RC out=$OUT"
else
  bad "control: the agent render lines could not be deleted from a guard copy"
fi
for other in "${AGENT_RENDERS[@]}"; do
  printf '# amended\n' >>"$R/$other"
done
run_guard
[ "$RC" -eq 0 ] \
  && ok "an agent edit landing all three renders passes" \
  || bad "an agent edit landing all three renders passes" "rc=$RC out=$OUT"
git -C "$R" checkout -q -- agents .claude/agents .codex .pi

printf '# amended\n' >>"$R/agents/demo.md"
printf '# amended\n' >>"$R/.codex/agents/demo.toml"
printf '# amended\n' >>"$R/.pi/agents/demo.md"
rm -f "$R/.claude/agents/demo.md"
run_guard
[ "$RC" -ne 0 ] && [[ "$OUT" == *"agents/demo.md -> .claude/agents/demo.md"* ]] \
  && [[ "$OUT" != *"-> .codex/agents/demo.toml"* ]] && [[ "$OUT" != *"-> .pi/agents/demo.md"* ]] \
  && ok "an agent edit with one harness render deleted reds, naming that render alone" \
  || bad "an agent edit with one harness render deleted reds, naming that render alone" "rc=$RC out=$OUT"
git -C "$R" checkout -q -- agents .claude/agents .codex .pi

# A new agent definition owes a render to every harness directory that
# tracks any, though none of its own is tracked yet. The control puts the
# per-file judgement back — a render owed only when it is already tracked.
printf '# fresh agent\n' >"$R/agents/fresh.md"
git -C "$R" add agents/fresh.md
run_guard
[ "$RC" -ne 0 ] && [[ "$OUT" == *"agents/fresh.md -> .claude/agents/fresh.md"* ]] \
  && [[ "$OUT" == *"agents/fresh.md -> .codex/agents/fresh.toml"* ]] \
  && [[ "$OUT" == *"agents/fresh.md -> .pi/agents/fresh.md"* ]] \
  && ok "a new agent definition with no render reds, naming all three" \
  || bad "a new agent definition with no render reds, naming all three" "rc=$RC out=$OUT"
if mutant_guard 's|^require_render() { |require_render() { git ls-files --error-unmatch -- "$2" >/dev/null 2>\&1 \|\| return 0; |'; then
  run_mutant
  [ "$RC" -eq 0 ] \
    && ok "control: with rendered judged per file the new agent passes" \
    || bad "control: with rendered judged per file the new agent passes" "rc=$RC out=$OUT"
else
  bad "control: the per-file judgement could not be put back in a guard copy"
fi
printf '# fresh agent render\n' >"$R/.claude/agents/fresh.md"
printf 'name = "fresh"\n' >"$R/.codex/agents/fresh.toml"
printf '# fresh agent render\n' >"$R/.pi/agents/fresh.md"
git -C "$R" add .claude/agents/fresh.md .codex/agents/fresh.toml .pi/agents/fresh.md
run_guard
[ "$RC" -eq 0 ] \
  && ok "the new agent with its three renders staged beside it passes" \
  || bad "the new agent with its three renders staged beside it passes" "rc=$RC out=$OUT"
git -C "$R" reset -q HEAD -- agents .claude/agents .codex .pi
rm -f "$R/agents/fresh.md" "$R/.claude/agents/fresh.md" "$R/.codex/agents/fresh.toml" "$R/.pi/agents/fresh.md"

# Hooks are judged per file: the two harness copies this hook already has
# are owed, the third harness directory is not, and a hook test that renders
# nowhere owes nothing.
printf 'echo more\n' >>"$R/hooks/demo.sh"
run_guard
[ "$RC" -ne 0 ] && [[ "$OUT" == *"hooks/demo.sh -> .claude/hooks/demo.sh"* ]] \
  && [[ "$OUT" == *"hooks/demo.sh -> .codex/hooks/demo.sh"* ]] \
  && [[ "$OUT" != *"-> .pi/kendex/hooks/demo.sh"* ]] \
  && ok "a hook edit reds, naming the two renders it has and not the third" \
  || bad "a hook edit reds, naming the two renders it has and not the third" "rc=$RC out=$OUT"
if mutant_guard '/^  hooks\/\*)$/,/^    ;;$/d'; then
  run_mutant
  [ "$RC" -eq 0 ] \
    && ok "control: with the hooks arm deleted the source-only hook edit passes" \
    || bad "control: with the hooks arm deleted the source-only hook edit passes" "rc=$RC out=$OUT"
else
  bad "control: the hooks render arm could not be deleted from a guard copy"
fi
printf 'echo more\n' >>"$R/.claude/hooks/demo.sh"
printf 'echo more\n' >>"$R/.codex/hooks/demo.sh"
run_guard
[ "$RC" -eq 0 ] \
  && ok "a hook edit landing both tracked renders passes" \
  || bad "a hook edit landing both tracked renders passes" "rc=$RC out=$OUT"
git -C "$R" checkout -q -- hooks .claude/hooks .codex/hooks

# Staging a render's deletion takes it out of the index, and the index alone
# would then read the hook as unrendered and owe nothing. Both renders go, so
# no surviving copy can red this for another reason: the union with HEAD is
# what keeps the rule running, and the outlives clause is what refuses.
printf 'echo more\n' >>"$R/hooks/demo.sh"
git -C "$R" rm -q .claude/hooks/demo.sh .codex/hooks/demo.sh
run_guard
[ "$RC" -ne 0 ] && [[ "$OUT" == *"hooks/demo.sh -> .claude/hooks/demo.sh"* ]] \
  && [[ "$OUT" == *"hooks/demo.sh -> .codex/hooks/demo.sh"* ]] \
  && ok "a hook edit staging its renders' deletion reds, naming both" \
  || bad "a hook edit staging its renders' deletion reds, naming both" "rc=$RC out=$OUT"
git -C "$R" reset -q HEAD -- .claude/hooks .codex/hooks
git -C "$R" checkout -q -- hooks .claude/hooks .codex/hooks

printf 'echo more\n' >>"$R/hooks/tests/demo.test.sh"
run_guard
[ "$RC" -eq 0 ] \
  && ok "a hook test with no render anywhere passes" \
  || bad "a hook test with no render anywhere passes" "rc=$RC out=$OUT"
git -C "$R" checkout -q -- hooks

# A harness directory that tracks nothing is owed nothing.
git -C "$R" rm -q .pi/agents/demo.md
git -C "$R" commit -q -m "chore: no pi renders"
printf '# amended\n' >>"$R/agents/demo.md"
printf '# amended\n' >>"$R/.claude/agents/demo.md"
printf '# amended\n' >>"$R/.codex/agents/demo.toml"
run_guard
[ "$RC" -eq 0 ] \
  && ok "an agent edit with no pi render tracked anywhere passes without one" \
  || bad "an agent edit with no pi render tracked anywhere passes without one" "rc=$RC out=$OUT"
git -C "$R" reset -q --hard HEAD~1

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
