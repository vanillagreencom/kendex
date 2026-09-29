#!/usr/bin/env bash
# The default branch the worktree commands read: WORKTREE_DEFAULT_BRANCH when
# set, else the repository's default branch on GitHub, read through the github
# skill beside this package. A checkout with no GitHub repository takes git's
# record of origin's HEAD and refuses where git holds none. The table runs
# `merged`, whose forge query carries the default branch as its --base; one
# `create` then starts a tree from GitHub's default branch.
set -euo pipefail
# A pre-commit hook exports GIT_DIR and GIT_INDEX_FILE, which point every git
# call below at the real repository; -C overrides neither.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/messages.sh
source "$TEST_DIR/lib/messages.sh"
PACKAGE_DIR="$(cd "$TEST_DIR/.." && pwd)"
SKILLS_DIR="$(cd "$PACKAGE_DIR/.." && pwd)"
WORKTREE_SCRIPT="$PACKAGE_DIR/scripts/worktree"
TMP_ROOT="$(mktemp -d)" || { echo "worktree_default_branch: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "worktree_default_branch: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "worktree_default_branch: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

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

# --- the forge ----------------------------------------------------------------
# GH_SLUG is what `gh repo view` names, `-` for a checkout gh finds no GitHub
# repository for; GH_DEFAULT is the repository's default_branch, FAIL for a
# read GitHub refuses. No merged pull request carries any branch.
mkdir -p "$TMP_ROOT/bin"
cat >"$TMP_ROOT/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$GH_LOG"
case "${1:-}:${2:-}" in
  repo:view)
    if [[ "$GH_SLUG" == - ]]; then
      echo "none of the git remotes configured for this repository point to a known GitHub host" >&2
      exit 1
    fi
    printf '%s\n' "$GH_SLUG"
    ;;
  api:repos/*)
    if [[ "$GH_DEFAULT" == FAIL ]]; then
      echo "gh: Not Found (HTTP 404)" >&2
      exit 1
    fi
    printf '%s\n' "$GH_DEFAULT"
    ;;
esac
exit 0
STUB
chmod +x "$TMP_ROOT/bin/gh"
GH_LOG="$TMP_ROOT/gh.log"

# --- the world ----------------------------------------------------------------
# main and develop on a bare origin, develop one commit past main, and git's
# record of origin's HEAD naming main. `lonely` is the branch `merged` asks
# about.
MAIN="$TMP_ROOT/main"
mkdir -p "$MAIN"
git -C "$MAIN" init -q -b main
git -C "$MAIN" config user.email test@example.com
git -C "$MAIN" config user.name Test
git -C "$MAIN" config commit.gpgsign false
printf 'orig\n' >"$MAIN/file.txt"
git -C "$MAIN" add file.txt
git -C "$MAIN" commit -q -m base
printf 'WORKTREE_BASE_DIR="../trees"\n' >"$MAIN/.env.local"
git init -q --bare "$TMP_ROOT/origin.git"
git -C "$MAIN" remote add origin "$TMP_ROOT/origin.git"
git -C "$MAIN" push -q -u origin main
git -C "$MAIN" checkout -q -b develop
printf 'develop\n' >"$MAIN/file.txt"
git -C "$MAIN" commit -q -am develop
git -C "$MAIN" push -q -u origin develop
DEVELOP="$(git -C "$MAIN" rev-parse develop)"
git -C "$MAIN" checkout -q main
git -C "$MAIN" remote set-head origin main
git -C "$MAIN" branch lonely

# The must-fail control: a copy of the two packages whose worktree script
# takes main in place of the github skill's answer.
READ_LINE='    answer="$(kendex_github_default_branch "$PROJECT_ROOT" 2>&1)" || rc=$?'
mkdir -p "$TMP_ROOT/pkg"
cp -R "$PACKAGE_DIR" "$TMP_ROOT/pkg/worktree"
cp -R "$SKILLS_DIR/github" "$TMP_ROOT/pkg/github"
MUTANT="$TMP_ROOT/pkg/worktree/scripts/worktree"
assert_eq "$(grep -cxF -- "$READ_LINE" "$MUTANT")" "1" "control: the default-branch read is one line"
F="$READ_LINE" awk 'BEGIN { f = ENVIRON["F"] } $0 == f { $0 = "    answer=main" } { print }' "$MUTANT" >"$TMP_ROOT/mutant.edit"
cat -- "$TMP_ROOT/mutant.edit" >"$MUTANT"
assert_eq "$(grep -cxF -- "$READ_LINE" "$MUTANT")" "0" "control: the read was replaced"

# --- the rows -------------------------------------------------------------------
# label|script|environment|exit|stderr records|the --base merged asked about|
# GitHub repository reads

records() {
  message_records <"$1" | sed "s|$MAIN|<root>|g" | paste -s -d ';' -
}

run_row() {
  local script="$1" env_words="$2" rc=0
  : >"$GH_LOG"
  [[ "$script" == mutant ]] && script="$MUTANT" || script="$WORKTREE_SCRIPT"
  # shellcheck disable=SC2086 # the row's environment is words
  (cd "$MAIN" && env -u WORKTREE_DEFAULT_BRANCH -u GH_REPO PATH="$TMP_ROOT/bin:$PATH" GH_LOG="$GH_LOG" $env_words \
    "$script" merged lonely >"$TMP_ROOT/out" 2>"$TMP_ROOT/err") || rc=$?
  printf 'rc=%s err=%s base=%s reads=%s' "$rc" "$(records "$TMP_ROOT/err")" \
    "$(sed -n 's/^pr list .*--base \([^ ]*\) .*/\1/p' "$GH_LOG" | paste -s -d , -)" \
    "$(grep -c '^api repos/' "$GH_LOG" || true)"
}

echo "=== the default branch ==="
while IFS='|' read -r label script env_words rc err base reads; do
  [[ -n "$label" ]] || continue
  if [[ "$label" == *"no record"* ]]; then git -C "$MAIN" remote set-head origin -d; fi
  assert_eq "$(run_row "$script" "$env_words")" "rc=$rc err=$err base=$base reads=$reads" "$label"
done <<'ROWS'
GitHub's default branch is the one the forge is asked about|real|GH_SLUG=acme/widgets GH_DEFAULT=develop|1|worktree-unmerged: lonely|develop|1
must-fail: with the read replaced by main, develop's repository is asked about main|mutant|GH_SLUG=acme/widgets GH_DEFAULT=develop|1|worktree-unmerged: lonely|main|0
WORKTREE_DEFAULT_BRANCH overrides, and GitHub is not asked|real|GH_SLUG=acme/widgets GH_DEFAULT=develop WORKTREE_DEFAULT_BRANCH=trunk|1|worktree-unmerged: lonely|trunk|0
a default branch GitHub cannot name leaves the question unanswered|real|GH_SLUG=acme/widgets GH_DEFAULT=FAIL|2|worktree-default-branch-unreadable: <root>||1
a checkout with no GitHub repository takes git's record of origin's HEAD|real|GH_SLUG=- GH_DEFAULT=develop|1|worktree-unmerged: lonely|main|0
a checkout with no GitHub repository and no record refuses|real|GH_SLUG=- GH_DEFAULT=develop|2|worktree-default-branch-unknown: <root>||0
ROWS
git -C "$MAIN" remote set-head origin main

echo "=== create starts from GitHub's default branch ==="
rc=0
(cd "$MAIN" && env -u WORKTREE_DEFAULT_BRANCH -u GH_REPO PATH="$TMP_ROOT/bin:$PATH" GH_LOG="$GH_LOG" \
  GH_SLUG=acme/widgets GH_DEFAULT=develop "$WORKTREE_SCRIPT" create dev1 >"$TMP_ROOT/out" 2>"$TMP_ROOT/err") || rc=$?
assert_eq "$rc" 0 "create exits 0"
assert_eq "$(git -C "$(cat "$TMP_ROOT/out")" rev-parse HEAD 2>/dev/null || true)" "$DEVELOP" \
  "the new tree starts at origin/develop"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
