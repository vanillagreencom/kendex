#!/usr/bin/env bash
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
unset DOC_LIMITS_CLASSES DOC_LIMITS_DEFAULT_CLASSES DOC_LIMITS_EXCLUDES DOC_LIMITS_SETTINGS_FILE
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SR="$(cd "$TEST_DIR/../scripts" && pwd)/doc-limits"
TMP="$(mktemp -d)"
trap 'rm -rf -- "${TMP:?}"' EXIT
R="$TMP/repo"
mkdir -p "$R/tools"
git -C "$R" -c init.defaultBranch=main init -q
git -C "$R" config user.email test@example.com
git -C "$R" config user.name test
PASS=0
FAIL=0
expect() { # EXPECTED-EXIT LABEL: assert the preceding run's result
  if [ "$RC" -eq "$1" ]; then
    PASS=$((PASS + 1)); printf '  ok: %s\n' "$2"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL: %s: exit %s\n%s\n' "$2" "$RC" "$OUT"
  fi
}
run() {
  RC=0
  OUT="$(cd "$R" && "$SR" "$@" 2>&1)" || RC=$?
}
bytes() { # PATH COUNT: create a byte-sized text fixture
  mkdir -p "$R/$(dirname "$1")"
  head -c "$2" /dev/zero | tr '\0' x >"$R/$1"
}
export DOC_LIMITS_CLASSES='*.md=1k'
bytes AGENTS.md 1024
printf '# exclusions\n' >"$R/tools/doc-limits-excludes"
git -C "$R" add -A
git -C "$R" commit -qm 'fixture'
bytes AGENTS.md 1025
run
expect 1 'worktree growth is measured'
run --staged
expect 0 'unstaged growth does not change the staged document'
git -C "$R" add AGENTS.md
bytes AGENTS.md 1024
run --staged
expect 1 'unstaged shrink cannot hide staged growth'
run
expect 0 'worktree shrink is measured'
printf 'AGENTS.md\tfixture exception\n' >"$R/tools/doc-limits-excludes"
run --staged
expect 1 'unstaged exclusion cannot permit staged growth'
git -C "$R" add tools/doc-limits-excludes
run --staged
expect 0 'staged exclusion applies'
git -C "$R" commit -qm 'fixture exclusion'
git -C "$R" rm -q --cached tools/doc-limits-excludes
run --staged
expect 1 'a deleted exclusion ignores the remaining worktree copy'
git -C "$R" add tools/doc-limits-excludes
git -C "$R" rm -q --cached AGENTS.md
run --staged
expect 0 'a staged document deletion is outside the tracked set'
git -C "$R" add AGENTS.md
: >"$R/tools/doc-limits-excludes"
git -C "$R" add tools/doc-limits-excludes
bytes AGENTS.md 1025
git -C "$R" add AGENTS.md
unset DOC_LIMITS_CLASSES
printf '[env]\nDOC_LIMITS_CLASSES = "*.md=1k"\n' >"$R/kendex.settings.toml"
git -C "$R" add kendex.settings.toml
printf '[env]\nDOC_LIMITS_CLASSES = "*.md=2k"\n' >"$R/kendex.settings.toml"
run --staged
expect 1 'staged settings decide the staged limit'
run
expect 0 'worktree settings decide the worktree limit'
git -C "$R" add kendex.settings.toml
run --staged
expect 0 'staging the class change applies it'
git -C "$R" commit -qm 'fixture settings'
git -C "$R" rm -q --cached kendex.settings.toml
printf '[env]\nDOC_LIMITS_CLASSES = "*.md=1k"\n' >"$R/kendex.settings.toml"
run --staged
expect 0 'deleted tracked settings do not read the worktree copy'
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
