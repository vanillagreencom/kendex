#!/usr/bin/env bash
# Pins for scripts/commit-msg, which carries every commit-message rule: the
# conventional header shape in both directions, the subject cap, and the
# changelog a commit owes for touching the configured paths. Plus the two
# MUSTs from the family contract — uppercase issue keys in scopes pass,
# git-generated messages pass shape and length — header extraction, type-list
# configuration, and the exit-2 usage/collection lanes. A git-generated header
# is exempt from shape and length ALONE: the changelog rule still runs over it.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
CM="$SKILL_DIR/scripts/commit-msg"
. "$TEST_DIR/lib/harness.bash"

unset GROWTH_GUARDS_COMMIT_TYPES GROWTH_GUARDS_SUBJECT_MAX \
  GROWTH_GUARDS_CHANGELOG_REQUIRED_PATHS GROWTH_GUARDS_CHANGELOG_PATHS \
  GROWTH_GUARDS_CHANGELOG_RECORD GROWTH_GUARDS_SETTINGS_FILE 2>/dev/null || true

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }

R="$TMP/repo"
mkdir -p "$R"
git -C "$R" -c init.defaultBranch=main init -q
git -C "$R" config user.email test@example.com
git -C "$R" config user.name test

run_stdin() { # MESSAGE [env-assignment] — feed via stdin; sets OUT and RC
  OUT=""
  RC=0
  OUT="$(cd "$R" && printf '%s\n' "$1" | env ${2:+"$2"} "$CM" 2>&1)" || RC=$?
}

expect_pass() { # HEADER DESC [env]
  run_stdin "$1" "${3:-}"
  [ "$RC" -eq 0 ] && ok "$2" || bad "$2" "rc=$RC out=$OUT"
}

expect_fail() { # HEADER DESC [env]
  run_stdin "$1" "${3:-}"
  [ "$RC" -eq 1 ] && ok "$2" || bad "$2" "rc=$RC out=$OUT"
}

echo "=== conventional headers pass ==="
expect_pass 'feat: add the gate' "bare type"
expect_pass 'fix(cli): repair the trailing newline' "lowercase scope"
expect_pass 'fix(ABC-123): tighten the gate' "MUST: uppercase issue key in the scope"
expect_pass 'fix(#123): case-fold open-terminal issue IDs' "issue-number scope"
expect_pass 'feat(api)!: drop the legacy endpoint' "breaking-change marker"
expect_pass 'chore(deps, ci): bump the runner image' "multi-part scope with comma and space"
expect_pass 'refactor(tui/render): split the paint pass' "slashed scope"

echo "=== git-generated headers pass unchanged (MUST) ==="
expect_pass 'Merge branch feature into main' "Merge"
expect_pass 'Revert "feat: add the gate"' "Revert"
expect_pass 'Reapply "feat: add the gate"' "Reapply"
expect_pass 'fixup! fix(cli): repair the newline' "fixup!"
expect_pass 'squash! fix(cli): repair the newline' "squash!"
expect_pass 'amend! fix(cli): repair the newline' "amend!"

echo "=== non-conventional headers fail ==="
expect_fail 'Add stuff' "bare imperative subject"
expect_fail 'Feat: uppercase type' "uppercase type"
expect_fail 'feat add the gate' "missing colon"
expect_fail 'feat:no space after colon' "missing space after the colon"
expect_fail 'feat: ' "empty subject"
expect_fail 'wip: not a known type' "unknown type"
expect_fail 'feat(): empty scope' "empty scope parens"
run_stdin 'Add stuff'
case "$OUT" in *"expected: type(scope)!: subject"*"types: build chore ci docs feat fix perf refactor revert style test"*) ok "diagnostic names the shape and the type list" ;; *) bad "diagnostic names the shape and types" "$OUT" ;; esac
case "$OUT" in *"fix(ABC-123)"*) ok "diagnostic shows the uppercase-key example" ;; *) bad "diagnostic shows the uppercase-key example" "$OUT" ;; esac

echo "=== header extraction ==="
expect_pass "$(printf 'feat: subject line\n\nbody paragraph\nmore body')" "multi-line message: only the header is judged"
expect_pass "$(printf '# comment from the template\n\nfeat: subject after comments')" "comment and blank lines before the header are skipped"
expect_fail '' "empty message fails"
run_stdin "$(printf 'feat: crlf subject\r')"
[ "$RC" -eq 0 ] && ok "a CRLF header is stripped before matching" || bad "CRLF header passes" "rc=$RC out=$OUT"

echo "=== file mode (the git hook contract) ==="
printf 'fix(VST-214): ship the check family\n' >"$TMP/msg"
OUT="$(cd "$R" && "$CM" "$TMP/msg" 2>&1)" && RC=0 || RC=$?
[ "$RC" -eq 0 ] && ok "a message FILE argument is read like the hook passes it" || bad "file mode passes" "rc=$RC out=$OUT"
OUT="$(cd "$R" && "$CM" "$TMP/no-such-msg" 2>&1)" && RC=0 || RC=$?
[ "$RC" -eq 2 ] && ok "a missing message file is exit 2" || bad "missing message file is exit 2" "rc=$RC out=$OUT"
OUT="$(cd "$R" && "$CM" "$TMP/msg" extra 2>&1)" && RC=0 || RC=$?
[ "$RC" -eq 2 ] && ok "two positional arguments are exit 2" || bad "two positionals are exit 2" "rc=$RC out=$OUT"

echo "=== the type list is configuration, and it is validated ==="
expect_pass 'release: cut 2.6.6' "custom type list admits its types" "GROWTH_GUARDS_COMMIT_TYPES=feat release"
expect_fail 'fix: no longer a type' "custom type list rejects everything else (control)" "GROWTH_GUARDS_COMMIT_TYPES=feat release"
run_stdin 'feat: x' "GROWTH_GUARDS_COMMIT_TYPES=Feat"
[ "$RC" -eq 2 ] && ok "a non-lowercase type entry is exit 2" || bad "bad type entry is exit 2" "rc=$RC out=$OUT"
run_stdin 'feat: x' "GROWTH_GUARDS_COMMIT_TYPES= "
[ "$RC" -eq 2 ] && ok "an empty type list is exit 2" || bad "empty type list is exit 2" "rc=$RC out=$OUT"

echo "=== settings file resolution ==="
printf '[env]\nGROWTH_GUARDS_COMMIT_TYPES = "docs"\n' >"$R/kendex.settings.toml"
run_stdin 'docs: settings-admitted type'
[ "$RC" -eq 0 ] && ok "kendex.settings.toml supplies the type list" || bad "settings file supplies the types" "rc=$RC out=$OUT"
run_stdin 'feat: settings-rejected type'
[ "$RC" -eq 1 ] && ok "control: the settings-restricted list really rejects other types" \
  || bad "control: settings-restricted list rejects" "rc=$RC out=$OUT"
rm "$R/kendex.settings.toml"

echo "=== a .env value is read by nothing ==="
# The .env layer is dropped: a type list there must not restrict anything,
# with or without the sentinel. Fails against a resolver that still reads
# the file (the docs-only list would reject feat).
printf 'GROWTH_GUARDS_COMMIT_TYPES=docs\n' >"$R/.env"
run_stdin 'feat: base type'
[ "$RC" -eq 0 ] && ok "a .env type list is ignored and the built-in list decides" \
  || bad "a .env type list is ignored" "rc=$RC out=$OUT"
rm -f "$R/.env"

echo "=== the /dev/null sentinel selects NO settings source, the dotenv layer included ==="
# It named only the settings file, so .env.local (read before it) kept
# deciding: a caller asking for built-in defaults got whatever the
# repository's env file said.
printf 'GROWTH_GUARDS_COMMIT_TYPES=chore\n' >"$R/.env.local"
run_stdin 'feat: base type'
[ "$RC" -eq 1 ] && ok "control: without the sentinel .env.local restricts the list to chore" \
  || bad "sentinel control (.env.local)" "rc=$RC out=$OUT"
run_stdin 'feat: base type' "GROWTH_GUARDS_SETTINGS_FILE=/dev/null"
[ "$RC" -eq 0 ] && ok "the sentinel skips .env.local (read BEFORE the settings file) too" \
  || bad "sentinel skips .env.local" "rc=$RC out=$OUT"
rm -f "$R/.env.local"

echo "=== a failing index probe never loosens the committed type list ==="
# The hook lane resolves tracked settings from the INDEX so a commit is judged
# by its own configuration. `--error-unmatch` reserves exit 1 for "no such
# path"; reading EVERY nonzero status as "untracked" let a broken git drop the
# committed list back to the built-in one and admit a type it rejects.
RI="$TMP/repo-index"
mkdir -p "$RI"
git -C "$RI" -c init.defaultBranch=main init -q
git -C "$RI" config user.email test@example.com
git -C "$RI" config user.name test
printf '[env]\nGROWTH_GUARDS_COMMIT_TYPES = "docs"\n' >"$RI/kendex.settings.toml"
git -C "$RI" add -A
git -C "$RI" commit -qm "docs: base" --no-verify
OUT=""; RC=0
OUT="$(cd "$RI" && printf 'feat: not in the committed list\n' | "$CM" 2>&1)" || RC=$?
[ "$RC" -eq 1 ] && ok "control: the committed list rejects the header" \
  || bad "committed list rejects (probe control)" "rc=$RC out=$OUT"

REAL_GIT="$(command -v git)"
GIT_TRACKED_SHIM="$TMP/git-tracked-shim"
mkdir -p "$GIT_TRACKED_SHIM"
cat >"$GIT_TRACKED_SHIM/git" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "ls-files" ] && [ "\${2:-}" = "--error-unmatch" ]; then
  echo "fatal: simulated index-probe failure" >&2
  exit 71
fi
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$GIT_TRACKED_SHIM/git"
OUT=""; RC=0
OUT="$(cd "$RI" && printf 'feat: not in the committed list\n' | PATH="$GIT_TRACKED_SHIM:$PATH" "$CM" 2>&1)" || RC=$?
[ "$RC" -eq 2 ] && case "$OUT" in *"could not query the index while resolving a setting"*) true ;; *) false ;; esac \
  && ok "a failing tracked-source probe is exit 2, never a silent fall back to the built-in list" \
  || bad "settings probe failure" "rc=$RC out=$OUT"

# A settings source that cannot be an index entry — absolute, or escaping the
# root — draws git's "outside repository" refusal, which carries the same 128
# an operational failure does. It is answered before the probe, so such a
# source still reads from the worktree instead of failing the run.
printf '[env]\nGROWTH_GUARDS_COMMIT_TYPES = "docs"\n' >"$TMP/outside-settings.toml"
for path in "$TMP/outside-settings.toml" "../outside-settings.toml"; do
  OUT=""; RC=0
  OUT="$(cd "$RI" && printf 'feat: not in the outside list\n' | GROWTH_GUARDS_SETTINGS_FILE="$path" "$CM" 2>&1)" || RC=$?
  [ "$RC" -eq 1 ] && ok "an out-of-repo settings source still reads in the hook lane ($path)" \
    || bad "out-of-repo settings source" "path=$path rc=$RC out=$OUT"
done

echo "=== a '..' that normalizes back inside is an ordinary index entry ==="
# The answer-before-probe shortcut for out-of-repo paths must not swallow
# sub/../kendex.settings.toml, which IS the committed settings file: reading
# the worktree copy there handed an unstaged edit exactly the authority the
# hook lane removes.
mkdir -p "$RI/sub"
echo keep >"$RI/sub/keep.txt"
git -C "$RI" add -A
git -C "$RI" commit -qm "docs: subdir" --no-verify
# Loosened on disk only: the commit still carries the docs-only list.
printf '[env]\nGROWTH_GUARDS_COMMIT_TYPES = "docs feat"\n' >"$RI/kendex.settings.toml"
for path in "kendex.settings.toml" "sub/../kendex.settings.toml" "./kendex.settings.toml" "a/b/../../kendex.settings.toml"; do
  OUT=""; RC=0
  OUT="$(cd "$RI" && printf 'feat: not in the committed list\n' | GROWTH_GUARDS_SETTINGS_FILE="$path" "$CM" 2>&1)" || RC=$?
  [ "$RC" -eq 1 ] && ok "the committed type list governs a path spelled '$path'" \
    || bad "dot-dot settings path resolves to the index" "path=$path rc=$RC out=$OUT"
done
# Control: still escaping once normalized, so it reads the out-of-repo file
# (docs-only, written above) instead of anything in the index.
OUT=""; RC=0
OUT="$(cd "$RI" && printf 'feat: not in the outside list\n' | GROWTH_GUARDS_SETTINGS_FILE="sub/../../outside-settings.toml" "$CM" 2>&1)" || RC=$?
[ "$RC" -eq 1 ] && ok "control: a path that still escapes once normalized reads the out-of-repo file" \
  || bad "normalized escape stays out-of-repo" "rc=$RC out=$OUT"
git -C "$RI" checkout -q -- kendex.settings.toml

echo "=== a failing HEAD probe never hands authority to a recreated list ==="
# Staged deletion + worktree recreation: the commit carries "docs", the
# deletion is staged, the recreated worktree copy allows "feat". The HEAD
# probe proves the commit once carried the source; a broken git there must
# fail closed, never read as "never tracked".
RH="$TMP/repo-headprobe"
mkdir -p "$RH"
git -C "$RH" -c init.defaultBranch=main init -q
git -C "$RH" config user.email test@example.com
git -C "$RH" config user.name test
printf '[env]\nGROWTH_GUARDS_COMMIT_TYPES = "docs"\n' >"$RH/kendex.settings.toml"
git -C "$RH" add -A
git -C "$RH" commit -qm "docs: base" --no-verify
git -C "$RH" rm -q --cached kendex.settings.toml
printf '[env]\nGROWTH_GUARDS_COMMIT_TYPES = "feat"\n' >"$RH/kendex.settings.toml"
REAL_GIT="$(command -v git)"
GIT_HTREE_SHIM="$TMP/git-htree-shim"
mkdir -p "$GIT_HTREE_SHIM"
{
  printf '#!/usr/bin/env bash\n'
  printf 'if [ "${1:-}" = "ls-tree" ]; then\n'
  printf '  echo "fatal: simulated HEAD-tree failure" >&2\n'
  printf '  exit 71\n'
  printf 'fi\n'
  printf 'exec %s "$@"\n' "$REAL_GIT"
} >"$GIT_HTREE_SHIM/git"
chmod +x "$GIT_HTREE_SHIM/git"
OUT=""; RC=0
OUT="$(cd "$RH" && printf 'feat: recreated list must not authorize\n' | PATH="$GIT_HTREE_SHIM:$PATH" "$CM" 2>&1)" || RC=$?
[ "$RC" -eq 2 ] && case "$OUT" in *"(git ls-tree exit 71)"*) true ;; *) false ;; esac \
  && ok "a failing HEAD probe is exit 2, never authority for the recreated list" \
  || bad "gg HEAD-probe failure" "rc=$RC out=$OUT"

echo "=== the subject cap: 72 by default, and it is configurable ==="
# N copies of a character, so a fixture states the length it means instead of
# carrying a literal nobody can count.
rep() { # CHAR N
  local c="$1" n="$2" i=0 out=""
  while [ "$i" -lt "$n" ]; do
    out="$out$c"
    i=$((i + 1))
  done
  printf '%s' "$out"
}
# "fix(KEN-1): " is twelve characters, so the subject is 12 + N.
expect_pass "fix(KEN-1): $(rep x 60)" "a 72-character header passes"
run_stdin "fix(KEN-1): $(rep x 61)"
[ "$RC" -eq 1 ] && case "$OUT" in *"subject is 73 characters (max 72)"*) true ;; *) false ;; esac \
  && ok "73 characters fails, naming the count and the cap" \
  || bad "73 characters fails, naming the count and the cap" "rc=$RC out=$OUT"
case "$OUT" in *"move the detail into the body"*) ok "the length diagnostic carries the remedy" ;; *) bad "the length diagnostic carries the remedy" "$OUT" ;; esac
expect_pass "Merge $(rep x 90)" "a long Merge header is exempt from the cap"
expect_pass "fixup! fix(KEN-1): $(rep x 90)" "a long fixup! header is exempt too"
expect_pass "fix(KEN-1): $(rep x 61)" "a raised cap admits the same header" "GROWTH_GUARDS_SUBJECT_MAX=100"
expect_fail "fix(KEN-1): $(rep x 20)" "a lowered cap refuses a header the default admits" "GROWTH_GUARDS_SUBJECT_MAX=20"
run_stdin 'fix: x' "GROWTH_GUARDS_SUBJECT_MAX=0"
[ "$RC" -eq 2 ] && case "$OUT" in *"must be a positive integer"*) true ;; *) false ;; esac \
  && ok "a cap that is not a positive integer is exit 2" \
  || bad "a cap that is not a positive integer is exit 2" "rc=$RC out=$OUT"

echo "=== shape and length are reported together, not one at a time ==="
run_stdin "$(rep q 90)" "GROWTH_GUARDS_SUBJECT_MAX=20"
[ "$RC" -eq 1 ] \
  && case "$OUT" in *"non-conventional header"*) true ;; *) false ;; esac \
  && case "$OUT" in *"subject is 90 characters (max 20)"*) true ;; *) false ;; esac \
  && ok "one run names both the shape and the length" \
  || bad "one run names both the shape and the length" "rc=$RC out=$OUT"

echo "=== a commit touching the required paths owes a changelog entry ==="
RC_REPO="$TMP/repo-changelog"
mkdir -p "$RC_REPO/crates/core" "$RC_REPO/docs"
git -C "$RC_REPO" -c init.defaultBranch=main init -q
git -C "$RC_REPO" config user.email test@example.com
git -C "$RC_REPO" config user.name test
printf '[env]\nGROWTH_GUARDS_CHANGELOG_REQUIRED_PATHS = "crates/* ui/*"\n' >"$RC_REPO/kendex.settings.toml"
printf '# Changelog\n\n## [Unreleased]\n' >"$RC_REPO/CHANGELOG.md"
printf 'fn main() {}\n' >"$RC_REPO/crates/core/lib.rs"
git -C "$RC_REPO" add -A
git -C "$RC_REPO" commit -qm "chore: base"

run_rc() { # MESSAGE — run in the changelog fixture; sets OUT and RC
  OUT=""
  RC=0
  OUT="$(cd "$RC_REPO" && printf '%s\n' "$1" | "$CM" 2>&1)" || RC=$?
}

# Nothing staged under the required paths: the rule is silent.
printf 'notes\n' >"$RC_REPO/docs/notes.md"
git -C "$RC_REPO" add -A
run_rc 'docs: a note'
[ "$RC" -eq 0 ] && case "$OUT" in *"changelog entry"*) false ;; *) true ;; esac \
  && ok "a commit touching none of the required paths owes nothing" \
  || bad "a commit touching none of the required paths owes nothing" "rc=$RC out=$OUT"

printf 'fn added() {}\n' >>"$RC_REPO/crates/core/lib.rs"
git -C "$RC_REPO" add -A
run_rc 'fix(KEN-1): change a crate'
[ "$RC" -eq 1 ] && case "$OUT" in *"crates/core/lib.rs changed without a changelog entry"*) true ;; *) false ;; esac \
  && ok "a staged crates/ change with no entry fails, naming the path" \
  || bad "a staged crates/ change with no entry fails, naming the path" "rc=$RC out=$OUT"
case "$OUT" in *"changelog.d"*"CHANGELOG.md"*) ok "the diagnostic names where an entry may be written" ;; *) bad "the diagnostic names where an entry may be written" "$OUT" ;; esac
run_rc 'fix(KEN-1): change a crate [no-changelog]'
[ "$RC" -eq 0 ] && ok "[no-changelog] in the header waives it" \
  || bad "[no-changelog] in the header waives it" "rc=$RC out=$OUT"
# MUST: a git-generated header skips shape and length, never this rule.
run_rc "Merge branch 'topic' into main"
[ "$RC" -eq 1 ] && case "$OUT" in *"changed without a changelog entry"*) true ;; *) false ;; esac \
  && ok "MUST: the changelog rule runs over a git-generated header too" \
  || bad "MUST: the changelog rule runs over a git-generated header too" "rc=$RC out=$OUT"
run_rc "Merge branch 'topic' into main [no-changelog]"
[ "$RC" -eq 0 ] && ok "control: [no-changelog] escapes it on a generated header as well" \
  || bad "control: [no-changelog] escapes it on a generated header as well" "rc=$RC out=$OUT"

mkdir -p "$RC_REPO/changelog.d/fixed"
printf -- '- A fix consumers see.\n' >"$RC_REPO/changelog.d/fixed/ken-1.md"
git -C "$RC_REPO" add -A
run_rc 'fix(KEN-1): change a crate'
[ "$RC" -eq 0 ] && ok "a staged fragment satisfies it" \
  || bad "a staged fragment satisfies it" "rc=$RC out=$OUT"
# Deleting a fragment is not writing one.
git -C "$RC_REPO" commit -qm "fix(KEN-1): change a crate"
printf 'fn more() {}\n' >>"$RC_REPO/crates/core/lib.rs"
rm -f "$RC_REPO/changelog.d/fixed/ken-1.md"
git -C "$RC_REPO" add -A
run_rc 'fix(KEN-2): change a crate again'
[ "$RC" -eq 1 ] && case "$OUT" in *"changed without a changelog entry"*) true ;; *) false ;; esac \
  && ok "deleting a fragment is not writing one" \
  || bad "deleting a fragment is not writing one" "rc=$RC out=$OUT"
# The record counts too, which is what the release commit needs.
printf '# Changelog\n\n## [Unreleased]\n\n- A fix consumers see.\n' >"$RC_REPO/CHANGELOG.md"
git -C "$RC_REPO" add -A
run_rc 'chore(release): collate the changelog'
[ "$RC" -eq 0 ] && ok "the collated record counts as the entry" \
  || bad "the collated record counts as the entry" "rc=$RC out=$OUT"

# A path git would quote in its text output — the name carries a byte outside
# ASCII — still reaches the globs as the bytes git recorded. A quoted name
# matches no glob, and the rule would stop seeing the file it is about.
git -C "$RC_REPO" reset -q --hard HEAD
QUOTED="$(printf 'crates/core/na\303\257ve.rs')"
printf 'fn quoted() {}\n' >"$RC_REPO/$QUOTED"
git -C "$RC_REPO" add -A
[ -n "$(cd "$RC_REPO" && git diff --cached --name-only | grep '"')" ] \
  && ok "fixture: git's text output really does quote this name" \
  || bad "fixture: git's text output really does quote this name" "$(cd "$RC_REPO" && git diff --cached --name-only)"
run_rc 'fix(KEN-4): change a crate under a quoted name'
[ "$RC" -eq 1 ] && case "$OUT" in *"changed without a changelog entry"*) true ;; *) false ;; esac \
  && ok "a required path git would quote is still matched" \
  || bad "a required path git would quote is still matched" "rc=$RC out=$OUT"
git -C "$RC_REPO" reset -q --hard HEAD
rm -f "$RC_REPO/$QUOTED"

echo "=== the required paths are configuration, validated like every other path ==="
git -C "$RC_REPO" reset -q --hard HEAD
printf 'fn yet() {}\n' >>"$RC_REPO/crates/core/lib.rs"
git -C "$RC_REPO" add -A
run_rc 'fix(KEN-3): change a crate'
[ "$RC" -eq 1 ] && ok "control: the committed settings still oblige an entry" \
  || bad "control: the committed settings still oblige an entry" "rc=$RC out=$OUT"
OUT=""; RC=0
OUT="$(cd "$RC_REPO" && printf 'fix(KEN-3): change a crate\n' | GROWTH_GUARDS_CHANGELOG_REQUIRED_PATHS= "$CM" 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && ok "an explicitly empty list switches the rule off" \
  || bad "an explicitly empty list switches the rule off" "rc=$RC out=$OUT"
OUT=""; RC=0
OUT="$(cd "$RC_REPO" && printf 'fix(KEN-3): change a crate\n' | GROWTH_GUARDS_CHANGELOG_REQUIRED_PATHS=/etc/crates "$CM" 2>&1)" || RC=$?
[ "$RC" -eq 2 ] && case "$OUT" in *"must be repo-root-relative"*) true ;; *) false ;; esac \
  && ok "an absolute required path is a config error" \
  || bad "an absolute required path is a config error" "rc=$RC out=$OUT"
OUT=""; RC=0
OUT="$(cd "$RC_REPO" && printf 'fix(KEN-3): change a crate\n' | GROWTH_GUARDS_CHANGELOG_PATHS="" GROWTH_GUARDS_CHANGELOG_RECORD="" "$CM" 2>&1)" || RC=$?
[ "$RC" -eq 2 ] && case "$OUT" in *"name nowhere one could be written"*) true ;; *) false ;; esac \
  && ok "obliging an entry with nowhere to write one is a config error" \
  || bad "obliging an entry with nowhere to write one is a config error" "rc=$RC out=$OUT"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
