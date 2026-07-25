#!/usr/bin/env bash
# A WORKTREE_SYMLINKS directory entry that contains tracked files marks them
# assume-unchanged, which makes git refuse to write them in that worktree while
# `git status` still reports clean. That silently breaks cherry-pick/checkout/
# merge for those paths. The setup must say so, naming the shadowed files.
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

assert_lacks() {
  local haystack="$1" needle="$2" name="$3"
  if grep -qF -- "$needle" <<<"$haystack"; then
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        unexpected substring: %s\n' "$name" "$needle"
  else
    PASS=$((PASS + 1)); printf '  ok    %s\n' "$name"
  fi
}

# No open PRs in this file; ownership signals are local/remote refs only.
mkdir -p "$TMP_ROOT/bin"
cat >"$TMP_ROOT/bin/gh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$TMP_ROOT/bin/gh"
export PATH="$TMP_ROOT/bin:$PATH"

make_repo() {
  local root="$1"
  mkdir -p "$root/main"
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
}

push_main() {
  git -C "$1/main" push -q origin main
}

echo "=== a symlinked dir containing tracked files warns and names them ==="

SHADOW_ROOT="$TMP_ROOT/shadow"
make_repo "$SHADOW_ROOT"
# harness/ mixes runtime (ignored) content with a tracked prompt file, exactly
# like a project that commits .pi/prompts while treating the rest as runtime.
mkdir -p "$SHADOW_ROOT/main/harness/prompts"
printf 'harness/**\n!harness/prompts/\n!harness/prompts/*.md\n' >"$SHADOW_ROOT/main/.gitignore"
printf 'runtime\n' >"$SHADOW_ROOT/main/harness/state.json"
printf 'tracked prompt\n' >"$SHADOW_ROOT/main/harness/prompts/deploy.md"
printf 'WORKTREE_SYMLINKS="harness"\n' >"$SHADOW_ROOT/main/.env"
git -C "$SHADOW_ROOT/main" add .gitignore harness/prompts/deploy.md
git -C "$SHADOW_ROOT/main" commit -q -m harness
push_main "$SHADOW_ROOT"

set +e
(cd "$SHADOW_ROOT/main" && "$WORKTREE_SCRIPT" create shadow-check) \
  >"$SHADOW_ROOT/out" 2>"$SHADOW_ROOT/err"
set -e
shadow_err="$(cat "$SHADOW_ROOT/err")"

assert_contains "$shadow_err" "shadows" "warns that the entry shadows tracked files"
assert_contains "$shadow_err" "harness/prompts/deploy.md" "names the shadowed tracked file"
assert_contains "$shadow_err" "narrow the entry" "suggests narrowing the symlink entry"

echo "=== a symlinked dir with no tracked files stays quiet ==="

CLEAN_ROOT="$TMP_ROOT/clean"
make_repo "$CLEAN_ROOT"
mkdir -p "$CLEAN_ROOT/main/runtime"
printf 'runtime/\n' >"$CLEAN_ROOT/main/.gitignore"
printf 'state\n' >"$CLEAN_ROOT/main/runtime/state.json"
printf 'WORKTREE_SYMLINKS="runtime"\n' >"$CLEAN_ROOT/main/.env"
git -C "$CLEAN_ROOT/main" add .gitignore
git -C "$CLEAN_ROOT/main" commit -q -m runtime
push_main "$CLEAN_ROOT"

set +e
(cd "$CLEAN_ROOT/main" && "$WORKTREE_SCRIPT" create clean-check) \
  >"$CLEAN_ROOT/out" 2>"$CLEAN_ROOT/err"
set -e

assert_lacks "$(cat "$CLEAN_ROOT/err")" "shadows" "no warning when the symlinked dir tracks nothing"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
