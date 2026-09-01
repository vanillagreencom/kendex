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
# The reply-contract block judges every run, so the fixture carries the three
# files it is about in the state it accepts: AGENTS.md holds the one copy of
# the forms in the contract bullet, one form per continuation line so a dropped
# form is a dropped line, and each bot-facing file points at it by name and
# section. The section also carries the do-not-re-raise bullet the real
# AGENTS.md carries, because that bullet spells `Declined: <reason>` outside
# the contract: dropping that form from the contract leaves the neighbour
# standing, which is the arrangement the bullet scope exists to survive. The
# forms and the pointer sentence are written out here rather than read back
# from guard — a list read from the script under test passes whatever that
# script names, and the sentence is this suite's document, not guard's
# predicate.
REPLY_FORMS=('Fixed in <sha>' 'Declined: <reason>' 'Tracked: KEN-<n>')
REPLY_POINTER='`AGENTS.md` § Code Review Rules is the contract. Read it there.'
DECOY_BULLET='- Do not re-raise a finding class answered `Declined: <reason>` on this PR'
BOT_FACING=(review-bots.md .github/copilot-instructions.md)
mkdir -p "$R/.github"
reply_fixture() { # the accepted state of all three files; with $1, the contract bullet omits that form
  local omit="${1-}" line f
  printf '%s\n' \
    '# fixture' \
    '' \
    '## Code Review Rules' \
    '' \
    "$DECOY_BULLET" \
    '  unless the relevant code changed since.' \
    '- Author replies are one of' >"$R/AGENTS.md"
  for line in '  `Fixed in <sha>`,' '  `Declined: <reason>`, or' '  `Tracked: KEN-<n>` / `#<n>`.'; do
    if [ -n "$omit" ]; then
      case "$line" in *"$omit"*) continue ;; esac
    fi
    printf '%s\n' "$line" >>"$R/AGENTS.md"
  done
  for f in "${BOT_FACING[@]}"; do
    printf '%s\n' "# fixture $f" \
      'Read this alongside AGENTS.md; it is not loaded as working instructions.' \
      '' "$REPLY_POINTER" >"$R/$f"
  done
}
reply_fixture
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

echo "=== AGENTS.md carries the reply forms, and the bot files point at it ==="
# The failing direction first. Each case mutates one file of the accepted
# fixture and asserts the arm that owns that mutation, so the green pass at
# the end of the section is evidence rather than a check that cannot fail.
reply_run() { # — stage the caller's mutation of the fixture and run guard
  git -C "$R" add -A
  run_guard
}

# A form is dropped by rewriting the contract bullet, not by deleting every
# line of the file that carries the literal: the second shape would take the
# do-not-re-raise bullet with it, and so would pass whether or not the arm
# reads past the contract.
for drop in "${REPLY_FORMS[@]}"; do
  reply_fixture "$drop"
  reply_run
  others=0
  for other in "${REPLY_FORMS[@]}"; do
    [ "$other" = "$drop" ] && continue
    [[ "$OUT" == *"reply form '$other'"* ]] && others=$((others + 1))
  done
  [ "$RC" != 0 ] && [[ "$OUT" == *"§ Code Review Rules no longer states the reply form '$drop'"* ]] && [ "$others" = 0 ] \
    && ok "the contract bullet losing $drop reds, naming that form and no other" \
    || bad "the contract bullet losing $drop reds, naming that form and no other" "rc=$RC others=$others out=$OUT"
done

# Anti-vacuous for the case above that carries the decoy: the neighbour bullet
# has to still spell the dropped form, or that case proves nothing about scope.
reply_fixture 'Declined: <reason>'
grep -qF -- "$DECOY_BULLET" "$R/AGENTS.md" \
  && ok "control: the do-not-re-raise bullet still spells Declined: <reason> after that drop" \
  || bad "control: the do-not-re-raise bullet still spells Declined: <reason> after that drop" "$(cat "$R/AGENTS.md")"

# The run ends at the bullet after the contract as well as the one before it.
reply_fixture 'Tracked: KEN-<n>'
printf '%s\n' '- File the remainder as `Tracked: KEN-<n>` once the round closes.' >>"$R/AGENTS.md"
reply_run
[ "$RC" != 0 ] && [[ "$OUT" == *"§ Code Review Rules no longer states the reply form 'Tracked: KEN-<n>'"* ]] \
  && ok "a form dropped from the contract and spelled by the bullet under it reds" \
  || bad "a form dropped from the contract and spelled by the bullet under it reds" "rc=$RC out=$OUT"

reply_fixture
rm -f "$R/AGENTS.md"
reply_run
[ "$RC" != 0 ] && [[ "$OUT" == *"AGENTS.md is gone"* ]] && [[ "$OUT" != *"No such file or directory"* ]] \
  && ok "an absent AGENTS.md reds on the absence, with no grep read error in the output" \
  || bad "an absent AGENTS.md reds on the absence, with no grep read error in the output" "rc=$RC out=$OUT"

for f in "${BOT_FACING[@]}"; do
  reply_fixture
  grep -vF -- "$REPLY_POINTER" "$R/$f" >"$TMP/bot"
  mv "$TMP/bot" "$R/$f"
  reply_run
  [ "$RC" != 0 ] && [[ "$OUT" == *"$f no longer points at AGENTS.md § Code Review Rules"* ]] \
    && ok "$f without the pointer sentence reds" \
    || bad "$f without the pointer sentence reds" "rc=$RC out=$OUT"

  reply_fixture
  rm -f "$R/$f"
  reply_run
  [ "$RC" != 0 ] && [[ "$OUT" == *"$f is gone"* ]] && [[ "$OUT" != *"No such file or directory"* ]] \
    && ok "an absent $f reds on the absence, with no grep read error in the output" \
    || bad "an absent $f reds on the absence, with no grep read error in the output" "rc=$RC out=$OUT"

  # A pointer is only a pointer if it names the file it sends readers to: the
  # same sentence aimed somewhere else reads as a pointer and is not one.
  reply_fixture
  sed 's/`AGENTS\.md` § Code Review Rules/`FOO.md` § Code Review Rules/' "$R/$f" >"$TMP/bot"
  mv "$TMP/bot" "$R/$f"
  reply_run
  [ "$RC" != 0 ] && [[ "$OUT" == *"$f no longer points at AGENTS.md § Code Review Rules"* ]] \
    && ok "$f pointing the same sentence at another file reds" \
    || bad "$f pointing the same sentence at another file reds" "rc=$RC out=$OUT"
done

# Deleting a form outright is the one mutation a whole-file substring search
# catches. These six are what stand between the arm and a green AGENTS.md with
# no contract under the heading the bot files name: the section keeps its
# heading or loses it, and the three forms survive somewhere the arm must not
# accept. Each defeats one predicate this arm has worn in turn — a whole-file
# search, a heading-to-heading slice, that slice's `## ` exit rule, that
# slice's start rule re-arming on a repeated heading, and the bullet scope
# that replaced the slice, which took any bullet in the file. The section and
# the bullet are both load-bearing, so each probe names which of the two is
# missing.
gutted_probe() { # LABEL EXPECTED — the AGENTS.md that replaces the fixture's arrives on stdin
  local label="$1" expected="$2"
  reply_fixture
  cat >"$R/AGENTS.md"
  reply_run
  [ "$RC" != 0 ] && [[ "$OUT" == *"$expected"* ]] \
    && ok "$label" \
    || bad "$label" "rc=$RC out=$OUT"
}
NO_SECTION="AGENTS.md has no § Code Review Rules section"
NO_BULLET="AGENTS.md § Code Review Rules has no '- Author replies are' bullet"

gutted_probe "the section gone and the forms recited in a glossary reds" "$NO_SECTION" <<'MD'
# fixture

## Glossary

Historical note: older repos spelled replies `Fixed in <sha>`,
`Declined: <reason>`, or `Tracked: KEN-<n>`; that convention is retired here.
MD

gutted_probe "the section kept and the forms moved into a later ## section reds" "$NO_BULLET" <<'MD'
# fixture

## Code Review Rules

Raise only defects in the changed lines.

## Glossary

Replies were once written `Fixed in <sha>`,
`Declined: <reason>`, or `Tracked: KEN-<n>`.
MD

gutted_probe "the forms recited under a following # heading reds" "$NO_BULLET" <<'MD'
# fixture

## Code Review Rules

- Do not re-raise a finding class answered `Declined: <reason>` on this PR
  unless the relevant code changed since.

# Appendix

Retired spellings: `Fixed in <sha>`, `Declined: <reason>`,
`Tracked: KEN-<n>`.
MD

gutted_probe "a repeated ## Code Review Rules heading reciting the forms reds" "$NO_BULLET" <<'MD'
# fixture

## Code Review Rules

Raise only defects in the changed lines.

## Code Review Rules

Replies were once written `Fixed in <sha>`, `Declined: <reason>`, or
`Tracked: KEN-<n>`; that convention is retired here.
MD

# The two the bullet scope alone let through: the contract bullet is whole and
# unedited, and it is somewhere the bot-facing files do not send readers.
gutted_probe "the whole contract bullet moved into a later section reds" "$NO_BULLET" <<'MD'
# fixture

## Code Review Rules

- Do not re-raise a finding class answered `Declined: <reason>` on this PR
  unless the relevant code changed since.

## Reply contract

- Author replies are one of
  `Fixed in <sha>`,
  `Declined: <reason>`, or
  `Tracked: KEN-<n>` / `#<n>`.
MD

gutted_probe "the whole contract bullet moved into an earlier section reds" "$NO_BULLET" <<'MD'
# fixture

## Reply contract

- Author replies are one of
  `Fixed in <sha>`,
  `Declined: <reason>`, or
  `Tracked: KEN-<n>` / `#<n>`.

## Code Review Rules

- Do not re-raise a finding class answered `Declined: <reason>` on this PR
  unless the relevant code changed since.
MD

# The pointer's two-file list is a decision, not an oversight: a path-scoped
# instruction file carries no reply-contract section and is not asked to point
# at one. This is what would red if someone widened the loop without saying so.
reply_fixture
mkdir -p "$R/.github/instructions"
printf '%s\n' '---' 'applyTo: "crates/**"' '---' '' 'Flag no line-oriented pass over TOML text.' \
  >"$R/.github/instructions/crates.instructions.md"
reply_run
[ "$RC" = 0 ] \
  && ok "a path-scoped .github/instructions file without the pointer passes, deliberately" \
  || bad "a path-scoped .github/instructions file without the pointer passes, deliberately" "rc=$RC out=$OUT"
rm -rf "$R/.github/instructions"

reply_fixture
reply_run
[ "$RC" = 0 ] \
  && ok "AGENTS.md holding the forms and both bot files pointing at it passes" \
  || bad "AGENTS.md holding the forms and both bot files pointing at it passes" "rc=$RC out=$OUT"

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
if mutant_guard '/agents\/\$n/d'; then
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
