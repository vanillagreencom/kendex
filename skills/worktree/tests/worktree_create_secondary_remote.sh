#!/usr/bin/env bash
# Regression coverage for secondary-remote ownership discovery (vstack#575):
# an unreachable non-origin remote must not brick new-work claims, a reachable
# secondary remote must still count as ownership, and origin stays required.
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

ROOT="$TMP_ROOT/multi-remote"
mkdir -p "$ROOT/main" "$ROOT/bin"
git -C "$ROOT/main" init -q -b main
git -C "$ROOT/main" config user.email test@example.com
git -C "$ROOT/main" config user.name Test
git -C "$ROOT/main" config commit.gpgsign false
printf 'base\n' >"$ROOT/main/base.txt"
git -C "$ROOT/main" add base.txt
git -C "$ROOT/main" commit -q -m base
# Pin the historical sibling trees/ base so this file's path assertions stay
# explicit; default base-dir resolution is covered by worktree_base_dir.sh.
printf 'WORKTREE_BASE_DIR="../trees"\n' >"$ROOT/main/.env"
git init -q --bare "$ROOT/origin.git"
git -C "$ROOT/main" remote add origin "$ROOT/origin.git"
git -C "$ROOT/main" push -q -u origin main

# No open PRs for any branch; ownership signals in this test come from remotes.
cat >"$ROOT/bin/gh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$ROOT/bin/gh"
export PATH="$ROOT/bin:$PATH"

echo "=== worktree create secondary-remote ownership discovery ==="

# An unreachable non-origin remote cannot receive other sessions' pushes, so
# discovery skips it with a warning instead of refusing every new-work claim.
git -C "$ROOT/main" remote add flaky "$ROOT/does-not-exist.git"
set +e
create_out="$(cd "$ROOT/main" && "$WORKTREE_SCRIPT" create issue-second 2>"$ROOT/create.err")"
create_code=$?
set -e
create_err="$(cat "$ROOT/create.err")"
assert_eq "$create_code" "0" "create succeeds despite an unreachable secondary remote"
assert_contains "$create_err" "warning: skipping unreachable remote 'flaky' for ownership discovery" "unreachable secondary remote is reported as skipped"
assert_eq "$create_out" "$ROOT/trees/issue-second" "create prints the new worktree path"
assert_path_exists "$ROOT/trees/issue-second/.git" "new worktree is registered"

# A reachable secondary remote is still an authoritative ownership signal.
git init -q --bare "$ROOT/second.git"
git -C "$ROOT/main" remote add second "$ROOT/second.git"
git -C "$ROOT/main" branch issue-owned main
git -C "$ROOT/main" push -q second issue-owned
git -C "$ROOT/main" branch -D issue-owned >/dev/null
set +e
(cd "$ROOT/main" && "$WORKTREE_SCRIPT" create issue-owned >"$ROOT/owned.out" 2>"$ROOT/owned.err")
owned_code=$?
set -e
owned_err="$(cat "$ROOT/owned.err")"
assert_eq "$owned_code" "75" "create exits 75 for a branch owned on a reachable secondary remote"
assert_contains "$owned_err" "existing remote branch (second/issue-owned)" "secondary-remote ownership names the remote ref"
assert_path_absent "$ROOT/trees/issue-owned" "secondary-remote ownership creates no worktree"
assert_branch_absent "$ROOT/main" "issue-owned" "secondary-remote ownership creates no local branch"

# Origin stays required and fail-closed: an unreachable origin is a hard error
# even while unreachable secondaries are merely skipped.
git -C "$ROOT/main" remote set-url origin "$ROOT/missing-origin.git"
set +e
(cd "$ROOT/main" && "$WORKTREE_SCRIPT" create issue-origin-down >"$ROOT/origin-down.out" 2>"$ROOT/origin-down.err")
origin_down_code=$?
set -e
origin_down_err="$(cat "$ROOT/origin-down.err")"
assert_eq "$origin_down_code" "1" "create exits 1 when origin is unreachable"
assert_contains "$origin_down_err" "Could not query remote 'origin'" "origin discovery failure is explicit"
assert_path_absent "$ROOT/trees/issue-origin-down" "origin failure creates no worktree"
assert_branch_absent "$ROOT/main" "issue-origin-down" "origin failure creates no local branch"

# A repository without an origin remote at all is also a hard error.
git -C "$ROOT/main" remote remove origin
set +e
(cd "$ROOT/main" && "$WORKTREE_SCRIPT" create issue-no-origin >"$ROOT/no-origin.out" 2>"$ROOT/no-origin.err")
no_origin_code=$?
set -e
assert_eq "$no_origin_code" "1" "create exits 1 when no origin remote is configured"
assert_contains "$(cat "$ROOT/no-origin.err")" "Remote 'origin' is required" "missing origin is explicit"
assert_path_absent "$ROOT/trees/issue-no-origin" "missing origin creates no worktree"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
