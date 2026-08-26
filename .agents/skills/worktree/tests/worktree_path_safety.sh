#!/usr/bin/env bash
# Path-boundary regressions for worktree issue IDs, setup config, and direct
# path arguments. These cases must fail before writing outside the intended
# worktree or mutating another repository's registered worktree.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKTREE_SCRIPT="${WORKTREE_SCRIPT:-$(cd "$TEST_DIR/.." && pwd)/scripts/worktree}"
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

assert_eq() {
  local got="$1" want="$2" name="$3"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$name" "$want" "$got"
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" name="$3"
  if grep -qF -- "$needle" <<<"$haystack"; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        wanted substring: %s\n        in: %s\n' "$name" "$needle" "$haystack"
  fi
}

assert_path_exists() {
  local path="$1" name="$2"
  if [[ -e "$path" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        missing path: %s\n' "$name" "$path"
  fi
}

assert_path_absent() {
  local path="$1" name="$2"
  if [[ ! -e "$path" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        unexpected path: %s\n' "$name" "$path"
  fi
}

assert_file_lacks_line() {
  local path="$1" line="$2" name="$3"
  if [[ ! -f "$path" ]] || ! grep -qxF -- "$line" "$path"; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        unexpected line in %s: %s\n' "$name" "$path" "$line"
  fi
}

assert_branch_absent() {
  local repo="$1" branch="$2" name="$3"
  if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch" 2>/dev/null; then
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        unexpected branch: %s\n' "$name" "$branch"
  else
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  fi
}

make_repo() {
  local root="$1" name="${2:-main}"
  mkdir -p "$root/$name"
  git -C "$root/$name" init -q -b main
  git -C "$root/$name" config user.email test@example.com
  git -C "$root/$name" config user.name Test
  git -C "$root/$name" config commit.gpgsign false
  printf 'base\n' >"$root/$name/base.txt"
  git -C "$root/$name" add base.txt
  git -C "$root/$name" commit -q -m base
}

run_from_main() {
  local root="$1"
  shift
  set +e
  (cd "$root/main" && "$WORKTREE_SCRIPT" "$@") >"$root/out" 2>"$root/err"
  local rc=$?
  set -e
  return "$rc"
}

echo "=== issue IDs cannot escape the configured base dir ==="

ID_ROOT="$TMP_ROOT/id"
make_repo "$ID_ROOT"
set +e
(cd "$ID_ROOT/main" && "$WORKTREE_SCRIPT" path ../escape) >"$ID_ROOT/path.out" 2>"$ID_ROOT/path.err"
path_rc=$?
set -e
assert_eq "$path_rc" "1" "path rejects traversal issue ID"
assert_contains "$(cat "$ID_ROOT/path.err")" "invalid issue ID" "path traversal diagnostic names invalid issue ID"

set +e
(cd "$ID_ROOT/main" && "$WORKTREE_SCRIPT" exists /absolute) >"$ID_ROOT/exists.out" 2>"$ID_ROOT/exists.err"
exists_rc=$?
set -e
assert_eq "$exists_rc" "1" "exists rejects absolute issue ID"
assert_contains "$(cat "$ID_ROOT/exists.err")" "invalid issue ID" "exists absolute diagnostic names invalid issue ID"

set +e
(cd "$ID_ROOT/main" && "$WORKTREE_SCRIPT" create ../escape --from main) >"$ID_ROOT/create.out" 2>"$ID_ROOT/create.err"
create_rc=$?
set -e
assert_eq "$create_rc" "1" "create rejects traversal issue ID before mutation"
assert_contains "$(cat "$ID_ROOT/create.err")" "invalid issue ID" "create traversal diagnostic names invalid issue ID"
assert_path_absent "$ID_ROOT/escape" "create traversal does not create escaped path"
assert_branch_absent "$ID_ROOT/main" "../escape" "create traversal does not create escaped branch"

echo "=== setup config rejects traversal and symlink-parent writes ==="

CONFIG_ROOT="$TMP_ROOT/config"
make_repo "$CONFIG_ROOT"
git -C "$CONFIG_ROOT/main" worktree add -q -b issue-config "$CONFIG_ROOT/trees/issue-config" main
printf 'WORKTREE_MKDIRS="../escape"\n' >"$CONFIG_ROOT/main/.env"
set +e
(cd "$CONFIG_ROOT/main" && "$WORKTREE_SCRIPT" fix-links "$CONFIG_ROOT/trees/issue-config") >"$CONFIG_ROOT/fix-invalid.out" 2>"$CONFIG_ROOT/fix-invalid.err"
invalid_config_rc=$?
set -e
assert_eq "$invalid_config_rc" "1" "fix-links rejects traversal mkdir config"
assert_contains "$(cat "$CONFIG_ROOT/fix-invalid.err")" "invalid WORKTREE_MKDIRS" "traversal mkdir diagnostic names config variable"
assert_path_absent "$CONFIG_ROOT/escape" "traversal mkdir does not create outside worktree"

OVERLAP_ROOT="$TMP_ROOT/overlap"
make_repo "$OVERLAP_ROOT"
mkdir -p "$OVERLAP_ROOT/main/config"
printf 'main-config\n' >"$OVERLAP_ROOT/main/config/local.txt"
git -C "$OVERLAP_ROOT/main" add config/local.txt
git -C "$OVERLAP_ROOT/main" commit -q -m config
git -C "$OVERLAP_ROOT/main" worktree add -q -b issue-overlap "$OVERLAP_ROOT/trees/issue-overlap" main
cat >"$OVERLAP_ROOT/main/.env" <<'ENV'
WORKTREE_SYMLINKS="config"
WORKTREE_COPIES="config/local.txt"
ENV
set +e
(cd "$OVERLAP_ROOT/main" && "$WORKTREE_SCRIPT" fix-links "$OVERLAP_ROOT/trees/issue-overlap") >"$OVERLAP_ROOT/overlap.out" 2>"$OVERLAP_ROOT/overlap.err"
overlap_rc=$?
set -e
assert_eq "$overlap_rc" "1" "setup rejects child path under configured symlink path"
assert_contains "$(cat "$OVERLAP_ROOT/overlap.err")" "inside symlink path 'config'" "overlap diagnostic names symlink parent"
assert_eq "$(cat "$OVERLAP_ROOT/main/config/local.txt")" "main-config" "overlap setup does not rewrite main checkout file"

EQUAL_ROOT="$TMP_ROOT/equal"
make_repo "$EQUAL_ROOT"
mkdir -p "$EQUAL_ROOT/main/config"
printf 'main-config\n' >"$EQUAL_ROOT/main/config/local.txt"
git -C "$EQUAL_ROOT/main" add config/local.txt
git -C "$EQUAL_ROOT/main" commit -q -m config
git -C "$EQUAL_ROOT/main" worktree add -q -b issue-equal "$EQUAL_ROOT/trees/issue-equal" main
cat >"$EQUAL_ROOT/main/.env" <<'ENV'
WORKTREE_SYMLINKS="config/local.txt"
WORKTREE_COPIES="config/local.txt"
ENV
set +e
(cd "$EQUAL_ROOT/main" && "$WORKTREE_SCRIPT" fix-links "$EQUAL_ROOT/trees/issue-equal") >"$EQUAL_ROOT/equal.out" 2>"$EQUAL_ROOT/equal.err"
equal_rc=$?
set -e
assert_eq "$equal_rc" "1" "setup rejects same path across symlink and copy config"
assert_contains "$(cat "$EQUAL_ROOT/equal.err")" "both a symlink target" "equal-path diagnostic names cross-operation conflict"

FOLLOW_ROOT="$TMP_ROOT/follow"
make_repo "$FOLLOW_ROOT"
mkdir -p "$FOLLOW_ROOT/main/config"
printf 'main-config\n' >"$FOLLOW_ROOT/main/config/local.txt"
git -C "$FOLLOW_ROOT/main" add config/local.txt
git -C "$FOLLOW_ROOT/main" commit -q -m config
git -C "$FOLLOW_ROOT/main" worktree add -q -b issue-follow "$FOLLOW_ROOT/trees/issue-follow" main
rm -rf "$FOLLOW_ROOT/trees/issue-follow/config"
ln -s "$FOLLOW_ROOT/main/config" "$FOLLOW_ROOT/trees/issue-follow/config"
printf 'WORKTREE_COPIES="config/local.txt"\n' >"$FOLLOW_ROOT/main/.env"
set +e
(cd "$FOLLOW_ROOT/main" && "$WORKTREE_SCRIPT" fix-links "$FOLLOW_ROOT/trees/issue-follow") >"$FOLLOW_ROOT/follow.out" 2>"$FOLLOW_ROOT/follow.err"
follow_rc=$?
set -e
assert_eq "$follow_rc" "1" "setup rejects writing through existing symlink parent"
assert_contains "$(cat "$FOLLOW_ROOT/follow.err")" "is a symlink" "symlink-parent diagnostic names the symlink"
assert_eq "$(cat "$FOLLOW_ROOT/main/config/local.txt")" "main-config" "symlink-parent setup does not rewrite main checkout file"

LEAF_ROOT="$TMP_ROOT/leaf"
make_repo "$LEAF_ROOT"
mkdir -p "$LEAF_ROOT/main/config"
printf 'main-config\n' >"$LEAF_ROOT/main/config/local.txt"
git -C "$LEAF_ROOT/main" add config/local.txt
git -C "$LEAF_ROOT/main" commit -q -m config
git -C "$LEAF_ROOT/main" worktree add -q -b issue-leaf "$LEAF_ROOT/trees/issue-leaf" main
mkdir -p "$LEAF_ROOT/trees/issue-leaf/config"
rm -f "$LEAF_ROOT/trees/issue-leaf/config/local.txt"
ln -s "$LEAF_ROOT/main/config/local.txt" "$LEAF_ROOT/trees/issue-leaf/config/local.txt"
printf 'WORKTREE_COPIES="config/local.txt"\n' >"$LEAF_ROOT/main/.env"
set +e
(cd "$LEAF_ROOT/main" && "$WORKTREE_SCRIPT" fix-links "$LEAF_ROOT/trees/issue-leaf") >"$LEAF_ROOT/leaf.out" 2>"$LEAF_ROOT/leaf.err"
leaf_rc=$?
set -e
assert_eq "$leaf_rc" "1" "copy setup rejects an existing leaf symlink"
assert_contains "$(cat "$LEAF_ROOT/leaf.err")" "is a symlink" "leaf-symlink diagnostic names the symlink"
assert_eq "$(cat "$LEAF_ROOT/main/config/local.txt")" "main-config" "leaf-symlink copy does not rewrite main checkout file"

GLOB_ROOT="$TMP_ROOT/glob"
make_repo "$GLOB_ROOT"
mkdir -p "$GLOB_ROOT/main/tmp/expanded"
git -C "$GLOB_ROOT/main" worktree add -q -b issue-glob "$GLOB_ROOT/trees/issue-glob" main
printf 'WORKTREE_MKDIRS="tmp/*"\n' >"$GLOB_ROOT/main/.env"
set +e
(cd "$GLOB_ROOT/main" && "$WORKTREE_SCRIPT" fix-links "$GLOB_ROOT/trees/issue-glob") >"$GLOB_ROOT/glob.out" 2>"$GLOB_ROOT/glob.err"
glob_rc=$?
set -e
assert_eq "$glob_rc" "1" "setup rejects glob metacharacters before pathname expansion"
assert_contains "$(cat "$GLOB_ROOT/glob.err")" "glob metacharacter" "glob diagnostic names metacharacter rejection"
assert_path_absent "$GLOB_ROOT/trees/issue-glob/tmp/expanded" "glob config does not expand caller-cwd matches into worktree paths"

FILE_LINK_ROOT="$TMP_ROOT/file-link"
make_repo "$FILE_LINK_ROOT"
printf 'main-tool\n' >"$FILE_LINK_ROOT/main/tool"
git -C "$FILE_LINK_ROOT/main" add tool
git -C "$FILE_LINK_ROOT/main" commit -q -m tool
git -C "$FILE_LINK_ROOT/main" worktree add -q -b issue-file-link "$FILE_LINK_ROOT/trees/issue-file-link" main
mkdir -p "$FILE_LINK_ROOT/outside-dir"
rm -f "$FILE_LINK_ROOT/trees/issue-file-link/tool"
ln -s "$FILE_LINK_ROOT/outside-dir" "$FILE_LINK_ROOT/trees/issue-file-link/tool"
printf 'WORKTREE_SYMLINKS="tool"\n' >"$FILE_LINK_ROOT/main/.env"
set +e
(cd "$FILE_LINK_ROOT/main" && "$WORKTREE_SCRIPT" fix-links "$FILE_LINK_ROOT/trees/issue-file-link") >"$FILE_LINK_ROOT/file-link.out" 2>"$FILE_LINK_ROOT/file-link.err"
file_link_rc=$?
set -e
assert_eq "$file_link_rc" "0" "file symlink setup replaces a symlink-to-directory leaf"
assert_eq "$(readlink "$FILE_LINK_ROOT/trees/issue-file-link/tool")" "$FILE_LINK_ROOT/main/tool" "file symlink points at main checkout file"
assert_path_absent "$FILE_LINK_ROOT/outside-dir/tool" "file symlink setup does not dereference old symlink-to-directory leaf"

FILE_DIR_ROOT="$TMP_ROOT/file-dir"
make_repo "$FILE_DIR_ROOT"
printf 'main-tool\n' >"$FILE_DIR_ROOT/main/tool"
git -C "$FILE_DIR_ROOT/main" add tool
git -C "$FILE_DIR_ROOT/main" commit -q -m tool
git -C "$FILE_DIR_ROOT/main" worktree add -q -b issue-file-dir "$FILE_DIR_ROOT/trees/issue-file-dir" main
rm -f "$FILE_DIR_ROOT/trees/issue-file-dir/tool"
mkdir -p "$FILE_DIR_ROOT/trees/issue-file-dir/tool"
printf 'keep\n' >"$FILE_DIR_ROOT/trees/issue-file-dir/tool/preserved.txt"
printf 'WORKTREE_SYMLINKS="tool"\n' >"$FILE_DIR_ROOT/main/.env"
file_dir_index_before="$(git -C "$FILE_DIR_ROOT/trees/issue-file-dir" ls-files -v tool)"
file_dir_common="$(git -C "$FILE_DIR_ROOT/trees/issue-file-dir" rev-parse --git-common-dir)"
set +e
(cd "$FILE_DIR_ROOT/main" && "$WORKTREE_SCRIPT" fix-links "$FILE_DIR_ROOT/trees/issue-file-dir") >"$FILE_DIR_ROOT/file-dir.out" 2>"$FILE_DIR_ROOT/file-dir.err"
file_dir_rc=$?
set -e
assert_eq "$file_dir_rc" "1" "file symlink setup refuses to delete an existing directory leaf"
assert_contains "$(cat "$FILE_DIR_ROOT/file-dir.err")" "refusing to replace non-file" "directory-leaf diagnostic names the refusal"
assert_eq "$(cat "$FILE_DIR_ROOT/trees/issue-file-dir/tool/preserved.txt")" "keep" "file symlink setup preserves an existing directory leaf"
assert_eq "$(git -C "$FILE_DIR_ROOT/trees/issue-file-dir" ls-files -v tool)" "$file_dir_index_before" "rejected file symlink leaves index flags unchanged"
assert_file_lacks_line "$file_dir_common/info/exclude" "tool" "rejected file symlink leaves shared excludes unchanged"

REL_DIR_ROOT="$TMP_ROOT/relative-dir"
make_repo "$REL_DIR_ROOT"
git -C "$REL_DIR_ROOT/main" worktree add -q -b issue-relative-dir "$REL_DIR_ROOT/trees/issue-relative-dir" main
mkdir -p "$REL_DIR_ROOT/trees/issue-relative-dir/local-link"
printf 'keep-relative\n' >"$REL_DIR_ROOT/trees/issue-relative-dir/local-link/preserved.txt"
printf 'WORKTREE_RELATIVE_SYMLINKS="local-link=../target"\n' >"$REL_DIR_ROOT/main/.env"
set +e
(cd "$REL_DIR_ROOT/main" && "$WORKTREE_SCRIPT" fix-links "$REL_DIR_ROOT/trees/issue-relative-dir") >"$REL_DIR_ROOT/relative-dir.out" 2>"$REL_DIR_ROOT/relative-dir.err"
relative_dir_rc=$?
set -e
assert_eq "$relative_dir_rc" "1" "relative symlink setup refuses to delete an existing directory leaf"
assert_contains "$(cat "$REL_DIR_ROOT/relative-dir.err")" "refusing to replace non-file" "relative directory-leaf diagnostic names the refusal"
assert_eq "$(cat "$REL_DIR_ROOT/trees/issue-relative-dir/local-link/preserved.txt")" "keep-relative" "relative symlink setup preserves an existing directory leaf"

echo "=== direct path commands refuse foreign worktrees and main checkout ==="

DIRECT_ROOT="$TMP_ROOT/direct"
make_repo "$DIRECT_ROOT"
make_repo "$DIRECT_ROOT/other"
git -C "$DIRECT_ROOT/other/main" worktree add -q -b issue-foreign "$DIRECT_ROOT/foreign/issue-foreign" main

set +e
(cd "$DIRECT_ROOT/main" && "$WORKTREE_SCRIPT" fix-links "$DIRECT_ROOT/foreign/issue-foreign") >"$DIRECT_ROOT/fix-foreign.out" 2>"$DIRECT_ROOT/fix-foreign.err"
fix_foreign_rc=$?
set -e
assert_eq "$fix_foreign_rc" "1" "fix-links refuses another repository's worktree"
assert_contains "$(cat "$DIRECT_ROOT/fix-foreign.err")" "not a registered worktree" "fix-links foreign diagnostic names registration boundary"

set +e
(cd "$DIRECT_ROOT/main" && "$WORKTREE_SCRIPT" codex-setup "$DIRECT_ROOT/foreign/issue-foreign") >"$DIRECT_ROOT/setup-foreign.out" 2>"$DIRECT_ROOT/setup-foreign.err"
setup_foreign_rc=$?
set -e
assert_eq "$setup_foreign_rc" "1" "codex-setup refuses another repository's worktree"
assert_contains "$(cat "$DIRECT_ROOT/setup-foreign.err")" "not a registered worktree" "codex-setup foreign diagnostic names registration boundary"

foreign_branch_before="$(git -C "$DIRECT_ROOT/foreign/issue-foreign" branch --show-current)"
set +e
(cd "$DIRECT_ROOT/main" && "$WORKTREE_SCRIPT" codex-branch ISSUE-FOREIGN "$DIRECT_ROOT/foreign/issue-foreign") >"$DIRECT_ROOT/branch-foreign.out" 2>"$DIRECT_ROOT/branch-foreign.err"
branch_foreign_rc=$?
set -e
assert_eq "$branch_foreign_rc" "1" "codex-branch refuses another repository's worktree"
assert_eq "$(git -C "$DIRECT_ROOT/foreign/issue-foreign" branch --show-current)" "$foreign_branch_before" "codex-branch leaves foreign branch unchanged"

set +e
(cd "$DIRECT_ROOT/main" && "$WORKTREE_SCRIPT" push "$DIRECT_ROOT/foreign/issue-foreign" --no-rebase) >"$DIRECT_ROOT/push-foreign.out" 2>"$DIRECT_ROOT/push-foreign.err"
push_foreign_rc=$?
set -e
assert_eq "$push_foreign_rc" "1" "push refuses another repository's worktree"
assert_contains "$(cat "$DIRECT_ROOT/push-foreign.err")" "not a registered worktree" "push foreign diagnostic names registration boundary"

set +e
(cd "$DIRECT_ROOT/main" && "$WORKTREE_SCRIPT" remove "$DIRECT_ROOT/main") >"$DIRECT_ROOT/remove-main.out" 2>"$DIRECT_ROOT/remove-main.err"
remove_main_rc=$?
set -e
assert_eq "$remove_main_rc" "1" "remove refuses the main checkout by direct path"
assert_contains "$(cat "$DIRECT_ROOT/remove-main.err")" "main checkout" "remove-main diagnostic names main checkout"
assert_path_exists "$DIRECT_ROOT/main/.git" "remove-main leaves main checkout intact"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
