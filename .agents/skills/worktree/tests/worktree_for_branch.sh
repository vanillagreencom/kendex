#!/usr/bin/env bash
# `worktree_for_branch`, the parser of `git worktree list --porcelain -z`:
# success always carries a non-empty worktree path, so a command-substitution
# caller can read empty output as "no worktree" without also getting exit 0.
# One table, a row per porcelain shape: the row's listing stands in for git's
# (a stanza without a worktree line, a pathless stanza before the real match,
# a pathless stanza after one with a path, a well-formed stanza, an absent
# branch, a path recorded under a symlinked spelling), and the row pins the
# function's exit status and output.
set -euo pipefail
# A pre-commit hook exports GIT_DIR and GIT_INDEX_FILE, which point every git
# call below at the real repository; -C overrides neither.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

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

# --- fixture ------------------------------------------------------------------
# One checkout to source the script in (the `path` command has no side
# effects); the rows never touch it.

ROOT="$TMP_ROOT/porcelain"
mkdir -p "$ROOT/main"
git -C "$ROOT/main" init -q -b main
git -C "$ROOT/main" config user.email test@example.com
git -C "$ROOT/main" config user.name Test
git -C "$ROOT/main" config commit.gpgsign false
printf 'base\n' >"$ROOT/main/base.txt"
git -C "$ROOT/main" add base.txt
git -C "$ROOT/main" commit -q -m base
# A worktree recorded under a symlinked spelling: the row asserts the physical
# path, which only the canonicalizing arm can produce.
mkdir -p "$ROOT/real/ghost"
ln -s "$ROOT/real" "$ROOT/link"

# Sources the script to get worktree_for_branch, overrides git to emit the
# row's NUL-delimited listing for `worktree list --porcelain -z` (every other
# git call is the real one), and prints the function's exit status and output.
run() {
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
    printf 'rc=%s out=%s' "$rc" "${out:--}"
  )
}

# --- the rows ---------------------------------------------------------------------
# label|porcelain (printf format, \0 between lines; <root> is the fixture's root)|branch|rc|out
ROWS='a branch entry without a worktree line is not a match|branch refs/heads/ghost\0|ghost|1|-
the scan continues past a pathless stanza to the real match|branch refs/heads/ghost\0\0worktree /real/ghost\0branch refs/heads/ghost\0|ghost|0|/real/ghost
a well-formed stanza resolves the worktree path|worktree /wt/ghost\0HEAD 0000000000000000000000000000000000000000\0branch refs/heads/ghost\0|ghost|0|/wt/ghost
a pathless stanza after a stanza with a path does not inherit that path|worktree /wt/other\0branch refs/heads/other\0\0branch refs/heads/ghost\0|ghost|1|-
an absent branch is no worktree, a longer name with its prefix included|worktree /wt/ghostly\0branch refs/heads/ghostly\0|ghost|1|-
a path recorded under a symlinked spelling is reported as the physical directory|worktree <root>/link/ghost\0branch refs/heads/ghost\0|ghost|0|<root>/real/ghost
'

echo "=== worktree_for_branch over porcelain shapes ==="
while IFS= read -r row; do
  [[ -n "$row" ]] || continue
  IFS='|' read -r label porcelain branch rc out <<<"$row"
  porcelain="${porcelain//<root>/$ROOT}"
  out="${out//<root>/$ROOT}"
  for field in "$label" "$porcelain" "$branch" "$rc" "$out"; do
    [[ -n "$field" ]] || { printf 'a row with an empty field asserts nothing: %s\n' "$row" >&2; exit 1; }
  done
  # A rendering aid for writing rows: prints what each row produces instead of
  # asserting it. A run that asserted no row is refused after the loop.
  if [[ "${WORKTREE_TABLE_PROBE:-}" == 1 ]]; then
    printf '%s => %s\n' "$label" "$(run "$porcelain" "$branch")"
    continue
  fi
  assert_eq "$(run "$porcelain" "$branch")" "rc=$rc out=$out" "$label"
done <<<"$ROWS"
[[ "$((PASS + FAIL))" -gt 0 ]] || { echo "no row was asserted (a probe run renders rows instead)" >&2; exit 2; }

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
