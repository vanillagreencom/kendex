#!/usr/bin/env bash
# `cleanup` and `remove` against squash-merged branches (#697).
#
# Every PR in this fleet lands by squash through the merge queue, so the merged
# branch is rewritten into a new commit and is an ancestor of nothing. Ancestry
# alone therefore reports every merged worktree as pending, and the old cleanup
# loop said nothing at all about the ones it declined to collect. What is under
# test:
#
#   * a squash-merged branch is collected on the forge's merged-PR proof;
#   * a branch with no merged PR is KEPT and named as unmerged;
#   * a lookup that cannot answer — gh failing, gh missing — keeps the worktree
#     and names that too, because an unanswered lookup is not a merge;
#   * `remove` deletes a squash-merged branch (`git branch -d` refuses it) and
#     still keeps an unmerged one.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKTREE_SCRIPT="$(cd "$TEST_DIR/.." && pwd)/scripts/worktree"

TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }

assert_eq() {
  local got="$1" want="$2" name="$3"
  if [[ "$got" == "$want" ]]; then
    pass "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$name" "$want" "$got"
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" name="$3"
  if grep -qF -- "$needle" <<<"$haystack"; then
    pass "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        wanted substring: %s\n        in: %s\n' "$name" "$needle" "$haystack"
  fi
}

assert_path_exists() {
  [[ -e "$1" ]] && pass "$2" || fail "$2 (missing: $1)"
}

assert_path_absent() {
  [[ ! -e "$1" ]] && pass "$2" || fail "$2 (still exists: $1)"
}

# `gh pr list --state merged --head <branch>` answers from GH_MERGED_PRS, a
# newline-separated "<branch> <number>" table. GH_FAIL=1 makes the query fail
# the way a network or auth error does.
make_gh_stub() {
  local bin="$1"
  mkdir -p "$bin"
  cat >"$bin/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
if [[ "${GH_FAIL:-0}" == "1" ]]; then
  echo "gh: could not reach api.github.com" >&2
  exit 1
fi
branch=""
prev=""
for arg in "$@"; do
  [[ "$prev" == "--head" ]] && branch="$arg"
  prev="$arg"
done
while read -r want number; do
  [[ -n "$want" ]] || continue
  if [[ "$want" == "$branch" ]]; then
    printf '%s\n' "$number"
    exit 0
  fi
done <<<"${GH_MERGED_PRS:-}"
exit 0
STUB
  chmod +x "$bin/gh"
}

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
  printf 'WORKTREE_BASE_DIR="../trees"\n' >"$root/main/.env"
  git init -q --bare "$root/origin.git"
  git -C "$root/main" remote add origin "$root/origin.git"
  git -C "$root/main" push -q -u origin main
}

# A branch with one commit of its own, checked out in its own worktree. Nothing
# lands on main, so it is unmerged by both proofs until the caller squashes it.
add_branch_tree() {
  local root="$1" name="$2"
  git -C "$root/main" worktree add -q -b "$name" "$root/trees/$name" main
  printf '%s\n' "$name" >"$root/trees/$name/$name.txt"
  git -C "$root/trees/$name" add "$name.txt"
  git -C "$root/trees/$name" commit -q -m "$name: work"
}

# Land the branch's content on main as a NEW commit, exactly as a squash merge
# does: the branch tip stays outside main's history forever.
squash_onto_main() {
  local root="$1" name="$2"
  printf '%s\n' "$name" >"$root/main/$name.txt"
  git -C "$root/main" add "$name.txt"
  git -C "$root/main" commit -q -m "$name: work (squashed)"
  git -C "$root/main" push -q origin main
}

echo "=== cleanup collects a squash-merged worktree ==="

ROOT="$TMP_ROOT/squash"
make_repo "$ROOT"
make_gh_stub "$ROOT/bin"
export PATH="$ROOT/bin:$PATH"

add_branch_tree "$ROOT" "issue-merged"
add_branch_tree "$ROOT" "issue-open"
squash_onto_main "$ROOT" "issue-merged"

MERGED_TREE="$ROOT/trees/issue-merged"
OPEN_TREE="$ROOT/trees/issue-open"

# Ancestry must genuinely fail here, or the test proves nothing about the PR
# lookup: it would pass on the ancestry arm alone.
if git -C "$ROOT/main" merge-base --is-ancestor issue-merged origin/main; then
  fail "precondition: the squashed branch must NOT be an ancestor of origin/main"
else
  pass "precondition: the squashed branch is not an ancestor of origin/main"
fi

export GH_MERGED_PRS="issue-merged 4242"
squash_code=0
squash_out=$(cd "$ROOT/main" && "$WORKTREE_SCRIPT" cleanup 2>"$ROOT/squash.err") || squash_code=$?
squash_err="$(cat "$ROOT/squash.err")"

assert_eq "$squash_code" "0" "cleanup exits 0"
assert_contains "$squash_out" "Cleaned: $MERGED_TREE" "cleanup collects the squash-merged worktree"
assert_path_absent "$MERGED_TREE" "the squash-merged worktree is gone"
if git -C "$ROOT/main" show-ref --verify --quiet refs/heads/issue-merged; then
  fail "cleanup deletes the squash-merged branch"
else
  pass "cleanup deletes the squash-merged branch"
fi

echo "=== cleanup names the worktree it keeps ==="

assert_path_exists "$OPEN_TREE" "the unmerged worktree survives"
assert_contains "$squash_err" "Skipped (branch 'issue-open' is not merged" \
  "cleanup reports the unmerged worktree instead of passing over it silently"
assert_contains "$squash_err" "$OPEN_TREE" "the unmerged skip names the path"

echo "=== an unanswerable lookup keeps the worktree ==="

fail_code=0
fail_out=$(cd "$ROOT/main" && GH_FAIL=1 "$WORKTREE_SCRIPT" cleanup 2>"$ROOT/fail.err") || fail_code=$?
fail_err="$(cat "$ROOT/fail.err")"

assert_eq "$fail_code" "0" "a failed lookup is a kept worktree, not a cleanup error"
assert_path_exists "$OPEN_TREE" "a failed lookup never removes the worktree"
assert_contains "$fail_err" "could not be determined" \
  "cleanup says the merge status could not be determined"
assert_contains "$fail_err" "issue-open" "the unanswerable skip names the branch"
if grep -qF "Cleaned:" <<<"$fail_out"; then
  fail "a failed lookup collects nothing"
else
  pass "a failed lookup collects nothing"
fi

echo "=== a missing gh keeps the worktree ==="

# A PATH holding every tool the script reaches for EXCEPT gh. Dropping the real
# PATH wholesale would fail for the wrong reason (no git), and shadowing gh is
# impossible — `command -v` answers from PATH alone.
NOGH_BIN="$ROOT/bin-nogh"
mkdir -p "$NOGH_BIN"
for tool in git grep sed awk cat cut tr sort uniq wc head tail find ln rm rmdir \
            mkdir mv cp ls readlink realpath dirname basename mktemp date id \
            hostname ps kill sleep touch chmod stat printf env flock jq; do
  tool_path="$(command -v "$tool" 2>/dev/null || true)"
  [[ -n "$tool_path" ]] && ln -sf "$tool_path" "$NOGH_BIN/$tool"
done
if command -v gh >/dev/null 2>&1 && PATH="$NOGH_BIN" command -v gh >/dev/null 2>&1; then
  fail "precondition: the gh-free PATH must not resolve gh"
else
  pass "precondition: the gh-free PATH does not resolve gh"
fi

nogh_code=0
nogh_out=$(cd "$ROOT/main" && PATH="$NOGH_BIN" \
  "$WORKTREE_SCRIPT" cleanup 2>"$ROOT/nogh.err") || nogh_code=$?
nogh_err="$(cat "$ROOT/nogh.err")"

assert_eq "$nogh_code" "0" "a missing gh is a kept worktree, not a cleanup error"
assert_path_exists "$OPEN_TREE" "a missing gh never removes the worktree"
assert_contains "$nogh_err" "gh is not installed" "cleanup names the missing gh"
if grep -qF "Cleaned:" <<<"$nogh_out"; then
  fail "a missing gh collects nothing"
else
  pass "a missing gh collects nothing"
fi

echo "=== remove deletes a squash-merged branch ==="

RM_ROOT="$TMP_ROOT/remove"
make_repo "$RM_ROOT"
add_branch_tree "$RM_ROOT" "issue-rm"
squash_onto_main "$RM_ROOT" "issue-rm"

export GH_MERGED_PRS="issue-rm 77"
rm_code=0
rm_out=$(cd "$RM_ROOT/main" && "$WORKTREE_SCRIPT" remove "$RM_ROOT/trees/issue-rm" 2>"$RM_ROOT/rm.err") || rm_code=$?
rm_err="$(cat "$RM_ROOT/rm.err")"

assert_eq "$rm_code" "0" "remove exits 0 on a squash-merged branch"
assert_contains "$rm_out" "Removed: $RM_ROOT/trees/issue-rm" "remove removed the worktree"
assert_contains "$rm_err" "squash-merged in pull request #77" "remove names the proof it used"
if git -C "$RM_ROOT/main" show-ref --verify --quiet refs/heads/issue-rm; then
  fail "remove deletes the squash-merged branch"
else
  pass "remove deletes the squash-merged branch"
fi

echo "=== remove keeps an unmerged branch ==="

add_branch_tree "$RM_ROOT" "issue-keep"
export GH_MERGED_PRS=""
keep_code=0
keep_out=$(cd "$RM_ROOT/main" && "$WORKTREE_SCRIPT" remove "$RM_ROOT/trees/issue-keep" 2>"$RM_ROOT/keep.err") || keep_code=$?
keep_err="$(cat "$RM_ROOT/keep.err")"

assert_eq "$keep_code" "1" "remove still exits nonzero when the branch is not merged"
assert_contains "$keep_err" "Remaining branch: issue-keep" "remove names the branch it kept"
assert_contains "$keep_err" "No merged pull request for 'issue-keep'" \
  "remove says the pull-request proof failed too"
if git -C "$RM_ROOT/main" show-ref --verify --quiet refs/heads/issue-keep; then
  pass "remove leaves the unmerged branch alone"
else
  fail "remove leaves the unmerged branch alone"
fi
: "${keep_out:=}"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
