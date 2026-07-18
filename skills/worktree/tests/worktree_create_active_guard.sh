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
  # Pin the historical sibling trees/ base so this file's path assertions stay
  # explicit; default base-dir resolution is covered by worktree_base_dir.sh.
  printf 'WORKTREE_BASE_DIR="../trees"\n' >"$root/main/.env"
  git init -q --bare "$root/origin.git"
  git -C "$root/main" remote add origin "$root/origin.git"
  git -C "$root/main" push -q -u origin main

  cat >"$root/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}:${2:-}" in
  pr:list)
    if [[ -f "${GH_STATE:?}/fail-gh" ]]; then
      printf 'simulated gh failure\n' >&2
      exit 42
    fi
    if [[ -f "${GH_STATE:?}/slow-gh" ]]; then
      sleep 0.2
    fi
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

# A relative worktree base inside the checkout must never let `git -C` search
# upward and reinterpret an incomplete target as the main checkout. Explicit
# reuse is subject to the same exact registration/common-dir proof.
IN_REPO_ROOT="$TMP_ROOT/in-repo"
make_repo "$IN_REPO_ROOT"
cat >"$IN_REPO_ROOT/main/.env" <<'ENV'
WORKTREE_BASE_DIR="trees"
ENV
mkdir -p "$IN_REPO_ROOT/main/trees/issue-incomplete"
printf 'preserve these bytes\n' >"$IN_REPO_ROOT/main/trees/issue-incomplete/owner-marker"
in_repo_pre_head="$(git -C "$IN_REPO_ROOT/main" rev-parse HEAD)"
in_repo_pre_config="$(git -C "$IN_REPO_ROOT/main" config --get extensions.worktreeConfig 2>/dev/null || true)"
in_repo_pre_marker="$(cat "$IN_REPO_ROOT/main/trees/issue-incomplete/owner-marker")"
export GH_STATE="$IN_REPO_ROOT/gh-state"
set +e
(cd "$IN_REPO_ROOT/main" && "$WORKTREE_SCRIPT" create issue-incomplete --reuse >"$IN_REPO_ROOT/reuse.out" 2>"$IN_REPO_ROOT/reuse.err")
in_repo_code=$?
set -e
assert_eq "$in_repo_code" "75" "--reuse exits 75 for an in-repo incomplete target"
assert_eq "$(git -C "$IN_REPO_ROOT/main" rev-parse HEAD)" "$in_repo_pre_head" "incomplete-target reuse preserves main HEAD"
assert_eq "$(git -C "$IN_REPO_ROOT/main" config --get extensions.worktreeConfig 2>/dev/null || true)" "$in_repo_pre_config" "incomplete-target reuse preserves repository config"
assert_eq "$(cat "$IN_REPO_ROOT/main/trees/issue-incomplete/owner-marker")" "$in_repo_pre_marker" "incomplete-target reuse preserves target bytes"
assert_path_absent "$IN_REPO_ROOT/main/trees/issue-incomplete/.git" "incomplete-target reuse does not register the target"

# --from is a new-branch mode, not an inspection escape hatch. Existing target
# ownership on the remote must stop it before a divergent checkout is created.
export GH_STATE="$ROOT/gh-state"
git -C "$ROOT/main" branch issue-from-remote main
git -C "$ROOT/main" push -q origin issue-from-remote
git -C "$ROOT/main" branch -D issue-from-remote >/dev/null
set +e
(cd "$ROOT/main" && "$WORKTREE_SCRIPT" create issue-from-remote --from main >"$ROOT/from-remote.out" 2>"$ROOT/from-remote.err")
from_remote_code=$?
set -e
assert_eq "$from_remote_code" "75" "--from exits 75 for an existing remote target branch"
assert_contains "$(cat "$ROOT/from-remote.err")" "existing remote branch" "--from reports remote ownership"
assert_path_absent "$ROOT/trees/issue-from-remote" "--from creates no duplicate worktree"
assert_branch_absent "$ROOT/main" "issue-from-remote" "--from creates no duplicate local branch"

# BOT_NAME/<issue> is an equal ownership candidate even when no PR exists.
git -C "$ROOT/main" branch robot/issue-bot-local main
set +e
(cd "$ROOT/main" && BOT_NAME=robot BOT_EMAIL=robot@example.test "$WORKTREE_SCRIPT" create issue-bot-local >"$ROOT/bot-local.out" 2>"$ROOT/bot-local.err")
bot_local_code=$?
set -e
assert_eq "$bot_local_code" "75" "bare create exits 75 for a bot-prefixed local branch"
assert_contains "$(cat "$ROOT/bot-local.err")" "robot/issue-bot-local" "bot local guard identifies the candidate branch"
assert_path_absent "$ROOT/trees/issue-bot-local" "bot local guard creates no worktree"

git -C "$ROOT/main" branch robot/issue-bot-remote main
git -C "$ROOT/main" push -q origin robot/issue-bot-remote
git -C "$ROOT/main" branch -D robot/issue-bot-remote >/dev/null
set +e
(cd "$ROOT/main" && BOT_NAME=robot BOT_EMAIL=robot@example.test "$WORKTREE_SCRIPT" create issue-bot-remote >"$ROOT/bot-remote.out" 2>"$ROOT/bot-remote.err")
bot_remote_code=$?
set -e
assert_eq "$bot_remote_code" "75" "bare create exits 75 for a bot-prefixed remote branch"
assert_contains "$(cat "$ROOT/bot-remote.err")" "origin/robot/issue-bot-remote" "bot remote guard identifies the remote candidate"
assert_path_absent "$ROOT/trees/issue-bot-remote" "bot remote guard creates no worktree"

# A failed GitHub ownership query is uncertainty, not absence. The script must
# fail before enabling per-worktree config or creating any branch/path.
GH_FAIL_ROOT="$TMP_ROOT/gh-failure"
make_repo "$GH_FAIL_ROOT"
touch "$GH_FAIL_ROOT/gh-state/fail-gh"
export GH_STATE="$GH_FAIL_ROOT/gh-state"
gh_fail_pre_head="$(git -C "$GH_FAIL_ROOT/main" rev-parse HEAD)"
gh_fail_pre_config="$(git -C "$GH_FAIL_ROOT/main" config --get extensions.worktreeConfig 2>/dev/null || true)"
set +e
(cd "$GH_FAIL_ROOT/main" && "$WORKTREE_SCRIPT" create issue-gh-failure >"$GH_FAIL_ROOT/create.out" 2>"$GH_FAIL_ROOT/create.err")
gh_fail_code=$?
set -e
assert_eq "$gh_fail_code" "1" "gh ownership failure exits 1"
assert_contains "$(cat "$GH_FAIL_ROOT/create.err")" "refusing to assume it is unowned" "gh failure reports fail-closed ownership discovery"
assert_eq "$(git -C "$GH_FAIL_ROOT/main" rev-parse HEAD)" "$gh_fail_pre_head" "gh failure preserves main HEAD"
assert_eq "$(git -C "$GH_FAIL_ROOT/main" config --get extensions.worktreeConfig 2>/dev/null || true)" "$gh_fail_pre_config" "gh failure preserves repository config"
assert_branch_absent "$GH_FAIL_ROOT/main" "issue-gh-failure" "gh failure creates no local branch"
assert_path_absent "$GH_FAIL_ROOT/trees/issue-gh-failure" "gh failure creates no worktree path"

# A final fetch can fail after the read-only remote/PR probes succeeded. Keep
# that failure before branch/worktree/config mutation too.
FETCH_FAIL_ROOT="$TMP_ROOT/fetch-failure"
make_repo "$FETCH_FAIL_ROOT"
REAL_GIT="$(command -v git)"
cat >"$FETCH_FAIL_ROOT/bin/git" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
for arg in "$@"; do
  if [[ "$arg" == "fetch" && -f "${GIT_STATE:?}/fail-fetch" ]]; then
    printf 'simulated fetch failure\n' >&2
    exit 42
  fi
done
exec "${GIT_REAL:?}" "$@"
STUB
chmod +x "$FETCH_FAIL_ROOT/bin/git"
touch "$FETCH_FAIL_ROOT/gh-state/fail-fetch"
export GH_STATE="$FETCH_FAIL_ROOT/gh-state"
fetch_fail_pre_head="$(git -C "$FETCH_FAIL_ROOT/main" rev-parse HEAD)"
fetch_fail_pre_config="$(git -C "$FETCH_FAIL_ROOT/main" config --get extensions.worktreeConfig 2>/dev/null || true)"
set +e
(cd "$FETCH_FAIL_ROOT/main" && PATH="$FETCH_FAIL_ROOT/bin:$PATH" GIT_REAL="$REAL_GIT" GIT_STATE="$FETCH_FAIL_ROOT/gh-state" "$WORKTREE_SCRIPT" create issue-fetch-failure >"$FETCH_FAIL_ROOT/create.out" 2>"$FETCH_FAIL_ROOT/create.err")
fetch_fail_code=$?
set -e
assert_eq "$fetch_fail_code" "1" "final fetch failure exits 1"
assert_contains "$(cat "$FETCH_FAIL_ROOT/create.err")" "Could not refresh remote 'origin'" "fetch failure reports authoritative refresh failure"
assert_eq "$(git -C "$FETCH_FAIL_ROOT/main" rev-parse HEAD)" "$fetch_fail_pre_head" "fetch failure preserves main HEAD"
assert_eq "$(git -C "$FETCH_FAIL_ROOT/main" config --get extensions.worktreeConfig 2>/dev/null || true)" "$fetch_fail_pre_config" "fetch failure preserves repository config"
assert_branch_absent "$FETCH_FAIL_ROOT/main" "issue-fetch-failure" "fetch failure creates no local branch"
assert_path_absent "$FETCH_FAIL_ROOT/trees/issue-fetch-failure" "fetch failure creates no worktree path"

# Remote discovery itself must also fail closed before the claim lock/path.
REMOTE_FAIL_ROOT="$TMP_ROOT/remote-failure"
make_repo "$REMOTE_FAIL_ROOT"
git -C "$REMOTE_FAIL_ROOT/main" remote set-url origin "$REMOTE_FAIL_ROOT/missing-origin.git"
export GH_STATE="$REMOTE_FAIL_ROOT/gh-state"
remote_fail_pre_config="$(git -C "$REMOTE_FAIL_ROOT/main" config --get extensions.worktreeConfig 2>/dev/null || true)"
set +e
(cd "$REMOTE_FAIL_ROOT/main" && "$WORKTREE_SCRIPT" create issue-remote-failure >"$REMOTE_FAIL_ROOT/create.out" 2>"$REMOTE_FAIL_ROOT/create.err")
remote_fail_code=$?
set -e
assert_eq "$remote_fail_code" "1" "remote ownership discovery failure exits 1"
assert_contains "$(cat "$REMOTE_FAIL_ROOT/create.err")" "Could not query remote 'origin'" "remote discovery failure is explicit"
assert_eq "$(git -C "$REMOTE_FAIL_ROOT/main" config --get extensions.worktreeConfig 2>/dev/null || true)" "$remote_fail_pre_config" "remote discovery failure preserves repository config"
assert_branch_absent "$REMOTE_FAIL_ROOT/main" "issue-remote-failure" "remote discovery failure creates no local branch"
assert_path_absent "$REMOTE_FAIL_ROOT/trees/issue-remote-failure" "remote discovery failure creates no worktree path"

# Concurrent claimers both pass their read-only preliminary discovery. The
# repository-local issue lock makes exactly one add; the waiter reruns the
# final checks and exits 75 without duplicate mutation.
RACE_ROOT="$TMP_ROOT/concurrent"
make_repo "$RACE_ROOT"
touch "$RACE_ROOT/gh-state/slow-gh"
export GH_STATE="$RACE_ROOT/gh-state"
set +e
(cd "$RACE_ROOT/main" && "$WORKTREE_SCRIPT" create issue-race >"$RACE_ROOT/a.out" 2>"$RACE_ROOT/a.err") &
race_pid_a=$!
(cd "$RACE_ROOT/main" && "$WORKTREE_SCRIPT" create ISSUE-RACE >"$RACE_ROOT/b.out" 2>"$RACE_ROOT/b.err") &
race_pid_b=$!
wait "$race_pid_a"
race_code_a=$?
wait "$race_pid_b"
race_code_b=$?
set -e
if [[ "$race_code_a:$race_code_b" == "0:75" || "$race_code_a:$race_code_b" == "75:0" ]]; then
  PASS=$((PASS + 1))
  printf '  ok    concurrent claim has one success and one active-work exit\n'
else
  FAIL=$((FAIL + 1))
  printf '  FAIL  concurrent claim exit codes\n        expected: 0:75 or 75:0\n        got:      %s:%s\n' "$race_code_a" "$race_code_b"
fi
assert_path_exists "$RACE_ROOT/trees/issue-race/.git" "concurrent claim creates one registered target"
assert_eq "$(git -C "$RACE_ROOT/main" worktree list --porcelain | grep -c '^branch refs/heads/issue-race$')" "1" "concurrent claim registers the issue branch once"
assert_eq "$(git -C "$RACE_ROOT/main" config --get extensions.worktreeConfig)" "true" "concurrent loser does not prevent successful setup"

echo "=== worktree create option/help parsing (#621) ==="

# --help / -h print create-specific usage, exit 0, and create nothing. This is
# the sibling of the remove --help fix (#619) at both create parse sites.
CREATE_HELP_ROOT="$TMP_ROOT/create-help"
make_repo "$CREATE_HELP_ROOT"
export GH_STATE="$CREATE_HELP_ROOT/gh-state"
set +e
create_help_out=$(cd "$CREATE_HELP_ROOT/main" && "$WORKTREE_SCRIPT" create --help 2>"$CREATE_HELP_ROOT/help.err")
create_help_code=$?
set -e
assert_eq "$create_help_code" "0" "create --help exits 0"
assert_contains "$create_help_out" "Usage: " "create --help prints usage"
assert_contains "$create_help_out" "--restack" "create --help lists the create-specific options"
assert_path_absent "$CREATE_HELP_ROOT/trees" "create --help creates no worktree tree"

set +e
create_help_short_out=$(cd "$CREATE_HELP_ROOT/main" && "$WORKTREE_SCRIPT" create -h 2>"$CREATE_HELP_ROOT/help-short.err")
create_help_short_code=$?
set -e
assert_eq "$create_help_short_code" "0" "create -h exits 0"
assert_contains "$create_help_short_out" "Usage: " "create -h prints usage"
assert_path_absent "$CREATE_HELP_ROOT/trees" "create -h creates no worktree tree"

# Parse site 1: an option-looking first positional ($2) must fail, not become
# the ISSUE and a trees/<id> path.
set +e
create_optid_out=$(cd "$CREATE_HELP_ROOT/main" && "$WORKTREE_SCRIPT" create --bogus 2>"$CREATE_HELP_ROOT/optid.err")
create_optid_code=$?
set -e
assert_eq "$create_optid_code" "1" "create --bogus (option-looking issue ID) exits nonzero"
assert_contains "$(cat "$CREATE_HELP_ROOT/optid.err")" "unknown option '--bogus'" "option-looking issue ID reports unknown option"
assert_path_absent "$CREATE_HELP_ROOT/trees/--bogus" "option-looking issue ID never computes a trees/--bogus path"

# Parse site 2: an unknown --flag in the option loop must fail, not be silently
# captured as a branch name.
set +e
create_flag_out=$(cd "$CREATE_HELP_ROOT/main" && "$WORKTREE_SCRIPT" create issue-flagcheck --bogus 2>"$CREATE_HELP_ROOT/flag.err")
create_flag_code=$?
set -e
assert_eq "$create_flag_code" "1" "create <id> --bogus exits nonzero"
assert_contains "$(cat "$CREATE_HELP_ROOT/flag.err")" "unknown option '--bogus'" "unknown flag in the option loop reports unknown option"
assert_path_absent "$CREATE_HELP_ROOT/trees/issue-flagcheck" "unknown flag creates no worktree"
assert_branch_absent "$CREATE_HELP_ROOT/main" "issue-flagcheck" "unknown flag creates no branch"

# Over-rejection guard: a legitimate positional branch name (not leading with
# '-') must STILL be accepted alongside the issue ID.
create_branch_out=$(cd "$CREATE_HELP_ROOT/main" && "$WORKTREE_SCRIPT" create issue-legit custom-branch-name)
assert_eq "$create_branch_out" "$CREATE_HELP_ROOT/trees/issue-legit" "create <id> <branch> returns the worktree path"
assert_path_exists "$CREATE_HELP_ROOT/trees/issue-legit/.git" "create <id> <branch> registers the worktree"
assert_eq "$(git -C "$CREATE_HELP_ROOT/trees/issue-legit" branch --show-current)" "custom-branch-name" "create <id> <branch> uses the positional branch name"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
