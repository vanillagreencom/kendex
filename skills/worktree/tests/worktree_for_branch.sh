#!/usr/bin/env bash
# Regression coverage for worktree_for_branch (vstack#575): success must
# always carry a non-empty worktree path, so command-substitution callers can
# treat empty output as "no worktree" without also getting exit 0.
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

ROOT="$TMP_ROOT/porcelain"
mkdir -p "$ROOT/main"
git -C "$ROOT/main" init -q -b main
git -C "$ROOT/main" config user.email test@example.com
git -C "$ROOT/main" config user.name Test
git -C "$ROOT/main" config commit.gpgsign false
printf 'base\n' >"$ROOT/main/base.txt"
git -C "$ROOT/main" add base.txt
git -C "$ROOT/main" commit -q -m base

# Sources the script (the `path` command has no side effects) to get
# worktree_for_branch, overrides git to emit a fixed NUL-delimited porcelain
# listing, and prints the function's exit status and output for assertions.
probe_worktree_for_branch() {
  local porcelain_fmt="$1" branch="$2"
  (
    cd "$ROOT/main"
    # shellcheck source=../scripts/worktree
    source "$WORKTREE_SCRIPT" path probe >/dev/null
    PORCELAIN_FMT="$porcelain_fmt"
    git() {
      case "$*" in
        *"worktree list --porcelain -z"*)
          # shellcheck disable=SC2059
          printf "$PORCELAIN_FMT"
          ;;
        *) command git "$@" ;;
      esac
    }
    set +e
    out="$(worktree_for_branch "$branch")"
    rc=$?
    printf 'rc=%s out=%s' "$rc" "$out"
  )
}

echo "=== worktree_for_branch porcelain edge cases ==="

got="$(probe_worktree_for_branch 'branch refs/heads/ghost\0' ghost)"
assert_eq "$got" "rc=1 out=" "branch entry without a worktree path is not a match"

got="$(probe_worktree_for_branch 'branch refs/heads/ghost\0\0worktree /real/ghost\0branch refs/heads/ghost\0' ghost)"
assert_eq "$got" "rc=0 out=/real/ghost" "scanning continues past a pathless stanza to a real match"

got="$(probe_worktree_for_branch 'worktree /wt/ghost\0HEAD 0000000000000000000000000000000000000000\0branch refs/heads/ghost\0' ghost)"
assert_eq "$got" "rc=0 out=/wt/ghost" "well-formed stanza still resolves the worktree path"

got="$(probe_worktree_for_branch 'worktree /wt/other\0branch refs/heads/other\0' ghost)"
assert_eq "$got" "rc=1 out=" "absent branch still returns no-worktree"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
