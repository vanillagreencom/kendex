#!/usr/bin/env bash
# Regression coverage for active-work ownership guards (vstack#571).
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

assert_ne() {
  local got="$1" unwanted="$2" name="$3"
  if [[ "$got" != "$unwanted" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected value to differ from: %s\n' "$name" "$unwanted"
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

make_repo() {
  local root="$1"
  mkdir -p "$root/main" "$root/bin" "$root/gh-state"
  git -C "$root/main" init -q -b main
  git -C "$root/main" config user.email test@example.com
  git -C "$root/main" config user.name Test
  git -C "$root/main" config commit.gpgsign false
  printf 'base\n' >"$root/main/base.txt"
  git -C "$root/main" add base.txt
  git -C "$root/main" commit -q -m base
  git init -q --bare "$root/origin.git"
  git -C "$root/main" remote add origin "$root/origin.git"
  git -C "$root/main" push -q -u origin main

  cat >"$root/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}:${2:-}" in
  pr:list)
    if [[ -f "${GH_STATE:?}/open-pr" ]]; then
      printf '42\thttps://example.test/pull/42\n'
    fi
    ;;
  pr:view)
    printf 'issue-active\n'
    ;;
esac
STUB
  chmod +x "$root/bin/gh"
}

ROOT="$TMP_ROOT/active"
make_repo "$ROOT"
export PATH="$ROOT/bin:$PATH"
export GH_STATE="$ROOT/gh-state"

echo "=== worktree create active-work guard ==="

# Create and publish a normal issue branch, then advance main so the historical
# implicit-reuse path would have rebased and rewritten its HEAD.
(cd "$ROOT/main" && "$WORKTREE_SCRIPT" create issue-active >/dev/null)
WT="$ROOT/trees/issue-active"
printf 'feature\n' >"$WT/feature.txt"
git -C "$WT" add feature.txt
git -C "$WT" commit -q -m feature
git -C "$WT" push -q -u origin issue-active

printf 'main advance\n' >"$ROOT/main/main-advance.txt"
git -C "$ROOT/main" add main-advance.txt
git -C "$ROOT/main" commit -q -m 'advance main'
git -C "$ROOT/main" push -q origin main

touch "$GH_STATE/open-pr"
git -C "$ROOT/main" worktree lock --reason 'owner session is active' "$WT"
pre_head="$(git -C "$WT" rev-parse HEAD)"

set +e
(cd "$ROOT/main" && "$WORKTREE_SCRIPT" create issue-active >"$ROOT/guard.out" 2>"$ROOT/guard.err")
guard_code=$?
set -e
guard_err="$(cat "$ROOT/guard.err")"

assert_eq "$guard_code" "75" "bare create exits 75 when an issue worktree is active"
assert_contains "$guard_err" "Active work already exists" "guard clearly reports active ownership"
assert_contains "$guard_err" "Open PR: #42" "guard reports the open PR signal"
assert_contains "$guard_err" "owner session is active" "guard reports the worktree lock signal"
assert_contains "$guard_err" "--reuse" "guard names the explicit owner override"
assert_eq "$(git -C "$WT" rev-parse HEAD)" "$pre_head" "guard leaves the active branch HEAD unchanged"
assert_eq "$(git -C "$WT" status --porcelain)" "" "guard leaves the active worktree clean"
assert_path_absent "$WT/main-advance.txt" "guard does not rebase main advancement into active work"

# The confirmed owner can still opt in to the established reuse/rebase behavior.
git -C "$ROOT/main" worktree unlock "$WT"
reuse_out="$(cd "$ROOT/main" && "$WORKTREE_SCRIPT" create issue-active --reuse)"
assert_eq "$reuse_out" "$WT" "--reuse returns the existing owned worktree"
assert_ne "$(git -C "$WT" rev-parse HEAD)" "$pre_head" "--reuse intentionally rebases the owned branch"
if git -C "$WT" merge-base --is-ancestor origin/main HEAD; then
  PASS=$((PASS + 1))
  printf '  ok    --reuse contains current origin/main\n'
else
  FAIL=$((FAIL + 1))
  printf '  FAIL  --reuse does not contain current origin/main\n'
fi

# Removing the checkout does not make an open PR unowned. Bare create must
# still stop before recreating it; --pr is the explicit inspection path.
git -C "$ROOT/main" worktree remove "$WT"
git -C "$ROOT/main" branch -D issue-active >/dev/null
set +e
(cd "$ROOT/main" && "$WORKTREE_SCRIPT" create issue-active >"$ROOT/pr-guard.out" 2>"$ROOT/pr-guard.err")
pr_guard_code=$?
set -e
pr_guard_err="$(cat "$ROOT/pr-guard.err")"
assert_eq "$pr_guard_code" "75" "bare create exits 75 for an open PR without a local worktree"
assert_contains "$pr_guard_err" "open pull request (#42)" "branch guard reports the PR ownership signal"
assert_path_absent "$WT" "open-PR guard creates no duplicate checkout"

pr_out="$(cd "$ROOT/main" && "$WORKTREE_SCRIPT" create issue-active --pr 42)"
assert_eq "$pr_out" "$WT" "--pr explicitly creates an inspection worktree"
assert_path_exists "$WT/.git" "explicit PR checkout is a registered worktree"

# Dirty and unpublished local work is independently sufficient ownership.
rm -f "$GH_STATE/open-pr"
(cd "$ROOT/main" && "$WORKTREE_SCRIPT" create issue-local >/dev/null)
LOCAL_WT="$ROOT/trees/issue-local"
printf 'local commit\n' >"$LOCAL_WT/local.txt"
git -C "$LOCAL_WT" add local.txt
git -C "$LOCAL_WT" commit -q -m 'unpublished local work'
printf 'dirty\n' >"$LOCAL_WT/dirty.txt"
local_pre_head="$(git -C "$LOCAL_WT" rev-parse HEAD)"
set +e
(cd "$ROOT/main" && "$WORKTREE_SCRIPT" create issue-local >"$ROOT/local-guard.out" 2>"$ROOT/local-guard.err")
local_guard_code=$?
set -e
local_guard_err="$(cat "$ROOT/local-guard.err")"
assert_eq "$local_guard_code" "75" "bare create exits 75 for dirty unpublished local work"
assert_contains "$local_guard_err" "Working tree: dirty" "guard reports dirty state"
assert_contains "$local_guard_err" "branch is unpublished" "guard reports unpublished branch state"
assert_eq "$(git -C "$LOCAL_WT" rev-parse HEAD)" "$local_pre_head" "guard leaves unpublished branch HEAD unchanged"
assert_path_exists "$LOCAL_WT/dirty.txt" "guard preserves uncommitted work"

# A remote branch is also ownership even when GitHub lookup is unavailable or
# no PR is open.
git -C "$ROOT/main" branch issue-remote main
git -C "$ROOT/main" push -q origin issue-remote
git -C "$ROOT/main" branch -D issue-remote >/dev/null
set +e
(cd "$ROOT/main" && "$WORKTREE_SCRIPT" create issue-remote >"$ROOT/remote-guard.out" 2>"$ROOT/remote-guard.err")
remote_guard_code=$?
set -e
remote_guard_err="$(cat "$ROOT/remote-guard.err")"
assert_eq "$remote_guard_code" "75" "bare create exits 75 for an existing remote branch"
assert_contains "$remote_guard_err" "existing remote branch" "remote-branch guard reports its ownership signal"
assert_path_absent "$ROOT/trees/issue-remote" "remote-branch guard creates no duplicate checkout"

# Never delete a target directory merely because it lacks a .git pointer; it
# may be a concurrent or interrupted creator.
mkdir -p "$ROOT/trees/issue-orphan"
printf 'keep\n' >"$ROOT/trees/issue-orphan/owner-marker"
set +e
(cd "$ROOT/main" && "$WORKTREE_SCRIPT" create issue-orphan >"$ROOT/orphan.out" 2>"$ROOT/orphan.err")
orphan_code=$?
set -e
assert_eq "$orphan_code" "75" "bare create exits 75 for an incomplete target directory"
assert_path_exists "$ROOT/trees/issue-orphan/owner-marker" "guard preserves incomplete/concurrent directory contents"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
