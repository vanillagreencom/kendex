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

# Most runs below settle a rule the script carries itself and configure it
# through the environment, so they resolve no setting from a file — and the
# sentinel spends none of the walk that would find nothing. The blocks that
# do put a file in front of the script clear NO_SETTINGS around themselves;
# a caller's own assignment comes last, so it still wins.
NO_SETTINGS=1

run_stdin() { # MESSAGE [env-assignment] — feed via stdin; sets OUT and RC
  OUT=""
  RC=0
  OUT="$(cd "$R" && printf '%s\n' "$1" |
    env ${NO_SETTINGS:+GROWTH_GUARDS_SETTINGS_FILE=/dev/null} ${2:+"$2"} "$CM" 2>&1)" || RC=$?
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

NO_SETTINGS=""
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
NO_SETTINGS=1

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
[ "$RC" -eq 1 ] && case "$OUT" in *"header is 73 characters (max 72)"*) true ;; *) false ;; esac \
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

# Characters, not bytes, whatever locale the committer's shell carries. A
# git hook inherits that environment, so a message measured in bytes is
# accepted in one shell and refused in another.
MULTI="fix(KEN-1): $(rep 'é' 55)" # 67 characters, 122 bytes
for loc in C C.UTF-8; do
  run_stdin "$MULTI" "LC_ALL=$loc"
  [ "$RC" -eq 0 ] && ok "a 67-character multibyte header passes under $loc" \
    || bad "a 67-character multibyte header passes under $loc" "rc=$RC out=$OUT"
done
# The control: one character more is over the cap in every one of them, so
# the passes above are the count and not the rule declining to look.
MULTI_OVER="fix(KEN-1): $(rep 'é' 61)" # 73 characters
for loc in C C.UTF-8; do
  run_stdin "$MULTI_OVER" "LC_ALL=$loc"
  [ "$RC" -eq 1 ] && case "$OUT" in *"header is 73 characters (max 72)"*) true ;; *) false ;; esac \
    && ok "and 73 of them is 73 characters under $loc, not its byte count" \
    || bad "and 73 of them is 73 characters under $loc" "rc=$RC out=$OUT"
done
# The SHAPE rule answers under the same rules. Its scope class is ASCII in
# every surface that documents it, and a bracket range is a COLLATION range
# under a UTF-8 locale, which is the one thing that could admit an accented
# scope. C and C.UTF-8 are what the hosts this suite runs on carry, so what
# these arms prove is that the verdict does not vary across them — not that
# collation cannot bite on some other glibc or grep. These bytes sit in the
# scope, which is the only part of the ERE a locale changes; the length
# fixtures above carry theirs in the subject and reach none of it.
for loc in C C.UTF-8; do
  run_stdin 'fix(café): tighten the gate' "LC_ALL=$loc"
  [ "$RC" -eq 1 ] && case "$OUT" in *"non-conventional header"*) true ;; *) false ;; esac \
    && ok "an accented scope is outside the documented class under $loc" \
    || bad "an accented scope is outside the documented class under $loc" "rc=$RC out=$OUT"
  run_stdin 'fix(cafe): tighten the gate' "LC_ALL=$loc"
  [ "$RC" -eq 0 ] && ok "control: the same scope in ASCII passes under $loc" \
    || bad "control: the same scope in ASCII passes under $loc" "rc=$RC out=$OUT"
done
# And bytes that are not valid UTF-8 at all decide the same way everywhere:
# the subject class is "not whitespace", which they are.
BADBYTES="$(printf 'fix: \377\376 bad bytes')"
for loc in C C.UTF-8; do
  run_stdin "$BADBYTES" "LC_ALL=$loc"
  [ "$RC" -eq 0 ] && ok "a subject carrying invalid UTF-8 is judged the same under $loc" \
    || bad "a subject carrying invalid UTF-8 is judged the same under $loc" "rc=$RC out=$OUT"
done
# Such bytes have no character count, and a cap has to round that the way that
# cannot let an over-long header through. Each of these continuation bytes
# belongs to no sequence, so each costs one: 205 bytes is 205 characters, not
# the 5 a bytes-minus-continuations count would report.
STRAY="fix: $(rep "$(printf '\277')" 200)"
run_stdin "$STRAY"
[ "$RC" -eq 1 ] && case "$OUT" in *"header is 205 characters (max 72)"*) true ;; *) false ;; esac \
  && ok "a header of stray continuation bytes counts each of them, never nothing" \
  || bad "a header of stray continuation bytes counts each of them" "rc=$RC out=$OUT"
# The same holds for every shape that LOOKS like a sequence and is not one:
# an overlong form, a surrogate encoding, a lead byte past the last code
# point. Each is counted byte by byte, so 30 of them is 90 characters and not
# 30 — a range written loosely here is a cap a malformed header walks past.
malformed_counted=1
for bad_seq in '\340\200\200:overlong' '\355\240\200:surrogate' '\364\220\200\200:out-of-range'; do
  bytes="${bad_seq%%:*}"
  what="${bad_seq#*:}"
  run_stdin "fix: $(rep "$(printf "$bytes")" 30)"
  # 5 for "fix: ", then one per byte of each malformed sequence.
  want=$((5 + 30 * (${#bytes} / 4)))
  [ "$RC" -eq 1 ] && case "$OUT" in *"header is $want characters (max 72)"*) true ;; *) false ;; esac \
    || { malformed_counted=0; bad "a $what sequence is counted byte by byte" "want=$want rc=$RC out=$OUT"; }
done
[ "$malformed_counted" -eq 1 ] && ok "an overlong, surrogate or out-of-range sequence costs one per byte"
# The control: the same count of WELL-FORMED three-byte sequences is 30
# characters and passes, so the refusals above are the malformed ranges and
# not the length rule refusing every multibyte header.
run_stdin "fix: $(rep "$(printf '\342\200\224')" 30)"
[ "$RC" -eq 0 ] && ok "control: 30 well-formed three-byte sequences are 30 characters and pass" \
  || bad "control: 30 well-formed three-byte sequences pass" "rc=$RC out=$OUT"

echo "=== shape and length are reported together, not one at a time ==="
run_stdin "$(rep q 90)" "GROWTH_GUARDS_SUBJECT_MAX=20"
[ "$RC" -eq 1 ] \
  && case "$OUT" in *"non-conventional header"*) true ;; *) false ;; esac \
  && case "$OUT" in *"header is 90 characters (max 20)"*) true ;; *) false ;; esac \
  && ok "one run names both the shape and the length" \
  || bad "one run names both the shape and the length" "rc=$RC out=$OUT"

echo "=== the header reaches every message rendered, never raw ==="
# A commit object carries whatever bytes were written into it, and a generated
# revert or fixup header carries a subject copied out of history nobody here
# reviewed. Either can spell terminal control codes, so no message may hand
# them on: an ESC in a header would otherwise repaint the reader's terminal or
# forge a second diagnostic line under this hook's own name.
ESC="$(printf '\033')"
case "fix: a subject with ${ESC}[31m in it" in
  *"$ESC"*) ok "must-fail: the fixture header really carries an ESC byte" ;;
  *) bad "the fixture header carries no ESC" "nothing to render" ;;
esac
# The conventional path: the header is echoed back on the OK line.
run_stdin "fix: a subject with ${ESC}[31m in it"
[ "$RC" -eq 0 ] && case "$OUT" in *"$ESC"*) false ;; *) true ;; esac \
  && ok "no raw ESC reaches the OK line that quotes the header" \
  || bad "no raw ESC reaches the OK line that quotes the header" "rc=$RC out=$(printf '%s' "$OUT" | cat -v)"
case "$OUT" in *"conventional header: fix: a subject with ?[31m in it"*) ok "and the byte is shown as a replacement, in place" ;;
  *) bad "the ESC is shown as a replacement in place" "$(printf '%s' "$OUT" | cat -v)" ;; esac
# The violation path: the same bytes in a header the shape rule refuses.
run_stdin "no type here ${ESC}[31m at all"
[ "$RC" -eq 1 ] && case "$OUT" in *"$ESC"*) false ;; *) true ;; esac \
  && ok "no raw ESC reaches the shape violation that quotes the header" \
  || bad "no raw ESC reaches the shape violation that quotes the header" "rc=$RC out=$(printf '%s' "$OUT" | cat -v)"
# The length path, and the generated-header path that skips both rules.
run_stdin "fix: a subject with ${ESC}[31m in it" "GROWTH_GUARDS_SUBJECT_MAX=5"
[ "$RC" -eq 1 ] && case "$OUT" in *"$ESC"*) false ;; *) true ;; esac \
  && ok "no raw ESC reaches the length violation that quotes the header" \
  || bad "no raw ESC reaches the length violation that quotes the header" "rc=$RC out=$(printf '%s' "$OUT" | cat -v)"
run_stdin "Revert \"fix: a subject with ${ESC}[31m in it\""
[ "$RC" -eq 0 ] && case "$OUT" in *"$ESC"*) false ;; *) true ;; esac \
  && ok "no raw ESC reaches the generated-header notice, which quotes it too" \
  || bad "no raw ESC reaches the generated-header notice" "rc=$RC out=$(printf '%s' "$OUT" | cat -v)"

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
case "$OUT" in *"write one of: changelog.d/*/*.md"*) ok "the diagnostic names the fragment globs, unescaped, as they have to be typed" ;;
  *) bad "the diagnostic names the fragment globs unescaped" "$OUT" ;; esac
# The record is NOT offered as a remedy: changelog-entries runs earlier in the
# same chain and refuses a hand-added [Unreleased] line, so a writer who took
# that advice would be refused by the next lane.
printf '%s\n' "$OUT" | grep -F 'write one of:' | grep -qF 'CHANGELOG.md' \
  && bad "the remedy does not send a writer at the record" "$OUT" \
  || ok "the remedy does not send a writer at the record"
case "$OUT" in *"CHANGELOG.md counts only under GROWTH_GUARDS_CHANGELOG_COLLATE=1"*) ok "the record is named as the release commit's own write, and what declares it" ;;
  *) bad "the record is named as the release commit's own write" "$OUT" ;; esac
run_rc 'fix(KEN-1): change a crate [no-changelog]'
[ "$RC" -eq 0 ] && ok "[no-changelog] in the header waives it" \
  || bad "[no-changelog] in the header waives it" "rc=$RC out=$OUT"
# The control for that waiver: it is the HEADER that carries it. A body
# mention is prose, and reading the whole message would let one waive a gate
# every doc says lives on the subject line.
run_rc "$(printf 'fix(KEN-1): change a crate\n\nThe rule here is [no-changelog] for pure refactors.\n')"
[ "$RC" -eq 1 ] && case "$OUT" in *"changed without a changelog entry"*) true ;; *) false ;; esac \
  && ok "control: [no-changelog] in the body alone waives nothing" \
  || bad "control: [no-changelog] in the body alone waives nothing" "rc=$RC out=$OUT"
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
# The record counts for the release commit that collates, and only there: an
# edit to a section released long ago is not an entry, and changelog-entries
# judges only the lines a commit GAINS under [Unreleased].
printf '# Changelog\n\n## [Unreleased]\n\n- A fix consumers see.\n\n## [1.0.0] - 2026-01-01\n\n- A released entry.\n' >"$RC_REPO/CHANGELOG.md"
git -C "$RC_REPO" add -A
run_rc 'chore(release): collate the changelog'
[ "$RC" -eq 1 ] && case "$OUT" in *"changed without a changelog entry"*) true ;; *) false ;; esac \
  && ok "the record alone is no entry — nothing declares this a collation" \
  || bad "the record alone is no entry" "rc=$RC out=$OUT"
OUT=""; RC=0
OUT="$(cd "$RC_REPO" && printf 'chore(release): collate the changelog\n' | GROWTH_GUARDS_CHANGELOG_COLLATE=1 "$CM" 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && ok "GROWTH_GUARDS_CHANGELOG_COLLATE=1 makes the collated record the entry" \
  || bad "GROWTH_GUARDS_CHANGELOG_COLLATE=1 makes the collated record the entry" "rc=$RC out=$OUT"
# A correction in an ALREADY-RELEASED section is what the declaration keeps
# out: no fragment, no [no-changelog], and no line gained under [Unreleased]
# for the sibling lane to catch.
git -C "$RC_REPO" commit -qm "chore(release): collate the changelog [no-changelog]"
printf 'fn corrected() {}\n' >>"$RC_REPO/crates/core/lib.rs"
printf '# Changelog\n\n## [Unreleased]\n\n- A fix consumers see.\n\n## [1.0.0] - 2026-01-01\n\n- A released entry, spelled right.\n' >"$RC_REPO/CHANGELOG.md"
git -C "$RC_REPO" add -A
run_rc 'fix(KEN-9): change a crate'
[ "$RC" -eq 1 ] && case "$OUT" in *"changed without a changelog entry"*) true ;; *) false ;; esac \
  && ok "a text correction in a released section is not an entry either" \
  || bad "a text correction in a released section is not an entry either" "rc=$RC out=$OUT"
git -C "$RC_REPO" reset -q --hard HEAD

# A type change is a written entry: git reports T, not M, when a path swaps
# kind, and reading that as merely touched rejects a commit that replaced a
# link with a real fragment. What it became is the sibling lane's judgement.
git -C "$RC_REPO" reset -q --hard HEAD
mkdir -p "$RC_REPO/changelog.d/fixed"
printf -- '- The real entry.\n' >"$RC_REPO/real-entry.md"
ln -s ../../real-entry.md "$RC_REPO/changelog.d/fixed/ken-t.md"
git -C "$RC_REPO" add -A
git -C "$RC_REPO" commit -qm "chore: a fragment that is a link [no-changelog]"
[ "$(git -C "$RC_REPO" ls-files -s changelog.d/fixed/ken-t.md | cut -d' ' -f1)" = "120000" ] \
  && ok "fixture: HEAD really carries that fragment as a symlink" \
  || bad "fixture: HEAD carries that fragment as a symlink" "$(git -C "$RC_REPO" ls-files -s changelog.d/fixed/ken-t.md)"
rm -f "$RC_REPO/changelog.d/fixed/ken-t.md"
printf -- '- The real entry.\n' >"$RC_REPO/changelog.d/fixed/ken-t.md"
printf 'fn typed() {}\n' >>"$RC_REPO/crates/core/lib.rs"
git -C "$RC_REPO" add -A
[ -n "$(cd "$RC_REPO" && git diff --cached --name-status | grep '^T')" ] \
  && ok "fixture: git reports it as a type change, not a modification" \
  || bad "fixture: git reports it as a type change" "$(cd "$RC_REPO" && git diff --cached --name-status)"
run_rc 'fix(KEN-T): replace a link with a real fragment'
[ "$RC" -eq 0 ] && ok "a fragment that changed type is a written entry" \
  || bad "a fragment that changed type is a written entry" "rc=$RC out=$OUT"
# The control: the same type change with no fragment among it still owes one,
# so the pass above is the entry and not the rule going quiet.
git -C "$RC_REPO" reset -q --hard HEAD
printf 'fn typed_only() {}\n' >>"$RC_REPO/crates/core/lib.rs"
ln -sf ../../real-entry.md "$RC_REPO/other-link"
git -C "$RC_REPO" add -A
run_rc 'fix(KEN-T): change a crate'
[ "$RC" -eq 1 ] && case "$OUT" in *"changed without a changelog entry"*) true ;; *) false ;; esac \
  && ok "control: a type change outside the fragment globs is no entry" \
  || bad "control: a type change outside the fragment globs is no entry" "rc=$RC out=$OUT"
git -C "$RC_REPO" reset -q --hard HEAD
rm -f "$RC_REPO/other-link"

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

# The second glob of the list is enforced as much as the first: this repo
# ships "crates/* ui/*" and ui/ is the half nothing else here reaches.
git -C "$RC_REPO" reset -q --hard HEAD
mkdir -p "$RC_REPO/ui/src"
printf 'export const x = 1;\n' >"$RC_REPO/ui/src/a.ts"
git -C "$RC_REPO" add -A
run_rc 'fix(KEN-6): change the UI'
[ "$RC" -eq 1 ] && case "$OUT" in *"ui/src/a.ts changed without a changelog entry"*) true ;; *) false ;; esac \
  && ok "a path matching the SECOND required glob owes an entry too, and is the one named" \
  || bad "a path matching the second required glob owes an entry too" "rc=$RC out=$OUT"
git -C "$RC_REPO" reset -q --hard HEAD
rm -rf -- "${RC_REPO:?}/ui"

# A rename is ONE entry under --name-only, naming the destination, so a file
# moved OUT of a required path would leave the gate nothing to see — and that
# is the direction that matters: the required path lost its content.
git -C "$RC_REPO" reset -q --hard HEAD
git -C "$RC_REPO" mv crates/core/lib.rs other-lib.rs
run_rc 'refactor(KEN-7): move a crate file out'
[ "$RC" -eq 1 ] && case "$OUT" in *"crates/core/lib.rs changed without a changelog entry"*) true ;; *) false ;; esac \
  && ok "a rename OUT of a required path is refused, naming the path it left" \
  || bad "a rename out of a required path is refused" "rc=$RC out=$OUT"
run_rc 'refactor(KEN-7): move a crate file out [no-changelog]'
[ "$RC" -eq 0 ] && ok "control: the same rename with [no-changelog] passes" \
  || bad "control: the same rename with [no-changelog] passes" "rc=$RC out=$OUT"
git -C "$RC_REPO" reset -q --hard HEAD
# A rename entirely outside the required paths owes nothing, so the fix reads
# both sides rather than treating every rename as a touch.
mkdir -p "$RC_REPO/docs"
printf 'notes\n' >"$RC_REPO/docs/a.md"
git -C "$RC_REPO" add -A
git -C "$RC_REPO" commit -qm "docs: a note"
git -C "$RC_REPO" mv docs/a.md docs/b.md
run_rc 'docs(KEN-7): rename a note'
[ "$RC" -eq 0 ] && ok "a rename within unrequired paths owes nothing" \
  || bad "a rename within unrequired paths owes nothing" "rc=$RC out=$OUT"
# And a rename INTO the fragment tree is a written entry: that path carries
# one now, which is what the evidence list is about.
git -C "$RC_REPO" reset -q --hard HEAD
mkdir -p "$RC_REPO/changelog.d/fixed"
printf -- '- A fix consumers see.\n' >"$RC_REPO/pending-entry.md"
git -C "$RC_REPO" add -A
git -C "$RC_REPO" commit -qm "chore: park an entry"
printf 'fn moved() {}\n' >>"$RC_REPO/crates/core/lib.rs"
git -C "$RC_REPO" mv pending-entry.md changelog.d/fixed/ken-7.md
git -C "$RC_REPO" add -A
run_rc 'fix(KEN-7): change a crate'
[ "$RC" -eq 0 ] && ok "a rename INTO the fragment tree is the entry" \
  || bad "a rename into the fragment tree is the entry" "rc=$RC out=$OUT"
# The control: renaming the same fragment back OUT is not writing one.
git -C "$RC_REPO" reset -q --hard HEAD
mkdir -p "$RC_REPO/changelog.d/fixed"
printf -- '- A fix consumers see.\n' >"$RC_REPO/changelog.d/fixed/ken-8.md"
git -C "$RC_REPO" add -A
git -C "$RC_REPO" commit -qm "chore: park a fragment [no-changelog]"
printf 'fn moved_again() {}\n' >>"$RC_REPO/crates/core/lib.rs"
git -C "$RC_REPO" mv changelog.d/fixed/ken-8.md parked.md
git -C "$RC_REPO" add -A
run_rc 'fix(KEN-8): change a crate'
[ "$RC" -eq 1 ] && case "$OUT" in *"changed without a changelog entry"*) true ;; *) false ;; esac \
  && ok "control: moving a fragment away is not writing one" \
  || bad "control: moving a fragment away is not writing one" "rc=$RC out=$OUT"
git -C "$RC_REPO" reset -q --hard HEAD

# The committer's diff.renames must not reach this scan. Set to copies it makes
# git pair a duplicated file as C — a status carrying two paths whose SOURCE the
# commit leaves in place — and the scan reads a vocabulary it never handled. The
# pin is what keeps the letters closed, so the control is a repo configured the
# way that would break it, judged the same as any other.
git -C "$RC_REPO" config diff.renames copies
# The copy source is a required path the commit also modifies, which is the only
# way git offers a file as a copy source at all.
printf 'fn copied() {}\n' >>"$RC_REPO/crates/core/lib.rs"
cp "$RC_REPO/crates/core/lib.rs" "$RC_REPO/docs/copy.rs"
git -C "$RC_REPO" add -A
run_rc 'fix(KEN-9): change a crate'
[ "$RC" -eq 1 ] && case "$OUT" in *"crates/core/lib.rs changed without a changelog entry"*) true ;; *) false ;; esac \
  && ok "a copy-configured repo is judged on the same status vocabulary" \
  || bad "a copy-configured repo is judged on the same status vocabulary" "rc=$RC out=$OUT"
# And the entry written beside the copy still counts: a stream the scan misread
# would lose the fragment that follows the copy record.
mkdir -p "$RC_REPO/changelog.d/fixed"
printf -- '- A fix consumers see.\n' >"$RC_REPO/changelog.d/fixed/ken-9.md"
git -C "$RC_REPO" add -A
run_rc 'fix(KEN-9): change a crate'
[ "$RC" -eq 0 ] && ok "the entry written beside a copy is still the entry" \
  || bad "the entry written beside a copy is still the entry" "rc=$RC out=$OUT"
git -C "$RC_REPO" config --unset diff.renames
git -C "$RC_REPO" reset -q --hard HEAD
rm -f "$RC_REPO/docs/copy.rs"

# A MODE change is not an entry. The scan reads blobs, not letters: a chmod
# leaves the fragment's content exactly where it was, and a letter that says
# only "modified" cannot tell that from a rewrite.
git -C "$RC_REPO" reset -q --hard HEAD
mkdir -p "$RC_REPO/changelog.d/fixed"
printf -- '- An old entry nobody is rewriting.\n' >"$RC_REPO/changelog.d/fixed/old.md"
git -C "$RC_REPO" add -A
git -C "$RC_REPO" commit -qm "chore: park an entry [no-changelog]"
printf 'fn chmodded() {}\n' >>"$RC_REPO/crates/core/lib.rs"
chmod +x "$RC_REPO/changelog.d/fixed/old.md"
git -C "$RC_REPO" add -A
run_rc 'fix(KEN-10): change a crate'
[ "$RC" -eq 1 ] && case "$OUT" in *"crates/core/lib.rs changed without a changelog entry"*) true ;; *) false ;; esac \
  && ok "a chmod on an existing fragment is not the entry" \
  || bad "a chmod on an existing fragment is not the entry" "rc=$RC out=$OUT"
# The control: editing that same fragment's content is.
git -C "$RC_REPO" reset -q --hard HEAD
printf 'fn edited() {}\n' >>"$RC_REPO/crates/core/lib.rs"
printf -- '- An old entry, now rewritten.\n' >"$RC_REPO/changelog.d/fixed/old.md"
git -C "$RC_REPO" add -A
run_rc 'fix(KEN-10): change a crate'
[ "$RC" -eq 0 ] && ok "control: rewriting the same fragment is the entry" \
  || bad "control: rewriting the same fragment is the entry" "rc=$RC out=$OUT"
# A symlink fragment replaced by a regular file holding the link target's own
# bytes: git reports a type change and BOTH SIDES CARRY THE SAME BLOB, so a
# sha comparison alone calls a real entry no entry at all. The path holds a
# document now where it held a link before, which is content it did not carry
# there.
git -C "$RC_REPO" reset -q --hard HEAD
rm -f "$RC_REPO/changelog.d/fixed/old.md"
ln -s -- '- A fix consumers see.' "$RC_REPO/changelog.d/fixed/old.md"
git -C "$RC_REPO" add -A
git -C "$RC_REPO" commit -qm "chore: park a symlink fragment [no-changelog]"
printf 'fn typed() {}\n' >>"$RC_REPO/crates/core/lib.rs"
rm -f "$RC_REPO/changelog.d/fixed/old.md"
printf -- '- A fix consumers see.' >"$RC_REPO/changelog.d/fixed/old.md"
git -C "$RC_REPO" add -A
# The control the case rests on: the two blobs really are the same object.
[ "$(git -C "$RC_REPO" rev-parse "HEAD:changelog.d/fixed/old.md")" = "$(git -C "$RC_REPO" rev-parse ":changelog.d/fixed/old.md")" ] \
  && ok "must-fail: the symlink and the file are one blob, so a sha says nothing" \
  || bad "the fixture's two sides are one blob" "$(git -C "$RC_REPO" diff --cached --raw -- changelog.d/fixed/old.md)"
run_rc 'fix(KEN-11): change a crate'
[ "$RC" -eq 0 ] && ok "a symlink fragment becoming a regular file is the entry" \
  || bad "a symlink fragment becoming a regular file is the entry" "rc=$RC out=$OUT"
# The other direction is not: a regular fragment becoming a symlink leaves no
# document at that path, and changelog-entries refuses one there.
git -C "$RC_REPO" reset -q --hard HEAD
printf 'fn untyped() {}\n' >>"$RC_REPO/crates/core/lib.rs"
rm -f "$RC_REPO/changelog.d/fixed/old.md"
ln -s -- '- A fix consumers see.' "$RC_REPO/changelog.d/fixed/old.md"
git -C "$RC_REPO" add -A
run_rc 'fix(KEN-11): change a crate'
[ "$RC" -eq 1 ] && case "$OUT" in *"crates/core/lib.rs changed without a changelog entry"*) true ;; *) false ;; esac \
  && ok "control: a fragment becoming a symlink is not the entry" \
  || bad "control: a fragment becoming a symlink is not the entry" "rc=$RC out=$OUT"
git -C "$RC_REPO" reset -q --hard HEAD

# And the mode alone still counts as a TOUCH, so a chmod under a required
# path is a change to it: the two sets answer different questions.
git -C "$RC_REPO" reset -q --hard HEAD
chmod +x "$RC_REPO/crates/core/lib.rs"
git -C "$RC_REPO" add -A
run_rc 'fix(KEN-10): make a crate file executable'
[ "$RC" -eq 1 ] && case "$OUT" in *"crates/core/lib.rs changed without a changelog entry"*) true ;; *) false ;; esac \
  && ok "a chmod under a required path is still a touch" \
  || bad "a chmod under a required path is still a touch" "rc=$RC out=$OUT"
git -C "$RC_REPO" reset -q --hard HEAD

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
# Every entry is validated, not the first: a list whose SECOND entry escapes
# is the same config error.
OUT=""; RC=0
OUT="$(cd "$RC_REPO" && printf 'fix(KEN-3): change a crate\n' | GROWTH_GUARDS_CHANGELOG_REQUIRED_PATHS="crates/* /etc/crates" "$CM" 2>&1)" || RC=$?
[ "$RC" -eq 2 ] && case "$OUT" in *"must be repo-root-relative"*) true ;; *) false ;; esac \
  && ok "a list whose second entry is absolute is a config error too" \
  || bad "a list whose second entry is absolute is a config error too" "rc=$RC out=$OUT"
# And a record carrying a space stays one value: word-split into the glob
# list, writing that very file would satisfy nothing.
git -C "$RC_REPO" reset -q --hard HEAD
mkdir -p "$RC_REPO/docs"
printf '# Changelog\n\n## [Unreleased]\n' >"$RC_REPO/docs/My Changelog.md"
printf 'fn spaced() {}\n' >>"$RC_REPO/crates/core/lib.rs"
git -C "$RC_REPO" add -A
OUT=""; RC=0
OUT="$(cd "$RC_REPO" && printf 'fix(KEN-5): change a crate\n' | GROWTH_GUARDS_CHANGELOG_COLLATE=1 GROWTH_GUARDS_CHANGELOG_RECORD="docs/My Changelog.md" "$CM" 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && ok "a record path carrying a space satisfies the rule when it is written" \
  || bad "a record path carrying a space satisfies the rule when it is written" "rc=$RC out=$OUT"
# The control: the same commit without that file owes an entry, so the pass
# above is the record matching and not the rule going quiet.
git -C "$RC_REPO" rm -q --cached "docs/My Changelog.md"
OUT=""; RC=0
OUT="$(cd "$RC_REPO" && printf 'fix(KEN-5): change a crate\n' | GROWTH_GUARDS_CHANGELOG_COLLATE=1 GROWTH_GUARDS_CHANGELOG_RECORD="docs/My Changelog.md" "$CM" 2>&1)" || RC=$?
[ "$RC" -eq 1 ] && ok "control: without it the same commit still owes an entry" \
  || bad "control: without it the same commit still owes an entry" "rc=$RC out=$OUT"
git -C "$RC_REPO" reset -q --hard HEAD
rm -rf -- "${RC_REPO:?}/docs"
OUT=""; RC=0
OUT="$(cd "$RC_REPO" && printf 'fix(KEN-3): change a crate\n' | GROWTH_GUARDS_CHANGELOG_PATHS="" "$CM" 2>&1)" || RC=$?
[ "$RC" -eq 2 ] && case "$OUT" in *"GROWTH_GUARDS_CHANGELOG_PATHS names no path"*) true ;; *) false ;; esac \
  && ok "an empty fragment glob list is the same config error both lanes give" \
  || bad "an empty fragment glob list is the same config error both lanes give" "rc=$RC out=$OUT"
OUT=""; RC=0
OUT="$(cd "$RC_REPO" && printf 'fix(KEN-3): change a crate\n' | GROWTH_GUARDS_CHANGELOG_RECORD=changelog.d/fixed/x.md "$CM" 2>&1)" || RC=$?
[ "$RC" -eq 2 ] && case "$OUT" in *"is also matched by GROWTH_GUARDS_CHANGELOG_PATHS"*) true ;; *) false ;; esac \
  && ok "and the overlap between the two scopes is one judgement, made in the shared resolution" \
  || bad "and the overlap between the two scopes is one judgement" "rc=$RC out=$OUT"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
