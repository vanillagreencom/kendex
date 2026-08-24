#!/usr/bin/env bash
# Help is inert: every --help form is answered before repository resolution
# and before any project env file is sourced, so a .env statement can never
# run under --help and help works outside a git repository. check takes no
# target: it inspects only the main checkout, and an argument is a usage
# error rather than a silently ignored one.
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
    printf '  FAIL  %s\n        wanted substring: %s\n' "$name" "$needle"
  fi
}

echo "=== worktree help dispatch runs before repository and env initialization ==="

# A repo whose .env records that it was sourced. Any help invocation that
# loads project config trips the marker.
REPO="$TMP_ROOT/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
printf 'touch "%s/env-executed"\n' "$TMP_ROOT" >"$REPO/.env"

for form in "--help" "-h" "help"; do
  out=$(cd "$REPO" && "$WORKTREE_SCRIPT" "$form")
  assert_eq "$?" 0 "worktree $form exits 0"
  assert_contains "$out" "Usage: worktree <command>" "worktree $form prints the command index"
done

for cmd in restack create remove cleanup check push fix-links repair-links \
  codex-setup codex-branch codex-cleanup claude-setup claude-cleanup; do
  out=$(cd "$REPO" && "$WORKTREE_SCRIPT" "$cmd" --help)
  assert_eq "$?" 0 "worktree $cmd --help exits 0"
  [[ -n "$out" ]] || { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "worktree $cmd --help prints something"; }
done

out=$(cd "$REPO" && "$WORKTREE_SCRIPT" claude-setup --help)
assert_contains "$out" "App-created worktree hooks" "hook commands share the app-hook help"

# Help at ANY argv position, not only right after the command: enumerating
# positions is how this class leaks.
out=$(cd "$REPO" && "$WORKTREE_SCRIPT" remove CC-1 --help)
assert_eq "$?" 0 "worktree remove CC-1 --help exits 0"
assert_contains "$out" "Usage: worktree remove" "late --help prints the remove help"
out=$(cd "$REPO" && "$WORKTREE_SCRIPT" cleanup --stale --help)
assert_eq "$?" 0 "worktree cleanup --stale --help exits 0"
assert_contains "$out" "Usage: worktree cleanup" "late --help prints the cleanup help"
out=$(cd "$REPO" && "$WORKTREE_SCRIPT" push some-id -h)
assert_eq "$?" 0 "worktree push some-id -h exits 0"
assert_contains "$out" "Usage: worktree push" "late -h prints the push help"

if [[ -e "$TMP_ROOT/env-executed" ]]; then
  FAIL=$((FAIL + 1))
  printf '  FAIL  %s\n' "help sourced the project .env"
else
  PASS=$((PASS + 1))
  printf '  ok    %s\n' "no help form sourced the project .env"
fi

# Help needs no repository at all.
NOREPO="$TMP_ROOT/norepo"
mkdir -p "$NOREPO"
out=$(cd "$NOREPO" && "$WORKTREE_SCRIPT" --help)
assert_eq "$?" 0 "worktree --help exits 0 outside a git repository"

# The top-level help states the loader's real precedence, lowest to highest.
assert_contains "$out" ".env, then kendex.settings.toml" "help orders .env below the settings files"
assert_contains "$out" ".kendex/settings.toml" "help names the .kendex settings file"
assert_contains "$out" "parent environment beats every project file" "help states parent env outranks project files"

echo
echo "=== check takes no target ==="

out=$(cd "$REPO" && "$WORKTREE_SCRIPT" check --help)
assert_contains "$out" "MAIN checkout" "check --help says it inspects the main checkout"

set +e
err=$(cd "$REPO" && "$WORKTREE_SCRIPT" check some-id 2>&1)
code=$?
set -e
assert_eq "$code" 1 "check with an argument exits 1"
assert_contains "$err" "check takes no arguments" "check names the rejection"

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
