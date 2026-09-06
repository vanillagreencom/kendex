#!/usr/bin/env bash
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$TEST_DIR/lib/harness.bash"
unset COMMIT_GUARDS_SUPPRESSION_EXCLUDES COMMIT_GUARDS_SUPPRESSION_BASELINE COMMIT_GUARDS_SETTINGS_FILE
SB="$TEST_DIR/../scripts/suppression-ban"
R="$TMP/repo"
mkdir -p "$R/.agents/skills/owned" "$R/.agents/hooks" "$R/.agents/skills/rendered"
git -C "$R" -c init.defaultBranch=main init -q
git -C "$R" config user.email test@example.com
git -C "$R" config user.name test
printf '[[skills]]\nname = "owned"\nsource = "in-place"\n' >"$R/kendex.toml"
printf '[".agents/skills/rendered/lib.rs"]\n' >"$R/.kendex-generated.json"
printf '#![allow(dead_code)]\n' >"$R/.agents/skills/rendered/lib.rs"
git -C "$R" add -A
git -C "$R" commit -qm fixture
expect() { # EXIT
  local rc=0 out
  out="$(cd "$R" && "$SB" 2>&1)" || rc=$?
  [ "$rc" -eq "$1" ] || { printf 'expected %s, got %s\n%s\n' "$1" "$rc" "$out"; return 1; }
}
expect 0
# The writer leaves both in-place skill source and the adopt hook home out.
for path in .agents/skills/owned/lib.rs .agents/hooks/check.py; do
  case "$path" in
    *.rs) printf '#![allow(dead_code)]\n' >"$R/$path" ;;
    *.py) printf '# ruff: noqa\n' >"$R/$path" ;;
  esac
  git -C "$R" add -- "$path"
  expect 1
  git -C "$R" rm -qf -- "$path"
  expect 0
done
printf '[]\n' >"$R/.kendex-generated.json"
expect 0
git -C "$R" add .kendex-generated.json
expect 1
git -C "$R" checkout HEAD -- .kendex-generated.json
# No inventory in the commit: an all-in-place project writes none, so the
# empty inventory excludes nothing and the render it used to cover is scanned.
git -C "$R" rm -q --cached .kendex-generated.json
expect 1
printf 'pub fn ok() {}\n' >"$R/.agents/skills/rendered/lib.rs"
git -C "$R" add -- .agents/skills/rendered/lib.rs
expect 0
printf '#![allow(dead_code)]\n' >"$R/.agents/skills/rendered/lib.rs"
git -C "$R" add -- .agents/skills/rendered/lib.rs
git -C "$R" add .kendex-generated.json

printf '{}\n' >"$R/.kendex-generated.json"
git -C "$R" add .kendex-generated.json
expect 2
git -C "$R" checkout HEAD -- .kendex-generated.json
mkdir -p "$R/tools"
printf '!.agents/skills/rendered/*\tmeasure this render explicitly\n' >"$R/tools/suppression-ban-excludes"
git -C "$R" add tools/suppression-ban-excludes
expect 1
git -C "$R" rm -qf tools/suppression-ban-excludes

mkdir -p "$TMP/mutant"
cp -R "$TEST_DIR/../scripts" "$TMP/mutant/scripts"
MATCHER="$TMP/mutant/scripts/lib/configured-paths.sh"
[ "$(grep -Fc '  generated_path_contains "$1"' "$MATCHER")" -eq 1 ]
sed 's/  generated_path_contains "\$1"/  false \&\& generated_path_contains "$1"/' "$TEST_DIR/../scripts/lib/configured-paths.sh" >"$MATCHER"
if cmp -s "$TEST_DIR/../scripts/lib/configured-paths.sh" "$MATCHER"; then exit 1; fi
SB="$TMP/mutant/scripts/suppression-ban"
if expect 0 >"$TMP/mutation.log"; then
  echo 'disabled inventory exclusion survived' >&2; exit 1
fi
expect 1
echo 'suppression generated paths: passed; disabled exclusion failed the control'
