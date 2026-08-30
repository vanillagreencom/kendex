#!/usr/bin/env bash
# Regression tests for `worktree push` auto-rebase behavior.
#
# Core regression (kendex#515): a feature branch that already contains
# origin/<default> as an ancestor (e.g. it merged the latest main) must NOT be
# rebased before push. A plain rebase flattens the merge commit and re-replays
# the merged edits, reintroducing conflicts the merge already resolved, which
# aborts the push. The fix guards both rebase sites with
# `merge-base --is-ancestor origin/<default> HEAD` and skips the rebase when the
# base is already contained. Rebase must still run when the branch is genuinely
# behind (does not contain the base as an ancestor).
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Default to the real script; allow override so the pre-fix regression can be
# demonstrated against a temporarily-reverted copy.
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

assert_not_contains() {
  local haystack="$1" needle="$2" name="$3"
  if grep -qF -- "$needle" <<<"$haystack"; then
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        unwanted substring present: %s\n        in: %s\n' "$name" "$needle" "$haystack"
  else
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
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
    printf '  FAIL  %s\n        still exists: %s\n' "$name" "$path"
  fi
}

assert_is_ancestor() {
  local repo="$1" ancestor="$2" descendant="$3" name="$4"
  if git -C "$repo" merge-base --is-ancestor "$ancestor" "$descendant"; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        %s is not an ancestor of %s\n' "$name" "$ancestor" "$descendant"
  fi
}

make_repo() {
  local repo="$1"
  mkdir -p "$repo"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config user.name Test
  git -C "$repo" config commit.gpgsign false
  printf 'orig\n' > "$repo/f"
  git -C "$repo" add f
  git -C "$repo" commit -q -m base
}

echo "=== worktree push auto-rebase ==="

# --- Core regression (kendex#515) ---------------------------------------------
# Feature branch merged origin/main and resolved a same-line conflict, so it
# already contains origin/main as an ancestor. A plain rebase would re-replay
# the feature edit onto main-edit and conflict. push must skip the rebase and
# publish the merge commit unchanged.
ANCESTOR_ROOT="$TMP_ROOT/already-ancestor"
make_repo "$ANCESTOR_ROOT/main"
git init -q --bare "$ANCESTOR_ROOT/origin.git"
git -C "$ANCESTOR_ROOT/main" remote add origin "$ANCESTOR_ROOT/origin.git"
git -C "$ANCESTOR_ROOT/main" push -q -u origin main
git -C "$ANCESTOR_ROOT/main" worktree add -q -b issue-ancestor "$ANCESTOR_ROOT/trees/issue-ancestor" main
# Feature edits the shared line.
printf 'feature\n' > "$ANCESTOR_ROOT/trees/issue-ancestor/f"
git -C "$ANCESTOR_ROOT/trees/issue-ancestor" add f
git -C "$ANCESTOR_ROOT/trees/issue-ancestor" commit -q -m 'feature edit'
# main edits the same line differently and advances origin.
printf 'main-side\n' > "$ANCESTOR_ROOT/main/f"
git -C "$ANCESTOR_ROOT/main" add f
git -C "$ANCESTOR_ROOT/main" commit -q -m 'main edit'
git -C "$ANCESTOR_ROOT/main" push -q origin main
# Feature merges origin/main and resolves the conflict — now it contains
# origin/main as an ancestor, and a plain rebase WOULD conflict.
git -C "$ANCESTOR_ROOT/trees/issue-ancestor" fetch -q origin
git -C "$ANCESTOR_ROOT/trees/issue-ancestor" merge origin/main >/dev/null 2>&1 || true
printf 'merged\n' > "$ANCESTOR_ROOT/trees/issue-ancestor/f"
git -C "$ANCESTOR_ROOT/trees/issue-ancestor" add f
git -C "$ANCESTOR_ROOT/trees/issue-ancestor" commit -q -m 'merge origin/main'
ancestor_pre_head="$(git -C "$ANCESTOR_ROOT/trees/issue-ancestor" rev-parse HEAD)"
set +e
(
  cd "$ANCESTOR_ROOT/main" && \
    "$WORKTREE_SCRIPT" push "$ANCESTOR_ROOT/trees/issue-ancestor" --set-upstream \
      >"$ANCESTOR_ROOT/push.out" 2>"$ANCESTOR_ROOT/push.err"
)
ancestor_code=$?
set -e
ancestor_post_head="$(git -C "$ANCESTOR_ROOT/trees/issue-ancestor" rev-parse HEAD)"
assert_eq "$ancestor_code" "0" "push succeeds when origin/main already merged into branch"
assert_not_contains "$(cat "$ANCESTOR_ROOT/push.err")" "Rebase onto origin/main failed" "push does not hit the spurious rebase-conflict error"
assert_contains "$(cat "$ANCESTOR_ROOT/push.err")" "skipping rebase" "push reports it skipped the unnecessary rebase"
assert_eq "$ancestor_post_head" "$ancestor_pre_head" "HEAD is unchanged (no rebase happened)"
assert_eq "$(git --git-dir="$ANCESTOR_ROOT/origin.git" rev-parse refs/heads/issue-ancestor)" "$ancestor_pre_head" "feature branch lands on remote at the merge commit"
assert_not_contains "$(cat "$ANCESTOR_ROOT/push.out")" "rebase-map:" "skipped rebase emits no rebase-map lines"

# --- Rebase still happens when genuinely behind -------------------------------
# Feature does NOT contain origin/main as an ancestor (main advanced after the
# branch point) and there are no conflicts. push must rebase and fast-forward
# the base before pushing, proving the skip only triggers on the ancestor case.
BEHIND_ROOT="$TMP_ROOT/behind"
make_repo "$BEHIND_ROOT/main"
git init -q --bare "$BEHIND_ROOT/origin.git"
git -C "$BEHIND_ROOT/main" remote add origin "$BEHIND_ROOT/origin.git"
git -C "$BEHIND_ROOT/main" push -q -u origin main
git -C "$BEHIND_ROOT/main" worktree add -q -b issue-behind "$BEHIND_ROOT/trees/issue-behind" main
# main advances on an unrelated file and pushes.
printf 'advanced\n' > "$BEHIND_ROOT/main/main-advanced.txt"
git -C "$BEHIND_ROOT/main" add main-advanced.txt
git -C "$BEHIND_ROOT/main" commit -q -m 'advance main'
git -C "$BEHIND_ROOT/main" push -q origin main
# Feature adds its own (non-conflicting) files on the old base — two commits,
# so the kendex#728 rebase map must pair each rewritten commit by position.
printf 'fix\n' > "$BEHIND_ROOT/trees/issue-behind/fix.txt"
git -C "$BEHIND_ROOT/trees/issue-behind" add fix.txt
git -C "$BEHIND_ROOT/trees/issue-behind" commit -q -m 'review fix'
printf 'fix2\n' > "$BEHIND_ROOT/trees/issue-behind/fix2.txt"
git -C "$BEHIND_ROOT/trees/issue-behind" add fix2.txt
git -C "$BEHIND_ROOT/trees/issue-behind" commit -q -m 'second review fix'
git -C "$BEHIND_ROOT/trees/issue-behind" fetch -q origin
# Precondition: branch does NOT yet contain the advanced origin/main.
set +e
git -C "$BEHIND_ROOT/trees/issue-behind" merge-base --is-ancestor origin/main HEAD
behind_precond=$?
set -e
assert_eq "$behind_precond" "1" "behind branch does not contain origin/main before push"
behind_pre_head="$(git -C "$BEHIND_ROOT/trees/issue-behind" rev-parse HEAD)"
behind_pre_c1="$(git -C "$BEHIND_ROOT/trees/issue-behind" rev-parse HEAD~1)"
behind_pre_c2="$behind_pre_head"
set +e
(
  cd "$BEHIND_ROOT/main" && \
    "$WORKTREE_SCRIPT" push "$BEHIND_ROOT/trees/issue-behind" --set-upstream \
      >"$BEHIND_ROOT/push.out" 2>"$BEHIND_ROOT/push.err"
)
behind_code=$?
set -e
behind_post_head="$(git -C "$BEHIND_ROOT/trees/issue-behind" rev-parse HEAD)"
assert_eq "$behind_code" "0" "push succeeds for a genuinely-behind branch"
assert_ne "$behind_post_head" "$behind_pre_head" "rebase rewrote HEAD (rebase actually ran)"
assert_path_exists "$BEHIND_ROOT/trees/issue-behind/main-advanced.txt" "rebase moved the base onto advanced origin/main"
assert_is_ancestor "$BEHIND_ROOT/trees/issue-behind" origin/main HEAD "origin/main is contained after rebase"
assert_eq "$(git --git-dir="$BEHIND_ROOT/origin.git" rev-parse refs/heads/issue-behind)" "$behind_post_head" "remote branch matches rebased local head"

# --- kendex#728: the rebase prints an old→new commit map -----------------------
# Both branch commits were rewritten; push stdout must carry one
# `rebase-map: <old-sha> <new-sha>` line per commit, paired by position.
behind_post_c1="$(git -C "$BEHIND_ROOT/trees/issue-behind" rev-parse HEAD~1)"
behind_post_c2="$behind_post_head"
behind_push_out="$(cat "$BEHIND_ROOT/push.out")"
assert_contains "$behind_push_out" "rebase-map: $behind_pre_c1 $behind_post_c1" "rebase map pairs the first rewritten commit"
assert_contains "$behind_push_out" "rebase-map: $behind_pre_c2 $behind_post_c2" "rebase map pairs the second rewritten commit"
assert_eq "$(grep -c '^rebase-map: ' <<<"$behind_push_out")" "2" "rebase map emits exactly one line per rewritten commit"
assert_contains "$(cat "$BEHIND_ROOT/push.err")" "rebase-map lines follow (kendex#728)" "rebase map announces itself on stderr"

# --- --no-rebase skips the rebase (unchanged behavior) ------------------------
# A behind branch pushed with --no-rebase must not be rebased: HEAD stays put
# and the advanced main file is absent from the worktree.
NOREBASE_ROOT="$TMP_ROOT/no-rebase"
make_repo "$NOREBASE_ROOT/main"
git init -q --bare "$NOREBASE_ROOT/origin.git"
git -C "$NOREBASE_ROOT/main" remote add origin "$NOREBASE_ROOT/origin.git"
git -C "$NOREBASE_ROOT/main" push -q -u origin main
git -C "$NOREBASE_ROOT/main" worktree add -q -b issue-norebase "$NOREBASE_ROOT/trees/issue-norebase" main
printf 'advanced\n' > "$NOREBASE_ROOT/main/main-advanced.txt"
git -C "$NOREBASE_ROOT/main" add main-advanced.txt
git -C "$NOREBASE_ROOT/main" commit -q -m 'advance main'
git -C "$NOREBASE_ROOT/main" push -q origin main
printf 'fix\n' > "$NOREBASE_ROOT/trees/issue-norebase/fix.txt"
git -C "$NOREBASE_ROOT/trees/issue-norebase" add fix.txt
git -C "$NOREBASE_ROOT/trees/issue-norebase" commit -q -m 'review fix'
norebase_pre_head="$(git -C "$NOREBASE_ROOT/trees/issue-norebase" rev-parse HEAD)"
set +e
(
  cd "$NOREBASE_ROOT/main" && \
    "$WORKTREE_SCRIPT" push "$NOREBASE_ROOT/trees/issue-norebase" --set-upstream --no-rebase \
      >"$NOREBASE_ROOT/push.out" 2>"$NOREBASE_ROOT/push.err"
)
norebase_code=$?
set -e
norebase_post_head="$(git -C "$NOREBASE_ROOT/trees/issue-norebase" rev-parse HEAD)"
assert_eq "$norebase_code" "0" "--no-rebase push succeeds"
assert_eq "$norebase_post_head" "$norebase_pre_head" "--no-rebase leaves HEAD unchanged"
assert_path_absent "$NOREBASE_ROOT/trees/issue-norebase/main-advanced.txt" "--no-rebase does not pull in advanced main"
assert_not_contains "$(cat "$NOREBASE_ROOT/push.out")" "rebase-map:" "--no-rebase emits no rebase-map lines"

# --- KEN-570: push rejects unknown flags --------------------------------------
# The argument loop used to end in a catch-all shift, so a typo'd flag was
# dropped and the caller got a default-behavior push it never asked for. An
# unrecognized flag must now be a usage error, which is what lets orch's
# worktree-push wrapper pass flags through instead of keeping its own copy of
# this vocabulary.
run_push_args() {
  local label="$1"
  shift
  set +e
  (
    cd "$NOREBASE_ROOT/main" && \
      "$WORKTREE_SCRIPT" push "$@" \
        >"$NOREBASE_ROOT/$label.out" 2>"$NOREBASE_ROOT/$label.err"
  )
  PUSH_ARGS_RC=$?
  set -e
}

typo_pre_head="$(git -C "$NOREBASE_ROOT/trees/issue-norebase" rev-parse HEAD)"
run_push_args typo "$NOREBASE_ROOT/trees/issue-norebase" --no-rebse
assert_eq "$PUSH_ARGS_RC" "1" "a typo'd flag is a usage error, not a silent default push"
assert_contains "$(cat "$NOREBASE_ROOT/typo.err")" "unknown option '--no-rebse' for push" "the rejected flag is named"
assert_eq "$(git -C "$NOREBASE_ROOT/trees/issue-norebase" rev-parse HEAD)" "$typo_pre_head" "a rejected flag pushes and rebases nothing"

# The known flags still parse ahead of the positional, so a flag-first call is
# not mistaken for an issue ID. Exit 0 alone proves nothing here: dropping the
# positional falls back to $PWD, the main checkout, whose push also succeeds.
# The branch must arrive on the remote at the named tree's head, which only
# happens if the trailing positional became the target.
FLAGFIRST_ROOT="$TMP_ROOT/flag-first"
make_repo "$FLAGFIRST_ROOT/main"
git init -q --bare "$FLAGFIRST_ROOT/origin.git"
git -C "$FLAGFIRST_ROOT/main" remote add origin "$FLAGFIRST_ROOT/origin.git"
git -C "$FLAGFIRST_ROOT/main" push -q -u origin main
git -C "$FLAGFIRST_ROOT/main" worktree add -q -b issue-flagfirst "$FLAGFIRST_ROOT/trees/issue-flagfirst" main
printf 'advanced\n' > "$FLAGFIRST_ROOT/main/main-advanced.txt"
git -C "$FLAGFIRST_ROOT/main" add main-advanced.txt
git -C "$FLAGFIRST_ROOT/main" commit -q -m 'advance main'
git -C "$FLAGFIRST_ROOT/main" push -q origin main
printf 'fix\n' > "$FLAGFIRST_ROOT/trees/issue-flagfirst/fix.txt"
git -C "$FLAGFIRST_ROOT/trees/issue-flagfirst" add fix.txt
git -C "$FLAGFIRST_ROOT/trees/issue-flagfirst" commit -q -m 'flag-first fix'
flagfirst_pre_head="$(git -C "$FLAGFIRST_ROOT/trees/issue-flagfirst" rev-parse HEAD)"
set +e
(
  cd "$FLAGFIRST_ROOT/main" && \
    "$WORKTREE_SCRIPT" push --no-rebase --set-upstream "$FLAGFIRST_ROOT/trees/issue-flagfirst" \
      >"$FLAGFIRST_ROOT/push.out" 2>"$FLAGFIRST_ROOT/push.err"
)
flagfirst_code=$?
set -e
assert_eq "$flagfirst_code" "0" "flags may precede the ID or path"
assert_eq "$(git --git-dir="$FLAGFIRST_ROOT/origin.git" rev-parse refs/heads/issue-flagfirst)" "$flagfirst_pre_head" "the trailing positional is the pushed target, not \$PWD"
assert_eq "$(git -C "$FLAGFIRST_ROOT/trees/issue-flagfirst" rev-parse HEAD)" "$flagfirst_pre_head" "the flag-first --no-rebase left HEAD unchanged"
assert_path_absent "$FLAGFIRST_ROOT/trees/issue-flagfirst/main-advanced.txt" "the flag-first --no-rebase did not pull in advanced main"

# The rejection arm shares its loop with --help, and the error it prints
# advertises `push --help` as the recovery. That the global pre-scan answers
# --help before this case is what keeps the advice true; nothing else here
# holds it.
run_push_args help --help
assert_eq "$PUSH_ARGS_RC" "0" "the advertised recovery command still exits 0"
assert_contains "$(cat "$NOREBASE_ROOT/help.out")" "Usage: worktree push" "push --help prints the push usage"

run_push_args twoargs "$NOREBASE_ROOT/trees/issue-norebase" issue-norebase
assert_eq "$PUSH_ARGS_RC" "1" "a second positional is a usage error"
assert_contains "$(cat "$NOREBASE_ROOT/twoargs.err")" "takes a single issue ID or path" "the duplicate positional is reported"

# An EMPTY positional is not "no target": resolution would fall back to $PWD
# and push the current checkout — the unintended default push this parser
# exists to prevent, one unset caller variable away. Seen-ness is tracked
# apart from the value, so an empty first argument still counts against the
# single-target rule.
empty_pre_head="$(git -C "$NOREBASE_ROOT/trees/issue-norebase" rev-parse HEAD)"
run_push_args emptyarg ""
assert_eq "$PUSH_ARGS_RC" "1" "an empty positional is a usage error, not a fallback to \$PWD"
assert_contains "$(cat "$NOREBASE_ROOT/emptyarg.err")" "push target is empty" "the empty target is reported"

run_push_args emptythenreal "" "$NOREBASE_ROOT/trees/issue-norebase"
assert_eq "$PUSH_ARGS_RC" "1" "an empty positional followed by a real one is still refused"

run_push_args realthenempty "$NOREBASE_ROOT/trees/issue-norebase" ""
assert_eq "$PUSH_ARGS_RC" "1" "a real positional followed by an empty one is a duplicate, not a silent second target"
assert_contains "$(cat "$NOREBASE_ROOT/realthenempty.err")" "takes a single issue ID or path" "the empty second positional is reported as a duplicate"
assert_eq "$(git -C "$NOREBASE_ROOT/trees/issue-norebase" rev-parse HEAD)" "$empty_pre_head" "an empty-target refusal pushes and rebases nothing"

# --- kendex#728: a commit dropped by the rebase maps to "dropped" --------------
# The branch carries a commit whose patch main already merged (different SHA,
# same patch-id) plus its own fix. The rebase drops the duplicated commit, so
# pre/post counts differ and the map must pair by subject: the surviving commit
# maps old→new, the vanished one maps old→dropped.
DROP_ROOT="$TMP_ROOT/dropped"
make_repo "$DROP_ROOT/main"
git init -q --bare "$DROP_ROOT/origin.git"
git -C "$DROP_ROOT/main" remote add origin "$DROP_ROOT/origin.git"
git -C "$DROP_ROOT/main" push -q -u origin main
git -C "$DROP_ROOT/main" worktree add -q -b issue-dropped "$DROP_ROOT/trees/issue-dropped" main
# Branch commit 1: the patch main will independently merge.
printf 'dup\n' > "$DROP_ROOT/trees/issue-dropped/dup.txt"
git -C "$DROP_ROOT/trees/issue-dropped" add dup.txt
git -C "$DROP_ROOT/trees/issue-dropped" commit -q -m 'duplicated change'
# Branch commit 2: the branch's own fix.
printf 'fix\n' > "$DROP_ROOT/trees/issue-dropped/fix.txt"
git -C "$DROP_ROOT/trees/issue-dropped" add fix.txt
git -C "$DROP_ROOT/trees/issue-dropped" commit -q -m 'review fix'
# main lands the same patch under another subject and advances origin.
printf 'dup\n' > "$DROP_ROOT/main/dup.txt"
git -C "$DROP_ROOT/main" add dup.txt
git -C "$DROP_ROOT/main" commit -q -m 'main landed the dup patch'
git -C "$DROP_ROOT/main" push -q origin main
drop_pre_c1="$(git -C "$DROP_ROOT/trees/issue-dropped" rev-parse HEAD~1)"
drop_pre_c2="$(git -C "$DROP_ROOT/trees/issue-dropped" rev-parse HEAD)"
set +e
(
  cd "$DROP_ROOT/main" && \
    "$WORKTREE_SCRIPT" push "$DROP_ROOT/trees/issue-dropped" --set-upstream \
      >"$DROP_ROOT/push.out" 2>"$DROP_ROOT/push.err"
)
drop_code=$?
set -e
drop_post_head="$(git -C "$DROP_ROOT/trees/issue-dropped" rev-parse HEAD)"
drop_push_out="$(cat "$DROP_ROOT/push.out")"
assert_eq "$drop_code" "0" "push succeeds when the rebase drops a duplicated commit"
assert_eq "$(git -C "$DROP_ROOT/trees/issue-dropped" rev-list --count origin/main..HEAD)" "1" "rebase dropped the duplicated commit"
assert_contains "$drop_push_out" "rebase-map: $drop_pre_c1 dropped" "rebase map reports the vanished commit as dropped"
assert_contains "$drop_push_out" "rebase-map: $drop_pre_c2 $drop_post_head" "rebase map pairs the surviving commit by subject"
assert_eq "$(grep -c '^rebase-map: ' <<<"$drop_push_out")" "2" "dropped-commit rebase map covers both pre-rebase commits"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
