#!/usr/bin/env bash
# `create --reuse` must be able to rebase a worktree whose WORKTREE_SYMLINKS
# entries shadow tracked files (vstack #873, #874).
#
# Since VST-37 setup provisions such an entry as a REAL directory with only the
# untracked children symlinked, so git owns the tracked paths and the rebase
# writes them directly. The reuse path must still succeed, and re-applying
# setup afterwards must keep the per-child layout intact.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKTREE_SCRIPT="${WORKTREE_SCRIPT:-$(cd "$TEST_DIR/.." && pwd)/scripts/worktree}"
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

assert_contains() {
  local haystack="$1" needle="$2" name="$3"
  if grep -qF -- "$needle" <<<"$haystack"; then
    PASS=$((PASS + 1)); printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        wanted substring: %s\n        in: %s\n' "$name" "$needle" "$haystack"
  fi
}

assert_eq() {
  local got="$1" want="$2" name="$3"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1)); printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        want: %s\n        got:  %s\n' "$name" "$want" "$got"
  fi
}

mkdir -p "$TMP_ROOT/bin"
cat >"$TMP_ROOT/bin/gh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$TMP_ROOT/bin/gh"
export PATH="$TMP_ROOT/bin:$PATH"

ROOT="$TMP_ROOT/repo"
mkdir -p "$ROOT/main"
git -C "$ROOT/main" init -q -b main
git -C "$ROOT/main" config user.email test@example.com
git -C "$ROOT/main" config user.name Test
git -C "$ROOT/main" config commit.gpgsign false
printf 'base\n' >"$ROOT/main/base.txt"
git -C "$ROOT/main" add base.txt
git -C "$ROOT/main" commit -q -m base
git init -q --bare "$ROOT/origin.git"
git -C "$ROOT/main" remote add origin "$ROOT/origin.git"
git -C "$ROOT/main" push -q -u origin main

# A harness dir that mixes runtime content with a TRACKED file — the shape that
# CC-1144's `.agents` relocation produced in hyprtrade.
mkdir -p "$ROOT/main/harness/skills"
printf 'harness/**\n!harness/skills/\n!harness/skills/*.md\n' >"$ROOT/main/.gitignore"
printf 'runtime\n' >"$ROOT/main/harness/state.json"
printf 'v1\n' >"$ROOT/main/harness/skills/tool.md"
printf 'WORKTREE_SYMLINKS="harness"\n' >"$ROOT/main/.env"
git -C "$ROOT/main" add .gitignore harness/skills/tool.md
git -C "$ROOT/main" commit -q -m harness
git -C "$ROOT/main" push -q origin main

echo "=== reuse rebases across a symlink entry that shadows tracked files ==="

WT="$( (cd "$ROOT/main" && "$WORKTREE_SCRIPT" create reuse-check) 2>/dev/null )"
[[ -n "$WT" && -d "$WT" ]] || { echo "FATAL: worktree not created"; exit 1; }

# Branch work that does NOT touch the shadowed path.
printf 'branch work\n' >"$WT/feature.txt"
git -C "$WT" add feature.txt
git -C "$WT" commit -q -m 'feature work'

# Main moves forward AND changes the tracked file hidden behind the symlink.
# This is what forces git to write through the shadowed path during rebase.
printf 'v2\n' >"$ROOT/main/harness/skills/tool.md"
printf 'moved on\n' >"$ROOT/main/other.txt"
# -f because `worktree create` appends a bare `harness` entry to the COMMON
# git dir's info/exclude, which makes plain `git add` refuse tracked paths
# underneath it even in the main checkout (vstack #878).
git -C "$ROOT/main" add -f harness/skills/tool.md other.txt
git -C "$ROOT/main" commit -q -m 'advance main and touch tracked harness file'
git -C "$ROOT/main" push -q origin main

# The per-child layout: tracked file real, untracked sibling linked, clean status.
assert_eq "$(git -C "$WT" status --porcelain)" "" "git status is clean before reuse"
if [[ -e "$WT/harness" && ! -L "$WT/harness" ]]; then
  PASS=$((PASS + 1)); printf '  ok    %s\n' "harness is a real directory before reuse"
else
  FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "harness is a real directory before reuse"
fi

set +e
reuse_out="$( (cd "$ROOT/main" && "$WORKTREE_SCRIPT" create reuse-check --reuse) 2>&1 )"
reuse_status=$?
set -e

assert_eq "$reuse_status" "0" "create --reuse succeeds"
assert_contains "$reuse_out" "$WT" "reuse prints the worktree path"

# The rebase actually happened: main's new commit is an ancestor of the branch.
set +e
git -C "$WT" merge-base --is-ancestor origin/main HEAD
ancestor_status=$?
set -e
assert_eq "$ancestor_status" "0" "origin/main is contained after reuse"

# The branch commit survived the rebase.
assert_contains "$(git -C "$WT" log --format=%s -3)" "feature work" "branch commit preserved"

# Setup was reapplied as the per-child layout: the entry is a real directory,
# the rebase wrote the tracked file directly, and the untracked runtime child
# is still a link into the main checkout.
if [[ -e "$WT/harness" && ! -L "$WT/harness" ]]; then
  PASS=$((PASS + 1)); printf '  ok    %s\n' "harness is a real directory after reuse"
else
  FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "harness is a real directory after reuse"
fi
if [[ -f "$WT/harness/skills/tool.md" && ! -L "$WT/harness/skills/tool.md" ]]; then
  PASS=$((PASS + 1)); printf '  ok    %s\n' "the tracked file is a real file after reuse"
else
  FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "the tracked file is a real file after reuse"
fi
assert_eq "$(cat "$WT/harness/skills/tool.md" 2>/dev/null)" "v2" "the rebase wrote the tracked file"
if [[ -L "$WT/harness/state.json" ]]; then
  PASS=$((PASS + 1)); printf '  ok    %s\n' "the untracked child is still symlinked after reuse"
else
  FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "the untracked child is still symlinked after reuse"
fi

# And the worktree is still clean — the reconciliation must not leave the
# shadowed paths reported as modified.
assert_eq "$(git -C "$WT" status --porcelain)" "" "git status is clean after reuse"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
