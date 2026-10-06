#!/usr/bin/env bash
# Tests for restack-skip, which says whether a restacked head needs its range
# re-test or the last passing run already validated everything but its
# version fields and changelog entries.
#
# One seed worktree validates its branch change through the real
# dev-validate-run before committing it, as dev-implement does. Each row
# copies the seed, moves origin/main by its own commit, restacks the branch
# onto it with git rebase, resolves any conflict its own way and asks
# restack-skip. The seed installs the shipped commit-guards beside its
# settings, so which file is a package, render, version or changelog file,
# and which field of a version file is its version, is commit-guards' own
# answer. The rows pin the whole answer line but its run directory.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TEST_DIR/../scripts" && pwd)"
COMMIT_GUARDS_DIR="$(cd "$TEST_DIR/../../commit-guards" && pwd)"
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
    -u WORKTREE_DEFAULT_BRANCH -u COMMIT_GUARDS_CHANGELOG_PATHS -u COMMIT_GUARDS_CHANGELOG_RECORD \
    -u COMMIT_GUARDS_CHANGELOG_VERSION_PATHS -u COMMIT_GUARDS_CHANGELOG_PACKAGE_PATHS -u COMMIT_GUARDS_SETTINGS_FILE "$@"
}

skill() { # VERSION BODY
  printf -- '---\nname: p\ndescription: d\nlicense: t\ntags: [t]\nmetadata:\n  author: t\n  version: "%s"\n---\n\n# P\n\n%s\n' "$1" "$2"
}
skills() { # DIR VERSION BODY — the package file and its render
  skill "$2" "$3" > "$1/skills/p/SKILL.md"
  skill "$2" "$3" > "$1/.agents/skills/p/SKILL.md"
}
agent() { # VERSION
  printf -- '---\nname: a\nmetadata:\n  version: "%s"\n---\n\nAgent.\n' "$1"
}
# An npm scripts.version, lines apart from the top-level version so the two
# conflict apart; commit-guards versions only the top-level one. The
# description sits beside the top-level version, so a lane that changes both
# conflicts over a line commit-guards does not version.
package() { # VERSION [SCRIPT] [PRIVATE] [DESCRIPTION]
  printf '{\n  "name": "p",\n  "version": "%s",\n  "description": "%s",\n  "license": "t",\n  "author": "t",\n  "scripts": {\n    "version": "%s",\n    "test": "true"\n  },\n  "private": %s\n}\n' \
    "$1" "${4:-d}" "${2:-echo branch}" "${3:-true}"
}

# The seed: main holds the base; the branch raises the skill, its render, the
# package and an undeclared agent, edits the skill's body and the package's
# scripts.version, adds a changelog entry and a code line
# and retargets a symlinked changelog fragment, validated before it is committed.
SEED="$TMP_ROOT/seed"
git init -q -b ken-1 "$SEED"
git -C "$SEED" config gc.auto 0
git -C "$SEED" config maintenance.auto false
mkdir -p "$SEED/skills/p" "$SEED/.agents/skills" "$SEED/.agents/skills/p" "$SEED/changelog.d/fixed" "$SEED/agents" "$SEED/pkg"
ln -s a.md "$SEED/changelog.d/fixed/link.md"
skills "$SEED" 1.0.0 "Body."
agent 1.0.0 > "$SEED/agents/a.md"
package 1.0.0 "echo base" > "$SEED/pkg/package.json"
printf '# Changelog\n\n### Unreleased\n\n- base entry\n' > "$SEED/pkg/CHANGELOG.md"
printf 'echo one\n' > "$SEED/code.sh"
printf '[".agents/skills/p/SKILL.md"]\n' > "$SEED/.kendex-generated.json"
g "$SEED" add -A
g "$SEED" commit -q -m base
g "$SEED" branch base-point
g "$SEED" update-ref refs/remotes/origin/main HEAD
{
  printf '[env]\n'
  printf 'DEV_VALIDATE_CMD = "true"\n'
  printf 'DEV_VALIDATE_TIMEOUT_SECS = "20"\n'
  printf 'COMMIT_GUARDS_CHANGELOG_VERSION_PATHS = "crates/app/tauri.conf.json pkg/*.json"\n'
  printf 'COMMIT_GUARDS_CHANGELOG_PACKAGE_PATHS = "skills/*/SKILL.md"\n'
} > "$SEED/kendex.settings.toml"
ln -s "$COMMIT_GUARDS_DIR" "$SEED/.agents/skills/commit-guards"
printf 'kendex.settings.toml\ntmp/\n.agents/skills/commit-guards\n' \
  >> "$(git -C "$SEED" rev-parse --path-format=absolute --git-path info/exclude)"
skills "$SEED" 1.0.1 "Body, branch."
agent 1.0.1 > "$SEED/agents/a.md"
package 1.0.1 > "$SEED/pkg/package.json"
printf -- '- branch entry\n' >> "$SEED/pkg/CHANGELOG.md"
printf 'echo two\n' >> "$SEED/code.sh"
ln -sfn b.md "${SEED:?}/changelog.d/fixed/link.md"
SEED_RUN="$(clean_env "$SCRIPTS_DIR/dev-validate-run" --worktree "$SEED" --poll 1)" || fixture_failed seed-run
grep -q 'validate=pass' <<<"$SEED_RUN" || fixture_failed seed-pass
g "$SEED" commit -q -am branch

# Main-side edits, one per row: each writes the files the other lane changed.
main_skill() { skills "$1" 1.1.0 "Body."; }
main_package() {
  package 1.0.5 "echo base" > "$1/pkg/package.json"
  printf -- '- main entry\n' >> "$1/pkg/CHANGELOG.md"
}
main_script() { package 1.0.5 "echo main" > "$1/pkg/package.json"; }
main_prose() {
  package 1.0.5 "echo base" > "$1/pkg/package.json"
  printf -- '- main entry\nMain notes.\n' >> "$1/pkg/CHANGELOG.md"
}
main_description() { package 1.0.5 "echo base" true main > "$1/pkg/package.json"; }
main_agent() { agent 1.1.0 > "$1/agents/a.md"; }
main_code() { printf 'echo uno\n' > "$1/code.sh"; }
main_other() { printf 'other\n' > "$1/other.txt"; }
main_drop_changelog() { rm -- "$1/pkg/CHANGELOG.md"; }
main_link() { ln -sfn c.md "${1:?}/changelog.d/fixed/link.md"; }

# Resolutions, one per row, each run with the rebase stopped on its conflict.
take_version() { skills "$1" 1.1.1 "Body, branch."; }
drop_both_lines() { package 1.0.6 | sed '/"version": "1.0.6"/d; /"description"/d' > "$1/pkg/package.json"; }
take_main_description() { package 1.0.6 "echo branch" true main > "$1/pkg/package.json"; }
take_package() {
  package 1.0.6 > "$1/pkg/package.json"
  printf '# Changelog\n\n### Unreleased\n\n- base entry\n- main entry\n- branch entry\n' > "$1/pkg/CHANGELOG.md"
}
take_package_private() { take_package "$1"; package 1.0.6 "echo branch" false > "$1/pkg/package.json"; }
take_package_script() { take_package "$1"; package 1.0.6 "echo third" > "$1/pkg/package.json"; }
take_package_code() { take_package "$1"; printf 'echo one\necho two\necho three\n' > "$1/code.sh"; }
take_script() { package 1.0.6 "echo third" > "$1/pkg/package.json"; }
leave_markers() {
  take_package "$1"
  printf '# Changelog\n\n### Unreleased\n\n- base entry\n<<<<<<< main\n- main entry\n=======\n- branch entry\n>>>>>>> branch\n' \
    > "$1/pkg/CHANGELOG.md"
}
rewrite_changelog() { take_package "$1"; printf 'Rewritten.\n' > "$1/pkg/CHANGELOG.md"; }
take_agent() { agent 1.1.1 > "$1/agents/a.md"; }
take_code() { printf 'echo uno\necho two\n' > "$1/code.sh"; }
keep_as_left() { :; }

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
skip_line() { # WT CONDITION PATHS
  printf 'restack=skip condition=%s validated-head=%s head=%s paths=%s rc=0\n' \
    "$2" "$(git -C "$1" rev-parse base-point)" "$(git -C "$1" rev-parse HEAD)" "$3"
}

echo "=== loose objects: asking writes none to the repository's own store ==="
FRESH="$(make_row fresh main_package take_package)" || fixture_failed row-fresh
loose_before="$(git -C "$FRESH" count-objects -v | sed -n 's/^count: //p')"
fresh_answer="$(ask "$SCRIPTS_DIR/restack-skip" "$FRESH")"
assert_eq "${fresh_answer%% *} $(git -C "$FRESH" count-objects -v | sed -n 's/^count: //p')" "restack=skip $loose_before" \
  "the first ask of a fresh restack skips and adds no loose object"

echo "=== a restack skips only where it resolved no conflict, or only version and changelog lines ==="
# label|row|main edit|resolution|answer (skip:CONDITION:PATHS or the retest line)
ROWS=(
  "a metadata.version line both lanes raised in a skill and its render re-tests: restack-skip reads no field in a package or render file|version|main_skill|take_version|restack=retest cause=unclassified path=.agents/skills/p/SKILL.md rc=1"
  "a package version and changelog entries both lanes wrote skip as version-only|package|main_package|take_package|skip:version-only:pkg/CHANGELOG.md,pkg/package.json"
  "a clean restack over another file skips as no-conflict|clean|main_other|keep_as_left|skip:no-conflict:none"
  "a resolution that also edits code the merge did not conflict on re-tests|code|main_package|take_package_code|restack=retest cause=path-unconflicted path=code.sh rc=1"
  "a conflict over a version file's other lines, resolved by dropping both, re-tests|region|main_description|drop_both_lines|restack=retest cause=hunk path=pkg/package.json rc=1"
  "a conflict over a version file's other lines, resolved to the base's side, re-tests|main-body|main_description|take_main_description|restack=retest cause=hunk path=pkg/package.json rc=1"
  "an npm scripts.version both lanes changed, resolved to a third command, re-tests|script|main_script|take_script|restack=retest cause=hunk path=pkg/package.json rc=1"
  "a resolution that also changes an unconflicted scripts.version re-tests|script-unconflicted|main_package|take_package_script|restack=retest cause=hunk path=pkg/package.json rc=1"
  "a conflict over code re-tests|conflict-code|main_code|take_code|restack=retest cause=unclassified path=code.sh rc=1"
  "a version line in a markdown file commit-guards declares no package re-tests|undeclared|main_agent|take_agent|restack=retest cause=unclassified path=agents/a.md rc=1"
  "a version file whose resolution also changes another line re-tests|private|main_package|take_package_private|restack=retest cause=hunk path=pkg/package.json rc=1"
  "conflict markers left in a changelog re-test|markers|main_package|leave_markers|restack=retest cause=hunk path=pkg/CHANGELOG.md rc=1"
  "a changelog replaced by prose re-tests|prose|main_package|rewrite_changelog|restack=retest cause=hunk path=pkg/CHANGELOG.md rc=1"
  "a changelog conflict over prose, resolved by dropping it, re-tests|prose-region|main_prose|take_package|restack=retest cause=hunk path=pkg/CHANGELOG.md rc=1"
  "a modify/delete conflict over a changelog, resolved by keeping the modified side, re-tests|modify-delete|main_drop_changelog|keep_as_left|restack=retest cause=conflict-kind path=pkg/CHANGELOG.md rc=1"
  "a symlinked fragment both lanes retargeted, kept as git keeps it, re-tests|symlink|main_link|keep_as_left|restack=retest cause=conflict-kind path=changelog.d/fixed/link.md rc=1"
)
for row in "${ROWS[@]}"; do
  IFS='|' read -r label name main resolve want <<<"$row"
  wt="$(make_row "$name" "$main" "$resolve")" || fixture_failed "row-$name"
  if [[ "$want" == skip:* ]]; then
    want="${want#skip:}"
    want="$(skip_line "$wt" "${want%%:*}" "${want#*:}")"
  fi
  assert_eq "$(ask "$SCRIPTS_DIR/restack-skip" "$wt")" "$want" "$label"
done

echo "=== a fact the check cannot read re-tests ==="
cp -a -- "$TMP_ROOT/package" "$TMP_ROOT/package-undeclared"
sed -i.bak '/^COMMIT_GUARDS_CHANGELOG_VERSION_PATHS/d' "$TMP_ROOT/package-undeclared/kendex.settings.toml"
assert_eq "$(ask "$SCRIPTS_DIR/restack-skip" "$TMP_ROOT/package-undeclared")" \
  "restack=retest cause=unclassified path=pkg/CHANGELOG.md rc=1" \
  "a package whose package.json COMMIT_GUARDS_CHANGELOG_VERSION_PATHS does not declare has no changelog of its own, and re-tests"
cp -a -- "$TMP_ROOT/package" "$TMP_ROOT/no-classifier"
rm -- "$TMP_ROOT/no-classifier/.agents/skills/commit-guards"
assert_eq "$(ask "$SCRIPTS_DIR/restack-skip" "$TMP_ROOT/no-classifier")" "restack=retest cause=classifier-missing rc=1" \
  "a worktree with no commit-guards install re-tests"
cp -a -- "$TMP_ROOT/package" "$TMP_ROOT/no-run"
rm -rf -- "$TMP_ROOT/no-run/tmp"
assert_eq "$(ask "$SCRIPTS_DIR/restack-skip" "$TMP_ROOT/no-run")" "restack=retest cause=no-passing-run rc=1" \
  "a worktree with no passing run re-tests"
cp -a -- "$TMP_ROOT/package" "$TMP_ROOT/no-tree"
sed -i.bak '/^tree=/d' "$TMP_ROOT"/no-tree/tmp/dev-validate-*/start
assert_eq "$(ask "$SCRIPTS_DIR/restack-skip" "$TMP_ROOT/no-tree")" "restack=retest cause=no-passing-run rc=1" \
  "a passing run whose record names no tree re-tests"
cp -a -- "$TMP_ROOT/package" "$TMP_ROOT/lost-tree"
sed -i.bak "s/^tree=.*/tree=$(printf '%040d' 7)/" "$TMP_ROOT"/lost-tree/tmp/dev-validate-*/start
assert_eq "$(ask "$SCRIPTS_DIR/restack-skip" "$TMP_ROOT/lost-tree")" "restack=retest cause=object-missing rc=1" \
  "a validated tree the repository no longer holds re-tests"
# A range run on the restacked head that fails, then the skip check asked
# again, as a re-entry of the restack cycle after a red verdict would.
cp -a -- "$TMP_ROOT/package" "$TMP_ROOT/newer-red"
# Run directories are named for the second they start: the red run must sort
# after the seed's pass.
sleep 1
sed -i.bak 's/^DEV_VALIDATE_CMD = .*/DEV_VALIDATE_CMD = "false"/' "$TMP_ROOT/newer-red/kendex.settings.toml"
printf 'DEV_VALIDATE_RANGE_CMD = "false"\n' >> "$TMP_ROOT/newer-red/kendex.settings.toml"
clean_env "$SCRIPTS_DIR/dev-validate-run" --worktree "$TMP_ROOT/newer-red" --poll 1 --validate-mode range --base origin/main \
  >/dev/null 2>&1 && fixture_failed newer-red-passed
assert_eq "$(ask "$SCRIPTS_DIR/restack-skip" "$TMP_ROOT/newer-red")" "restack=retest cause=newer-red rc=1" \
  "a range run that failed on the restacked head re-tests when asked again"

echo "=== controls: each rule, removed, lets its row skip ==="
# control NAME FILE OLD NEW ROW — ROW's answer under copies of the scripts with
# one rule removed from FILE; a skip line means the row depended on that rule.
control() {
  local dir
  dir="$(mutant_scripts "$1" "$2")" || exit 1
  mutate_file "$dir/$2" "$3" "$4"
  ask "$dir/restack-skip" "$TMP_ROOT/$5"
}
version_only() { skip_line "$TMP_ROOT/$1" version-only "$2"; }
assert_eq "$(control no-hunk restack-skip '      cmp -s -- "$scratch/merged-kept" "$scratch/head-kept" \' '      : \' private)" \
  "$(version_only private pkg/CHANGELOG.md,pkg/package.json)" \
  "control: with no comparison against the merge's sides an edited version file skips"
assert_eq "$(control no-changelog-hunk restack-skip '&& cmp -s -- "$scratch/merged-kept" "$scratch/head-kept"' '&& :' prose)" \
  "$(version_only prose pkg/CHANGELOG.md,pkg/package.json)" \
  "control: with no changelog comparison a changelog replaced by prose skips"
assert_eq "$(control no-conflicted restack-skip 'is_conflicted "$path" || retest' ': || retest' code)" \
  "$(version_only code pkg/CHANGELOG.md,pkg/package.json)" \
  "control: with no conflicted-path rule an unconflicted code edit skips"
assert_eq "$(control no-region restack-skip 'region { if (!allowed($0)) { bad = 1; exit 3 } next }' 'region { next }' prose-region)" \
  "$(version_only prose-region pkg/CHANGELOG.md,pkg/package.json)" \
  "control: with no changelog conflict-region rule a dropped prose conflict skips"
assert_eq "$(control no-sides restack-skip '    region && region != side { next }' '    region { next }' region)" \
  "$(version_only region pkg/package.json)" \
  "control: with conflict regions dropped instead of read side by side a dropped conflict skips"
assert_eq "$(control one-side restack-skip 'for side in 1 2; do' 'for side in 1; do' main-body)" \
  "$(version_only main-body pkg/package.json)" \
  "control: with the branch's side unread a conflict resolved to the base's side skips"
assert_eq "$(control no-unclassified restack-skip '*) retest unclassified' '*) kind=fragment ;; #' undeclared)" \
  "$(version_only undeclared agents/a.md)" \
  "control: with no unclassified rule an undeclared markdown version line skips"
# A strip that drops a version key at any depth reads an npm scripts.version
# as the version field, so each row that changes one, conflicted or not,
# skips under it.
for name in script script-unconflicted; do
  assert_eq "$(control "depth-free-json-$name" restack-skip 'unversion() { "$classifier" --unversion 2>/dev/null; }' \
    "unversion() { grep -Ev '^[[:space:]]*\"version\"[[:space:]]*:'; }" "$name")" \
    "$(version_only "$name" "$([[ $name == script ]] || printf 'pkg/CHANGELOG.md,')pkg/package.json")" \
    "control: with a depth-free JSON version strip the $name row skips"
done
for name in markers prose; do
  assert_eq "$(control "no-changelog-grammar-$name" restack-skip 'function allowed(line) { return line ~' 'function allowed(line) { return 1 || line ~' "$name")" \
    "$(version_only "$name" pkg/CHANGELOG.md,pkg/package.json)" \
    "control: with no changelog line rule the $name row skips"
done
assert_eq "$(control no-conflict-kind restack-skip 'CONFLICT*) retest conflict-kind' 'CONFLICT*) : conflict-kind' modify-delete)" \
  "$(version_only modify-delete pkg/CHANGELOG.md)" \
  "control: with no conflict-kind rule a modify/delete conflict skips"
assert_eq "$(control no-mode restack-skip '          *) retest conflict-kind "path=$path" "run-dir=$run_dir" ;;' '          *) ;;' symlink)" \
  "$(version_only symlink changelog.d/fixed/link.md)" \
  "control: with no regular-file mode rule a symlink conflict skips"
assert_eq "$(control no-newer-red dev-validate-run $'      red="$run_dir"\n      continue' '      continue' newer-red)" \
  "$(version_only newer-red pkg/CHANGELOG.md,pkg/package.json)" \
  "control: with no newer-red rule in dev-validate-run a failed head skips"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
