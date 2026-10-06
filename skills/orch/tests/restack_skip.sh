#!/usr/bin/env bash
# Tests for restack-skip, which says whether a restacked head needs its range
# re-test or the last passing run already validated everything but its
# version and changelog lines.
#
# One seed worktree validates its branch change through the real
# dev-validate-run before committing it, as dev-implement does. Each row
# copies the seed, moves origin/main by its own commit, restacks the branch
# onto it with git rebase, resolves any conflict its own way and asks
# restack-skip. The rows pin the whole answer line but its run directory.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TEST_DIR/../scripts" && pwd)"
# shellcheck source=lib/assertions.sh
source "$TEST_DIR/lib/assertions.sh"
# shellcheck source=lib/growth-state.sh
source "$TEST_DIR/lib/growth-state.sh"
TMP_ROOT="$(mktemp -d)" || { echo "restack_skip: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "restack_skip: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "restack_skip: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

fixture_failed() { echo "restack_skip: fixture=failed step=$1" >&2; exit 1; }
g() { git -C "$1" -c user.name=t -c user.email=t@example.com "${@:2}"; }
# The environment every script call runs under: none of the caller's
# DEV_VALIDATE_* or COMMIT_GUARDS_* settings, so the fixture's own file decides.
clean_env() {
  env -u DEV_VALIDATE_CMD -u DEV_VALIDATE_RANGE_CMD -u DEV_VALIDATE_TIMEOUT_SECS -u DEV_VALIDATE_BASE \
    -u DEV_VALIDATE_CLASS -u DEV_VALIDATE_DOCS_ONLY -u DEV_VALIDATE_PATHS -u DEV_VALIDATE_CI_CONTEXT \
    -u WORKTREE_DEFAULT_BRANCH -u COMMIT_GUARDS_CHANGELOG_PATHS -u COMMIT_GUARDS_CHANGELOG_VERSION_PATHS "$@"
}

skill() { # VERSION BODY
  printf -- '---\nname: p\nmetadata:\n  author: t\n  version: "%s"\n---\n\n# P\n\n%s\n' "$1" "$2"
}
agent() { # VERSION
  printf -- '---\nname: a\nmetadata:\n  version: "%s"\n---\n\nAgent.\n' "$1"
}
package() { # VERSION
  printf '{\n  "name": "p",\n  "version": "%s",\n  "private": true\n}\n' "$1"
}

# The seed: main holds the base; the branch raises the skill and the package,
# edits the skill's body, adds a changelog entry and a code line, validated
# before it is committed.
SEED="$TMP_ROOT/seed"
git init -q -b ken-1 "$SEED"
git -C "$SEED" config gc.auto 0
git -C "$SEED" config maintenance.auto false
mkdir -p "$SEED/skills/p" "$SEED/agents" "$SEED/pkg"
skill 1.0.0 "Body." > "$SEED/skills/p/SKILL.md"
agent 1.0.0 > "$SEED/agents/a.md"
package 1.0.0 > "$SEED/pkg/package.json"
printf '# Changelog\n\n### Unreleased\n\n- base entry\n' > "$SEED/pkg/CHANGELOG.md"
printf 'echo one\n' > "$SEED/code.sh"
g "$SEED" add -A
g "$SEED" commit -q -m base
g "$SEED" branch base-point
g "$SEED" update-ref refs/remotes/origin/main HEAD
{
  printf '[env]\n'
  printf 'DEV_VALIDATE_CMD = "true"\n'
  printf 'DEV_VALIDATE_TIMEOUT_SECS = "20"\n'
  printf 'COMMIT_GUARDS_CHANGELOG_VERSION_PATHS = "crates/app/tauri.conf.json pkg/*.json"\n'
} > "$SEED/kendex.settings.toml"
printf 'kendex.settings.toml\ntmp/\n' >> "$(git -C "$SEED" rev-parse --path-format=absolute --git-path info/exclude)"
skill 1.0.1 "Body, branch." > "$SEED/skills/p/SKILL.md"
package 1.0.1 > "$SEED/pkg/package.json"
printf -- '- branch entry\n' >> "$SEED/pkg/CHANGELOG.md"
printf 'echo two\n' >> "$SEED/code.sh"
SEED_RUN="$(clean_env "$SCRIPTS_DIR/dev-validate-run" --worktree "$SEED" --poll 1)" || fixture_failed seed-run
grep -q 'validate=pass' <<<"$SEED_RUN" || fixture_failed seed-pass
g "$SEED" commit -q -am branch

# Main-side edits, one per row: each writes the files the other lane changed.
main_skill() { skill 1.1.0 "Body." > "$1/skills/p/SKILL.md"; }
main_skill_body() { skill 1.1.0 "Body, main." > "$1/skills/p/SKILL.md"; }
main_package() {
  package 1.0.5 > "$1/pkg/package.json"
  printf -- '- main entry\n' >> "$1/pkg/CHANGELOG.md"
}
main_code() { printf 'echo uno\n' > "$1/code.sh"; }
main_other() { printf 'other\n' > "$1/other.txt"; }

# Resolutions, one per row, each run with the rebase stopped on its conflict.
take_version() { skill 1.1.1 "Body, branch." > "$1/skills/p/SKILL.md"; }
take_version_body() { skill 1.1.1 "Body, edited." > "$1/skills/p/SKILL.md"; }
take_version_code() { take_version "$1"; printf 'echo one\necho two\necho three\n' > "$1/code.sh"; }
take_version_agent() { take_version "$1"; agent 1.0.1 > "$1/agents/a.md"; }
drop_both_bodies() {
  printf -- '---\nname: p\nmetadata:\n  author: t\n  version: "1.1.1"\n---\n\n# P\n\n' > "$1/skills/p/SKILL.md"
}
take_package() {
  package 1.0.6 > "$1/pkg/package.json"
  printf '# Changelog\n\n### Unreleased\n\n- base entry\n- main entry\n- branch entry\n' > "$1/pkg/CHANGELOG.md"
}
take_code() { printf 'echo uno\necho two\n' > "$1/code.sh"; }
no_conflict() { :; }

# make_row NAME MAIN RESOLVE — a copy of the seed restacked onto a main that
# MAIN moved, its conflict resolved by RESOLVE.
make_row() {
  local wt="$TMP_ROOT/$1"
  cp -a -- "$SEED" "$wt"
  g "$wt" checkout -q --detach base-point
  "$2" "$wt"
  g "$wt" add -A
  g "$wt" commit -q -m main
  g "$wt" update-ref refs/remotes/origin/main HEAD
  g "$wt" checkout -q ken-1
  if ! g "$wt" rebase -q origin/main >/dev/null 2>&1; then
    "$3" "$wt"
    g "$wt" add -A
    GIT_EDITOR=true g "$wt" rebase --continue >/dev/null 2>&1 || fixture_failed "rebase-$1"
  fi
  printf '%s\n' "$wt"
}

ask() { # SCRIPT WT — the answer line less its run directory, and the exit
  local out rc=0
  out="$(clean_env "$1" --worktree "$2" --base origin/main 2>&1)" || rc=$?
  printf '%s rc=%s\n' "$(sed -E 's/ run-dir=[^ ]*//' <<<"$out")" "$rc"
}
skip_line() { # WT PATHS
  printf 'restack=skip validated-head=%s head=%s paths=%s rc=0\n' \
    "$(git -C "$1" rev-parse base-point)" "$(git -C "$1" rev-parse HEAD)" "$2"
}

echo "=== a restack that differs from the validated tree only in version and changelog lines skips ==="
# label|row|main edit|resolution|answer (skip:PATHS or the retest line)
ROWS=(
  "a version line both lanes raised, resolved to a third version, skips|version|main_skill|take_version|skip:skills/p/SKILL.md"
  "a package version and changelog entries both lanes wrote skip|package|main_package|take_package|skip:pkg/CHANGELOG.md,pkg/package.json"
  "a clean restack over another file skips with no path|clean|main_other|no_conflict|skip:none"
  "a resolution that also edits the conflicted file's body re-tests|body|main_skill|take_version_body|restack=retest cause=hunk path=skills/p/SKILL.md rc=1"
  "a resolution that also edits code the merge did not conflict on re-tests|code|main_skill|take_version_code|restack=retest cause=path-unconflicted path=code.sh rc=1"
  "a resolution that raises a version the merge did not conflict on re-tests|agent|main_skill|take_version_agent|restack=retest cause=path-unconflicted path=agents/a.md rc=1"
  "a conflict over body lines, resolved by dropping both, re-tests|region|main_skill_body|drop_both_bodies|restack=retest cause=hunk path=skills/p/SKILL.md rc=1"
  "a conflict over code re-tests|conflict-code|main_code|take_code|restack=retest cause=hunk path=code.sh rc=1"
)
for row in "${ROWS[@]}"; do
  IFS='|' read -r label name main resolve want <<<"$row"
  wt="$(make_row "$name" "$main" "$resolve")" || fixture_failed "row-$name"
  [[ "$want" != skip:* ]] || want="$(skip_line "$wt" "${want#skip:}")"
  assert_eq "$(ask "$SCRIPTS_DIR/restack-skip" "$wt")" "$want" "$label"
done

echo "=== a fact the check cannot read re-tests ==="
cp -a -- "$TMP_ROOT/package" "$TMP_ROOT/package-undeclared"
sed -i.bak '/^COMMIT_GUARDS_CHANGELOG_VERSION_PATHS/d' "$TMP_ROOT/package-undeclared/kendex.settings.toml"
assert_eq "$(ask "$SCRIPTS_DIR/restack-skip" "$TMP_ROOT/package-undeclared")" \
  "restack=retest cause=hunk path=pkg/package.json rc=1" \
  "a version line in a file COMMIT_GUARDS_CHANGELOG_VERSION_PATHS does not declare re-tests"
cp -a -- "$TMP_ROOT/version" "$TMP_ROOT/no-run"
rm -rf -- "$TMP_ROOT/no-run/tmp"
assert_eq "$(ask "$SCRIPTS_DIR/restack-skip" "$TMP_ROOT/no-run")" "restack=retest cause=no-passing-run rc=1" \
  "a worktree with no passing run re-tests"
cp -a -- "$TMP_ROOT/version" "$TMP_ROOT/no-tree"
sed -i.bak '/^tree=/d' "$TMP_ROOT"/no-tree/tmp/dev-validate-*/start
assert_eq "$(ask "$SCRIPTS_DIR/restack-skip" "$TMP_ROOT/no-tree")" "restack=retest cause=no-passing-run rc=1" \
  "a passing run whose record names no tree re-tests"
cp -a -- "$TMP_ROOT/version" "$TMP_ROOT/lost-tree"
sed -i.bak "s/^tree=.*/tree=$(printf '%040d' 7)/" "$TMP_ROOT"/lost-tree/tmp/dev-validate-*/start
assert_eq "$(ask "$SCRIPTS_DIR/restack-skip" "$TMP_ROOT/lost-tree")" "restack=retest cause=object-missing rc=1" \
  "a validated tree the repository no longer holds re-tests"
loose_before="$(git -C "$TMP_ROOT/package" count-objects -v | sed -n 's/^count: //p')"
ask "$SCRIPTS_DIR/restack-skip" "$TMP_ROOT/package" >/dev/null
assert_eq "$(git -C "$TMP_ROOT/package" count-objects -v | sed -n 's/^count: //p')" "$loose_before" \
  "the check writes no object to the repository's own store"

echo "=== controls: each rule, removed, lets its row skip ==="
# control NAME OLD NEW ROW — ROW's answer under a copy of the script with one
# rule removed; a skip line means the row depended on that rule.
control() {
  local dir
  dir="$(mutant_scripts "$1" restack-skip)" || exit 1
  mutate_file "$dir/restack-skip" "$2" "$3"
  ask "$dir/restack-skip" "$TMP_ROOT/$4"
}
assert_eq "$(control no-hunk '&& cmp -s -- "$scratch/merged-kept" "$scratch/head-kept"' '&& :' body)" \
  "$(skip_line "$TMP_ROOT/body" skills/p/SKILL.md)" \
  "control: with no line comparison an edited body skips"
assert_eq "$(control no-conflicted 'grep -Fxq -- "$path" "$scratch/conflicted" || retest' ': || retest' agent)" \
  "$(skip_line "$TMP_ROOT/agent" agents/a.md,skills/p/SKILL.md)" \
  "control: with no conflicted-path rule an unconflicted version raise skips"
assert_eq "$(control no-region 'region { if (!allowed($0)) { bad = 1; exit 3 } next }' 'region { next }' region)" \
  "$(skip_line "$TMP_ROOT/region" skills/p/SKILL.md)" \
  "control: with no conflict-region rule a dropped body conflict skips"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
