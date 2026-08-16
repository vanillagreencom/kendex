#!/usr/bin/env bash
# Pins for scripts/commit-msg: the conventional header shape in both
# directions, the two MUSTs from the family contract — uppercase issue
# keys in scopes pass, git-generated messages pass — plus header
# extraction, type-list configuration, and the exit-2 usage/collection
# lanes.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
CM="$SKILL_DIR/scripts/commit-msg"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

unset GROWTH_GUARDS_COMMIT_TYPES GROWTH_GUARDS_SETTINGS_FILE 2>/dev/null || true

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
printf '[env]\nGROWTH_GUARDS_COMMIT_TYPES = "docs"\n' >"$R/vstack.settings.toml"
run_stdin 'docs: settings-admitted type'
[ "$RC" -eq 0 ] && ok "vstack.settings.toml supplies the type list" || bad "settings file supplies the types" "rc=$RC out=$OUT"
run_stdin 'feat: settings-rejected type'
[ "$RC" -eq 1 ] && ok "control: the settings-restricted list really rejects other types" \
  || bad "control: settings-restricted list rejects" "rc=$RC out=$OUT"
rm "$R/vstack.settings.toml"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
