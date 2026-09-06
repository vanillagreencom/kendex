#!/usr/bin/env bash
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
unset DOC_LIMITS_CLASSES DOC_LIMITS_DEFAULT_CLASSES DOC_LIMITS_EXCLUDES DOC_LIMITS_SETTINGS_FILE
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SR="$TEST_DIR/../scripts/doc-limits"
TMP="$(mktemp -d)"
trap 'rm -rf -- "${TMP:?}"' EXIT
R="$TMP/repo"
mkdir -p "$R/.agents/skills/owned" "$R/.agents/skills/rendered" "$R/tools"
git -C "$R" -c init.defaultBranch=main init -q
git -C "$R" config user.email test@example.com
git -C "$R" config user.name test
export DOC_LIMITS_CLASSES='*.md=1k'
printf '[[skills]]\nname = "owned"\nsource = "in-place"\n' >"$R/kendex.toml"
# The render writer omits the adopted source and records only its renders.
printf '[".agents/skills/rendered/SKILL.md"]\n' >"$R/.kendex-generated.json"
head -c 1025 /dev/zero | tr '\0' x >"$R/.agents/skills/rendered/SKILL.md"
printf 'owned\n' >"$R/.agents/skills/owned/SKILL.md"
git -C "$R" add -A
git -C "$R" commit -qm fixture
expect() { # EXIT [ARG...]
  local expected="$1" rc=0 out
  shift
  out="$(cd "$R" && "$SR" "$@" 2>&1)" || rc=$?
  [ "$rc" -eq "$expected" ] || { printf 'expected %s, got %s\n%s\n' "$expected" "$rc" "$out"; return 1; }
}
for mode in worktree staged; do
  args=()
  [ "$mode" != staged ] || args=(--staged)
  expect 0 ${args[@]+"${args[@]}"}
  head -c 1025 /dev/zero | tr '\0' x >"$R/.agents/skills/owned/SKILL.md"
  git -C "$R" add .agents/skills/owned/SKILL.md
  expect 1 ${args[@]+"${args[@]}"}
  printf 'owned\n' >"$R/.agents/skills/owned/SKILL.md"
  git -C "$R" add .agents/skills/owned/SKILL.md
  expect 0 ${args[@]+"${args[@]}"}
done

# Unstaged ownership changes cannot authorize a staged scan.
printf '[]\n' >"$R/.kendex-generated.json"
expect 1
expect 0 --staged
git -C "$R" add .kendex-generated.json
expect 1 --staged
git -C "$R" checkout HEAD -- .kendex-generated.json
git -C "$R" rm -q --cached .kendex-generated.json
expect 2 --staged
git -C "$R" add .kendex-generated.json
rm "$R/.kendex-generated.json"
expect 0
git -C "$R" checkout -- .kendex-generated.json
printf '{}\n' >"$R/.kendex-generated.json"
git -C "$R" add .kendex-generated.json
expect 2
expect 2 --staged
git -C "$R" checkout HEAD -- .kendex-generated.json
printf '!.agents/skills/rendered/*\tmeasure this render explicitly\n' >"$R/tools/doc-limits-excludes"
git -C "$R" add tools/doc-limits-excludes
expect 1
expect 1 --staged
git -C "$R" rm -qf tools/doc-limits-excludes

# Keep the lookup text but disable its execution in a private script copy.
mkdir -p "$TMP/skills/doc-limits"
cp -R "$TEST_DIR/../scripts" "$TMP/skills/doc-limits/scripts"
ln -s "$TEST_DIR/../../commit-guards" "$TMP/skills/commit-guards"
MUTANT="$TMP/skills/doc-limits/scripts/doc-limits"
[ "$(grep -Fc '  generated_path_contains "$1"' "$MUTANT")" -eq 1 ]
sed 's/  generated_path_contains "\$1"/  false \&\& generated_path_contains "$1"/' "$SR" >"$MUTANT"
if cmp -s "$SR" "$MUTANT"; then exit 1; fi
SR="$MUTANT"
for mode in worktree staged; do
  args=()
  [ "$mode" != staged ] || args=(--staged)
  if expect 0 ${args[@]+"${args[@]}"} >"$TMP/mutation.log"; then
    echo 'disabled inventory exclusion survived' >&2; exit 1
  fi
  expect 1 ${args[@]+"${args[@]}"}
done
echo 'doc-limits generated paths: passed; disabled exclusions failed both controls'
