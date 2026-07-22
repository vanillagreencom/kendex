#!/usr/bin/env bash
# Coverage for vstack#692: external default worktree base dir
# (<parent-of-checkout>/.worktrees/<checkout-name>), absolute and ~ overrides,
# canonical (symlink-resolved) path comparisons, and compatibility with
# worktrees registered under an older base-dir convention.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKTREE_SCRIPT="${WORKTREE_SCRIPT:-$(cd "$TEST_DIR/.." && pwd)/scripts/worktree}"
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# Default resolution must come from the script, not an inherited override.
unset WORKTREE_BASE_DIR

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

assert_not_contains() {
  local haystack="$1" needle="$2" name="$3"
  if grep -qF -- "$needle" <<<"$haystack"; then
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        unwanted substring: %s\n        in: %s\n' "$name" "$needle" "$haystack"
  else
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
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

assert_branch_absent() {
  local repo="$1" branch="$2" name="$3"
  if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        unexpected branch: %s\n' "$name" "$branch"
  else
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  fi
}

assert_branch_exists() {
  local repo="$1" branch="$2" name="$3"
  if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        missing branch: %s\n' "$name" "$branch"
  fi
}

# No open PRs anywhere in this file; ownership signals are local/remote refs.
mkdir -p "$TMP_ROOT/bin"
cat >"$TMP_ROOT/bin/gh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$TMP_ROOT/bin/gh"
export PATH="$TMP_ROOT/bin:$PATH"

# make_repo ROOT [NAME]: main checkout at ROOT/NAME with a bare origin.
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
  git init -q --bare "$root/origin-$name.git"
  git -C "$root/$name" remote add origin "$root/origin-$name.git"
  git -C "$root/$name" push -q -u origin main
}

echo "=== default base dir: external .worktrees/<repo> beside the checkout ==="

DEFAULT_ROOT="$TMP_ROOT/default"
make_repo "$DEFAULT_ROOT" repo-a
make_repo "$DEFAULT_ROOT" repo-b

default_path=$(cd "$DEFAULT_ROOT/repo-a" && "$WORKTREE_SCRIPT" path ISSUE-1)
assert_eq "$default_path" "$DEFAULT_ROOT/.worktrees/repo-a/issue-1" "default resolves outside the repo to .worktrees/<repo>"

sibling_path=$(cd "$DEFAULT_ROOT/repo-b" && "$WORKTREE_SCRIPT" path ISSUE-1)
assert_eq "$sibling_path" "$DEFAULT_ROOT/.worktrees/repo-b/issue-1" "sibling repos get distinct default base dirs for the same ID"

default_create_out=$(cd "$DEFAULT_ROOT/repo-a" && "$WORKTREE_SCRIPT" create issue-default)
assert_eq "$default_create_out" "$DEFAULT_ROOT/.worktrees/repo-a/issue-default" "create lands in the default external base dir"
assert_path_exists "$DEFAULT_ROOT/.worktrees/repo-a/issue-default/.git" "default-created worktree is registered"
assert_path_absent "$DEFAULT_ROOT/repo-a/trees" "create adds nothing under the repo root"

# cleanup parses the registry under the new layout, excludes the main checkout
# by canonical comparison, and removes merged worktrees before deleting their
# checked-out branches.
set +e
(cd "$DEFAULT_ROOT/repo-a" && "$WORKTREE_SCRIPT" cleanup >"$DEFAULT_ROOT/cleanup.out" 2>"$DEFAULT_ROOT/cleanup.err")
cleanup_code=$?
set -e
assert_eq "$cleanup_code" "0" "cleanup runs cleanly under the default external layout"
assert_path_absent "$DEFAULT_ROOT/.worktrees/repo-a/issue-default" "cleanup removes a merged worktree whose branch was checked out"
assert_branch_absent "$DEFAULT_ROOT/repo-a" "issue-default" "cleanup deletes the merged worktree branch after removal"
assert_path_exists "$DEFAULT_ROOT/repo-a/base.txt" "cleanup never touches the main checkout"

invalid_cleanup_path=$(cd "$DEFAULT_ROOT/repo-a" && "$WORKTREE_SCRIPT" create issue-invalid-cleanup)
printf 'WORKTREE_SYMLINKS="../outside"\n' >"$DEFAULT_ROOT/repo-a/.env"
set +e
(cd "$DEFAULT_ROOT/repo-a" && "$WORKTREE_SCRIPT" cleanup >"$DEFAULT_ROOT/invalid-cleanup.out" 2>"$DEFAULT_ROOT/invalid-cleanup.err")
invalid_cleanup_code=$?
set -e
assert_eq "$invalid_cleanup_code" "0" "cleanup does not depend on current setup-path configuration"
assert_path_absent "$invalid_cleanup_path" "cleanup removes the intact merged worktree despite invalid setup config"
assert_branch_absent "$DEFAULT_ROOT/repo-a" "issue-invalid-cleanup" "cleanup deletes the merged branch despite invalid setup config"
rm -f "$DEFAULT_ROOT/repo-a/.env"

REMOVE_FAIL_ROOT="$TMP_ROOT/remove-failure"
make_repo "$REMOVE_FAIL_ROOT"
printf 'TEST_SHARED="shared"\n' >"$REMOVE_FAIL_ROOT/main/.env.local"
printf 'WORKTREE_SYMLINKS=".env.local"\n' >"$REMOVE_FAIL_ROOT/main/.env"
remove_fail_path=$(cd "$REMOVE_FAIL_ROOT/main" && "$WORKTREE_SCRIPT" create issue-remove-failure)
assert_eq "$(readlink "$remove_fail_path/.env.local")" "$REMOVE_FAIL_ROOT/main/.env.local" "removal-failure fixture starts with configured symlink intact"
mkdir -p "$REMOVE_FAIL_ROOT/bin"
cat >"$REMOVE_FAIL_ROOT/bin/git" <<'STUB'
#!/usr/bin/env bash
if [[ " $* " == *" worktree remove --force "* && "$*" == *"issue-remove-failure"* ]]; then
  echo "simulated worktree removal failure" >&2
  exit 1
fi
exec "$REAL_GIT_BIN" "$@"
STUB
chmod +x "$REMOVE_FAIL_ROOT/bin/git"
REAL_GIT_BIN="$(command -v git)"
set +e
(cd "$REMOVE_FAIL_ROOT/main" && PATH="$REMOVE_FAIL_ROOT/bin:$PATH" REAL_GIT_BIN="$REAL_GIT_BIN" "$WORKTREE_SCRIPT" cleanup >"$REMOVE_FAIL_ROOT/cleanup.out" 2>"$REMOVE_FAIL_ROOT/cleanup.err")
remove_fail_code=$?
set -e
assert_eq "$remove_fail_code" "1" "cleanup reports git worktree removal failure"
assert_contains "$(cat "$REMOVE_FAIL_ROOT/cleanup.err")" "preserving it for manual recovery" "cleanup explains that failed removal was preserved"
assert_path_exists "$remove_fail_path/.git" "cleanup preserves a worktree that Git refused to remove"
assert_eq "$(readlink "$remove_fail_path/.env.local")" "$REMOVE_FAIL_ROOT/main/.env.local" "cleanup failure preserves configured worktree symlinks"
assert_branch_exists "$REMOVE_FAIL_ROOT/main" "issue-remove-failure" "cleanup preserves the branch when worktree removal fails"
(cd "$REMOVE_FAIL_ROOT/main" && "$WORKTREE_SCRIPT" remove issue-remove-failure >/dev/null)

echo "=== explicit absolute and ~ overrides ==="

abs_path=$(cd "$DEFAULT_ROOT/repo-a" && WORKTREE_BASE_DIR="$DEFAULT_ROOT/abs-base" "$WORKTREE_SCRIPT" path ISSUE-2)
assert_eq "$abs_path" "$DEFAULT_ROOT/abs-base/issue-2" "absolute WORKTREE_BASE_DIR is honored"

mkdir -p "$DEFAULT_ROOT/home"
tilde_path=$(cd "$DEFAULT_ROOT/repo-a" && HOME="$DEFAULT_ROOT/home" WORKTREE_BASE_DIR='~/wt' "$WORKTREE_SCRIPT" path ISSUE-2)
assert_eq "$tilde_path" "$DEFAULT_ROOT/home/wt/issue-2" "~ WORKTREE_BASE_DIR expands against HOME"

echo "=== canonical comparison through a symlinked base dir ==="

SYM_ROOT="$TMP_ROOT/symlinked"
make_repo "$SYM_ROOT"
mkdir -p "$SYM_ROOT/real-trees"
# Compatibility shape: an in-repo `trees` symlink pointing at an external dir.
ln -s "$SYM_ROOT/real-trees" "$SYM_ROOT/main/trees"
printf 'WORKTREE_BASE_DIR="trees"\n' >"$SYM_ROOT/main/.env"

sym_create_out=$(cd "$SYM_ROOT/main" && "$WORKTREE_SCRIPT" create issue-sym)
assert_eq "$sym_create_out" "$SYM_ROOT/main/trees/issue-sym" "create reports the configured (symlinked) path"
assert_path_exists "$SYM_ROOT/real-trees/issue-sym/.git" "worktree physically lands behind the symlink"

# The same tree addressed through the symlinked spelling is active work, not a
# foreign/incomplete target.
set +e
(cd "$SYM_ROOT/main" && "$WORKTREE_SCRIPT" create issue-sym >"$SYM_ROOT/again.out" 2>"$SYM_ROOT/again.err")
sym_again_code=$?
set -e
sym_again_err="$(cat "$SYM_ROOT/again.err")"
assert_eq "$sym_again_code" "75" "bare create through the symlink exits 75 for the owned tree"
assert_contains "$sym_again_err" "Active work already exists" "symlinked spelling is recognized as the same tree"
assert_not_contains "$sym_again_err" "not a registered worktree" "same tree is never treated as foreign"

# Repoint the config at the physical dir: the tree registered under the
# symlinked spelling must still be recognized and reusable in place.
printf 'WORKTREE_BASE_DIR="%s"\n' "$SYM_ROOT/real-trees" >"$SYM_ROOT/main/.env"
sym_reuse_out=$(cd "$SYM_ROOT/main" && "$WORKTREE_SCRIPT" create issue-sym --reuse)
assert_eq "$sym_reuse_out" "$SYM_ROOT/real-trees/issue-sym" "--reuse recognizes the tree via its physical path"

sym_remove_out=$(cd "$SYM_ROOT/main" && "$WORKTREE_SCRIPT" remove issue-sym)
assert_eq "$sym_remove_out" "Removed: $SYM_ROOT/real-trees/issue-sym" "remove works via the physical path"
assert_path_absent "$SYM_ROOT/real-trees/issue-sym" "removed worktree is gone from the physical dir"
assert_branch_absent "$SYM_ROOT/main" "issue-sym" "removed merged branch is deleted"

echo "=== foreign worktree behind the configured path is still refused ==="

FOREIGN_ROOT="$TMP_ROOT/foreign"
make_repo "$FOREIGN_ROOT"
make_repo "$FOREIGN_ROOT/other"
git -C "$FOREIGN_ROOT/other/main" worktree add -q -b issue-foreign "$FOREIGN_ROOT/shared-trees/issue-foreign" main
printf 'keep\n' >"$FOREIGN_ROOT/shared-trees/issue-foreign/marker"
printf 'secret\n' >"$FOREIGN_ROOT/shared-trees/issue-foreign/.env.local"
printf 'WORKTREE_BASE_DIR="../shared-trees"\nWORKTREE_SYMLINKS=".env.local"\n' >"$FOREIGN_ROOT/main/.env"

set +e
(cd "$FOREIGN_ROOT/main" && "$WORKTREE_SCRIPT" create issue-foreign --reuse >"$FOREIGN_ROOT/reuse.out" 2>"$FOREIGN_ROOT/reuse.err")
foreign_reuse_code=$?
set -e
assert_eq "$foreign_reuse_code" "75" "--reuse exits 75 for another repository's worktree"
assert_contains "$(cat "$FOREIGN_ROOT/reuse.err")" "not a registered worktree" "foreign tree is reported as unregistered, not reused"

set +e
(cd "$FOREIGN_ROOT/main" && "$WORKTREE_SCRIPT" remove issue-foreign >"$FOREIGN_ROOT/remove.out" 2>"$FOREIGN_ROOT/remove.err")
foreign_remove_code=$?
set -e
assert_eq "$foreign_remove_code" "1" "remove refuses another repository's worktree"
assert_contains "$(cat "$FOREIGN_ROOT/remove.err")" "refusing to remove" "remove names the refusal"
assert_path_exists "$FOREIGN_ROOT/shared-trees/issue-foreign/.git" "foreign worktree registration is untouched"
assert_path_exists "$FOREIGN_ROOT/shared-trees/issue-foreign/marker" "foreign worktree contents are untouched"
assert_path_exists "$FOREIGN_ROOT/shared-trees/issue-foreign/.env.local" "foreign worktree keeps files matching configured symlink paths"

echo "=== worktrees registered under an older base-dir convention keep working ==="

LEGACY_ROOT="$TMP_ROOT/legacy"
make_repo "$LEGACY_ROOT"
# Legacy convention: sibling trees/ dir, registered directly with git.
git -C "$LEGACY_ROOT/main" worktree add -q -b issue-legacy "$LEGACY_ROOT/trees/issue-legacy" main
git -C "$LEGACY_ROOT/main" worktree add -q -b issue-legacy-rm "$LEGACY_ROOT/trees/issue-legacy-rm" main

legacy_path=$(cd "$LEGACY_ROOT/main" && "$WORKTREE_SCRIPT" path issue-legacy)
assert_eq "$legacy_path" "$LEGACY_ROOT/trees/issue-legacy" "path falls back to the registered legacy worktree"

legacy_exists=$(cd "$LEGACY_ROOT/main" && "$WORKTREE_SCRIPT" exists issue-legacy)
assert_eq "$legacy_exists" "true" "exists sees the registered legacy worktree"

set +e
(cd "$LEGACY_ROOT/main" && "$WORKTREE_SCRIPT" create issue-legacy >"$LEGACY_ROOT/create.out" 2>"$LEGACY_ROOT/create.err")
legacy_create_code=$?
set -e
assert_eq "$legacy_create_code" "75" "bare create still refuses the active legacy worktree"
assert_contains "$(cat "$LEGACY_ROOT/create.err")" "$LEGACY_ROOT/trees/issue-legacy" "refusal names the legacy location"

legacy_reuse_out=$(cd "$LEGACY_ROOT/main" && "$WORKTREE_SCRIPT" create issue-legacy --reuse)
assert_eq "$legacy_reuse_out" "$LEGACY_ROOT/trees/issue-legacy" "--reuse resolves to the legacy worktree unmoved"

set +e
legacy_restack_err="$(cd "$LEGACY_ROOT/main" && "$WORKTREE_SCRIPT" restack abort issue-legacy 2>&1)"
legacy_restack_code=$?
set -e
assert_eq "$legacy_restack_code" "1" "restack control on a legacy tree fails only on missing paused state"
assert_contains "$legacy_restack_err" "$LEGACY_ROOT/trees/issue-legacy" "restack resolves the ID to the legacy worktree"
assert_contains "$legacy_restack_err" "missing a paused rebase" "restack refusal is the paused-state check, not resolution"

printf 'legacy work\n' >"$LEGACY_ROOT/trees/issue-legacy/work.txt"
git -C "$LEGACY_ROOT/trees/issue-legacy" add work.txt
git -C "$LEGACY_ROOT/trees/issue-legacy" commit -q -m 'legacy work'
set +e
(cd "$LEGACY_ROOT/main" && "$WORKTREE_SCRIPT" push issue-legacy --no-rebase >"$LEGACY_ROOT/push.out" 2>"$LEGACY_ROOT/push.err")
legacy_push_code=$?
set -e
assert_eq "$legacy_push_code" "0" "push resolves the ID to the legacy worktree"
if git -C "$LEGACY_ROOT/main" ls-remote --exit-code --heads origin issue-legacy >/dev/null 2>&1; then
  PASS=$((PASS + 1))
  printf '  ok    push publishes the legacy worktree branch\n'
else
  FAIL=$((FAIL + 1))
  printf '  FAIL  push publishes the legacy worktree branch\n'
fi

fresh_create_out=$(cd "$LEGACY_ROOT/main" && "$WORKTREE_SCRIPT" create issue-fresh)
assert_eq "$fresh_create_out" "$LEGACY_ROOT/.worktrees/main/issue-fresh" "new IDs land in the new default while legacy trees drain"
assert_path_exists "$LEGACY_ROOT/trees/issue-legacy/.git" "legacy worktree stays unmoved (no auto-migration)"

legacy_remove_out=$(cd "$LEGACY_ROOT/main" && "$WORKTREE_SCRIPT" remove issue-legacy-rm)
assert_eq "$legacy_remove_out" "Removed: $LEGACY_ROOT/trees/issue-legacy-rm" "remove resolves the ID to the legacy worktree"
assert_path_absent "$LEGACY_ROOT/trees/issue-legacy-rm" "legacy worktree is removed"
assert_branch_absent "$LEGACY_ROOT/main" "issue-legacy-rm" "legacy merged branch is deleted"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
