#!/usr/bin/env bash
# Tests for `create --pr` against a fork pull request: the head branch lives
# in the contributor's repository, so origin has no such head and the commit
# is reachable only through origin's refs/pull/<n>/head. A same-repository PR
# keeps the tracked origin-branch checkout, and a pull ref that does not
# deliver the head gh reports refuses before any worktree exists.
set -euo pipefail

# A pre-commit hook exports GIT_DIR and GIT_INDEX_FILE, which point every git
# call in this file back at the real repository.
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

ROOT="$TMP_ROOT/fork-pr"
mkdir -p "$ROOT/main" "$ROOT/bin" "$ROOT/gh-state"
git -C "$ROOT/main" init -q -b main
git -C "$ROOT/main" config user.email test@example.com
git -C "$ROOT/main" config user.name Test
git -C "$ROOT/main" config commit.gpgsign false
printf 'base\n' >"$ROOT/main/base.txt"
git -C "$ROOT/main" add base.txt
git -C "$ROOT/main" commit -q -m base
printf 'WORKTREE_BASE_DIR="../trees"\n' >"$ROOT/main/.env.local"
git init -q --bare "$ROOT/origin.git"
git -C "$ROOT/main" remote add origin "$ROOT/origin.git"
git -C "$ROOT/main" push -q -u origin main

# The contributor's repository: a clone of origin whose branch never reaches
# origin as a head. GitHub exposes such a head to the base repository only as
# refs/pull/<n>/head, which is the one ref the fixture publishes.
git clone -q "$ROOT/origin.git" "$ROOT/fork"
git -C "$ROOT/fork" config user.email fork@example.com
git -C "$ROOT/fork" config user.name Fork
git -C "$ROOT/fork" config commit.gpgsign false
git -C "$ROOT/fork" checkout -q -b fix/widget-expiry
printf 'fork fix\n' >"$ROOT/fork/fix.txt"
git -C "$ROOT/fork" add fix.txt
git -C "$ROOT/fork" commit -q -m 'fork fix'
FORK_HEAD="$(git -C "$ROOT/fork" rev-parse HEAD)"
git -C "$ROOT/fork" push -q origin "HEAD:refs/pull/7/head"

# A same-repository PR: its head is an ordinary origin branch.
git -C "$ROOT/main" checkout -q -b feat/same
printf 'same repo\n' >"$ROOT/main/same.txt"
git -C "$ROOT/main" add same.txt
git -C "$ROOT/main" commit -q -m 'same-repo feature'
SAME_HEAD="$(git -C "$ROOT/main" rev-parse HEAD)"
git -C "$ROOT/main" push -q origin feat/same "HEAD:refs/pull/8/head"
git -C "$ROOT/main" checkout -q main
git -C "$ROOT/main" branch -q -D feat/same

# A pull ref that is not the head gh reports: the base's own tip.
git -C "$ROOT/main" push -q origin "main:refs/pull/9/head"
PHANTOM_OID="$(printf '%040d' 1)"

# gh as it answers `pr view <n> --json <fields> -q <query>`: the stored
# document is the field set gh returns, and the query runs over it.
cat >"$ROOT/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}:${2:-}" in
  pr:list) exit 0 ;;
  pr:view)
    pr="$3"
    shift 3
    query=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -q | --jq) query="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    doc="${GH_STATE:?}/pr-$pr.json"
    if [[ ! -f "$doc" ]]; then
      printf 'GraphQL: Could not resolve to a PullRequest with the number of %s.\n' "$pr" >&2
      exit 1
    fi
    jq -r "$query" "$doc"
    ;;
  *)
    printf 'gh stub: unexpected call %s\n' "$*" >&2
    exit 64
    ;;
esac
STUB
chmod +x "$ROOT/bin/gh"
export PATH="$ROOT/bin:$PATH"
export GH_STATE="$ROOT/gh-state"

pr_doc() {
  local number="$1" name="$2" oid="$3" cross="$4"
  printf '{"headRefName":"%s","headRefOid":"%s","isCrossRepository":%s}\n' \
    "$name" "$oid" "$cross" >"$GH_STATE/pr-$number.json"
}
pr_doc 7 fix/widget-expiry "$FORK_HEAD" true
pr_doc 8 feat/same "$SAME_HEAD" false
pr_doc 9 fix/phantom "$PHANTOM_OID" true
pr_doc 10 fix/no-pull-ref "$FORK_HEAD" true

echo "=== worktree create --pr on a fork pull request ==="

origin_heads_before="$(git -C "$ROOT/origin.git" for-each-ref --format='%(refname) %(objectname)' | sort)"

set +e
fork_out="$(cd "$ROOT/main" && "$WORKTREE_SCRIPT" create issue-fork --pr 7 2>"$ROOT/fork.err")"
fork_code=$?
set -e
FORK_WT="$ROOT/trees/issue-fork"
assert_eq "$fork_code" "0" "fork PR creates a worktree (stderr: $(tr '\n' ' ' <"$ROOT/fork.err"))"
assert_eq "$fork_out" "$FORK_WT" "fork PR prints the worktree path"
assert_eq "$(git -C "$FORK_WT" rev-parse HEAD 2>/dev/null || true)" "$FORK_HEAD" "fork worktree HEAD is the PR head commit"
assert_eq "$(git -C "$FORK_WT" branch --show-current 2>/dev/null || true)" "fix/widget-expiry" "fork worktree branch carries the contributor's branch name"
set +e
fork_upstream="$(git -C "$FORK_WT" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)"
fork_upstream_code=$?
set -e
assert_eq "$fork_upstream_code:$fork_upstream" "128:" "fork worktree branch has no upstream"
assert_eq "$(git -C "$ROOT/main" remote | sort | tr '\n' ' ')" "origin " "no remote is added for the fork"
assert_eq "$(git -C "$ROOT/origin.git" for-each-ref --format='%(refname) %(objectname)' | sort)" "$origin_heads_before" "origin refs are unchanged after the fork checkout"

set +e
same_out="$(cd "$ROOT/main" && "$WORKTREE_SCRIPT" create issue-same --pr 8 2>"$ROOT/same.err")"
same_code=$?
set -e
SAME_WT="$ROOT/trees/issue-same"
assert_eq "$same_code" "0" "same-repository PR creates a worktree (stderr: $(tr '\n' ' ' <"$ROOT/same.err"))"
assert_eq "$same_out" "$SAME_WT" "same-repository PR prints the worktree path"
assert_eq "$(git -C "$SAME_WT" rev-parse HEAD 2>/dev/null || true)" "$SAME_HEAD" "same-repository worktree HEAD is the origin branch tip"
assert_eq "$(git -C "$SAME_WT" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)" "origin/feat/same" "same-repository branch tracks its origin branch"

# A fork head the base cannot deliver refuses before any worktree exists:
#   number  issue            message fragment
rows=(
  "9	issue-phantom	did not deliver commit $PHANTOM_OID"
  "10	issue-no-ref	Could not fetch refs/pull/10/head from origin"
)
for row in "${rows[@]}"; do
  IFS=$'\t' read -r number issue fragment <<<"$row"
  set +e
  (cd "$ROOT/main" && "$WORKTREE_SCRIPT" create "$issue" --pr "$number" >"$ROOT/$issue.out" 2>"$ROOT/$issue.err")
  code=$?
  set -e
  assert_eq "$code" "1" "PR #$number: undeliverable fork head exits 1"
  assert_contains "$(cat "$ROOT/$issue.err")" "$fragment" "PR #$number: refusal names the cause"
  assert_path_absent "$ROOT/trees/$issue" "PR #$number: no worktree is created"
done

echo
echo "Passed: $PASS, Failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
