#!/usr/bin/env bash
# Surface: changelog-entries --collated. Inputs: scripts/changelog-entries and scripts/lib/.
# Release callers supply an immutable PR head; current index changes must not replace it.
set -euo pipefail
TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL_DIR="$(cd -- "$TEST_DIR/.." && pwd -P)"
CE="$SKILL_DIR/scripts/changelog-entries"
# shellcheck source=lib/harness.bash
. "$TEST_DIR/lib/harness.bash"
unset COMMIT_GUARDS_CHANGELOG_PATHS COMMIT_GUARDS_CHANGELOG_RECORD COMMIT_GUARDS_CHANGELOG_PACKAGE_PATHS COMMIT_GUARDS_CHANGELOG_VERSION_PATHS COMMIT_GUARDS_SETTINGS_FILE

R="$TMP/repo"
mkdir -p "$R/changelog.d/fixed"
git -C "$R" -c init.defaultBranch=main init -q
git -C "$R" config gc.auto 0
git -C "$R" config maintenance.auto false
git -C "$R" config user.name fixture
git -C "$R" config user.email fixture@example.invalid
printf 'Format.\n' >"$R/changelog.d/README.md"
git -C "$R" add -A
git -C "$R" commit -qm clean
CLEAN="$(git -C "$R" rev-parse HEAD)"
printf -- '- Pending entry.\n' >"$R/changelog.d/fixed/pending.md"
git -C "$R" add -A
git -C "$R" commit -qm pending
PENDING="$(git -C "$R" rev-parse HEAD)"
git -C "$R" rm -q changelog.d/fixed/pending.md
printf 'Stray entry.\n' >"$R/changelog.d/stray.txt"
git -C "$R" add -A
git -C "$R" commit -qm stray
STRAY="$(git -C "$R" rev-parse HEAD)"
git -C "$R" rm -q changelog.d/stray.txt

run() { # SCRIPT REF: RC and OUT contain the command result.
  RC=0
  OUT="$(cd -- "$R" && "$1" --collated "$2" 2>&1)" || RC=$?
}
assert_eq() { # ACTUAL EXPECTED LABEL
  [ "$1" = "$2" ] || { printf 'FAIL: %s: expected [%s], got [%s]\n' "$3" "$2" "$1" >&2; exit 1; }
  printf 'ok: %s\n' "$3"
}

BEFORE="$(git -C "$R" status --porcelain)"
while IFS='|' read -r label ref expected; do
  run "$CE" "$ref"
  assert_eq "$RC" "$expected" "$label"
done <<ROWS
clean snapshot with a dirty index|$CLEAN|0
pending snapshot with its fragment deleted from the index|$PENDING|1
stray snapshot under the configured root|$STRAY|1
unknown snapshot|ffffffffffffffffffffffffffffffffffffffff|2
ROWS
assert_eq "$(git -C "$R" status --porcelain)" "$BEFORE" 'snapshot checks leave the index and files unchanged'

# The same pending-snapshot assertion must turn red when its verdict is ignored.
gg_mutant CONTROL changelog-entries '[ "$violations" -eq 0 ] || exit 1' ': '\''[ "$violations" -eq 0 ] || exit 1'\'''
run "$CONTROL" "$PENDING"
assert_eq "$RC" 0 'control: ignoring pending fragments permits the release'

gg_mutant STRAY_CONTROL changelog-entries '    refuse fragment-stray ' '    : refuse fragment-stray '
run "$STRAY_CONTROL" "$STRAY"
assert_eq "$RC" 0 'control: ignoring the stray file permits the release'

# A failed Git tree read cannot become an empty snapshot.
REAL_GIT="$(command -v git)"
mkdir -p "$TMP/bin"
printf '#!/usr/bin/env bash\nset -euo pipefail\n[ "$1" != ls-tree ] || exit 1\nexec %q "$@"\n' "$REAL_GIT" >"$TMP/bin/git"
chmod +x "$TMP/bin/git"
PATH="$TMP/bin:$PATH" run "$CE" "$CLEAN"
assert_eq "$RC" 2 'unreadable snapshot refuses'
gg_mutant READ_CONTROL changelog-entries 'git ls-tree -rz "$COLLATED_REF"' ': git ls-tree -rz "$COLLATED_REF"'
PATH="$TMP/bin:$PATH" run "$READ_CONTROL" "$CLEAN"
assert_eq "$RC" 0 'control: an ignored tree read permits the release'
