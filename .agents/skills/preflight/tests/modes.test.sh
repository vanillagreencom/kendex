#!/usr/bin/env bash
# Scope pins. Each mode decides which lines the line-scoped lanes may speak
# about, so a mode that quietly widens or narrows its diff would either fail
# innocent changes or wave real ones through. Environment failures (bad flag,
# no repository, unresolvable base) must exit 2 — distinct from a clean run
# and from a run with findings.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
PF="$SKILL_DIR/scripts/preflight"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok() {
  PASS=$((PASS + 1))
  printf '  ok    %s\n' "$1"
}
bad() {
  FAIL=$((FAIL + 1))
  printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"
}

seed() { # NAME — fixture in $R: committed baseline, origin/main, feature branch
  R="$TMP/$1"
  mkdir -p "$R/docs"
  git -C "$R" -c init.defaultBranch=main init -q
  git -C "$R" config user.email test@example.com
  git -C "$R" config user.name test
  printf '# Staged\n' >"$R/docs/staged.md"
  printf '# Loose\n' >"$R/docs/loose.md"
  printf '# Legacy\n\nTODO: ancient and unreferenced.\n' >"$R/docs/legacy.md"
  git -C "$R" add -A
  git -C "$R" commit -qm init
  git clone -q --bare "$R" "$R.git"
  git -C "$R" remote add origin "$R.git"
  git -C "$R" fetch -q origin
  git -C "$R" remote set-head origin main >/dev/null
  git -C "$R" checkout -qb feature
}

run_pf() {
  OUT=""
  RC=0
  OUT="$(cd "$R" && "$PF" "$@" 2>&1)" || RC=$?
}
has() { case "$OUT" in *"$1"*) return 0 ;; esac; return 1; }

echo "=== --staged sees the index, not the worktree ==="
seed staged
printf '# Staged\n\nTODO: staged and unreferenced.\n' >"$R/docs/staged.md"
git -C "$R" add docs/staged.md
printf '# Loose\n\nTODO: never staged.\n' >"$R/docs/loose.md"
run_pf --staged
if [ "$RC" -eq 1 ] && has "docs/staged.md:3: [todo-links]" && ! has "docs/loose.md"; then
  ok "the staged TODO fires and the unstaged one is out of scope"
else
  bad "the staged TODO fires and the unstaged one is out of scope" "rc=$RC out=$OUT"
fi

run_pf
if [ "$RC" -eq 1 ] && has "docs/staged.md:3: [todo-links]" && has "docs/loose.md:3: [todo-links]"; then
  ok "the default scope is base-to-worktree, so it sees both"
else
  bad "the default scope is base-to-worktree, so it sees both" "rc=$RC out=$OUT"
fi

echo "=== --staged reads a lane's policy inputs from the index too ==="
seed stagedpolicy
mkdir -p "$R/tests" "$R/.github/workflows"
printf 'name: ci\non: push\njobs:\n  t:\n    runs-on: ubuntu-latest\n    steps:\n      - run: bash tests/other.test.sh\n' >"$R/.github/workflows/ci.yml"
git -C "$R" add -A
git -C "$R" commit -qm ci
# Staged: a new suite AND the workflow edit that wires it. The worktree copy
# of the workflow is then reverted, so a lane reading the worktree would call
# the staged suite unwired.
printf '#!/usr/bin/env bash\nset -euo pipefail\necho new\n' >"$R/tests/new.test.sh"
printf 'name: ci\non: push\njobs:\n  t:\n    runs-on: ubuntu-latest\n    steps:\n      - run: bash tests/new.test.sh\n' >"$R/.github/workflows/ci.yml"
git -C "$R" add -A
printf 'name: ci\non: push\njobs:\n  t:\n    runs-on: ubuntu-latest\n    steps:\n      - run: bash tests/other.test.sh\n' >"$R/.github/workflows/ci.yml"
run_pf --staged
if [ "$RC" -eq 0 ] && ! has "unwired-suite"; then
  ok "the staged runner wires the staged suite, whatever the worktree copy says"
else
  bad "the staged runner wires the staged suite, whatever the worktree copy says" "rc=$RC out=$OUT"
fi

# The inverse: only the worktree copy names it. The staged runner does not,
# so the staged suite is unwired.
printf '#!/usr/bin/env bash\nset -euo pipefail\necho new2\n' >"$R/tests/new2.test.sh"
git -C "$R" add tests/new2.test.sh
printf 'name: ci\non: push\njobs:\n  t:\n    runs-on: ubuntu-latest\n    steps:\n      - run: bash tests/new2.test.sh\n' >"$R/.github/workflows/ci.yml"
run_pf --staged
if [ "$RC" -eq 1 ] && has "tests/new2.test.sh:0: [unwired-suite]"; then
  ok "a worktree-only mention does not wire a staged suite"
else
  bad "a worktree-only mention does not wire a staged suite" "rc=$RC out=$OUT"
fi

echo "=== untracked files are new files in the default scope, invisible to --staged ==="
seed untracked
printf '# Never added\n\nTODO: untracked and unreferenced.\n' >"$R/docs/never-added.md"
mkdir -p "$R/scratch"
printf 'scratch/\n' >"$R/.gitignore"
printf '# Ignored\n\nTODO: ignored and unreferenced.\n' >"$R/scratch/ignored.md"
run_pf
if [ "$RC" -eq 1 ] && has "docs/never-added.md:3: [todo-links]" && ! has "scratch/ignored.md"; then
  ok "a non-ignored untracked file is in scope; an ignored one is not"
else
  bad "a non-ignored untracked file is in scope; an ignored one is not" "rc=$RC out=$OUT"
fi
run_pf --staged
if [ "$RC" -eq 0 ] && ! has "never-added.md"; then
  ok "--staged sees only the index, so the untracked file is out of scope"
else
  bad "--staged sees only the index, so the untracked file is out of scope" "rc=$RC out=$OUT"
fi
# A new doc under a NEW directory is judged as it will be once committed:
# its citation of a missing sibling fires even though nothing tracked lives
# in that directory yet.
seed newdir
mkdir -p "$R/docs/new"
printf '# New\n\nSee `docs/new/missing.md`.\n' >"$R/docs/new/guide.md"
run_pf
if [ "$RC" -eq 1 ] && has "docs/new/guide.md:3: [docs-cited-paths] cites a path that does not exist: docs/new/missing.md"; then
  ok "an untracked doc in an untracked directory has its dead citation reported"
else
  bad "an untracked doc in an untracked directory has its dead citation reported" "rc=$RC out=$OUT"
fi

echo "=== --staged judges staged bytes even when the worktree has moved on ==="
seed rewound
printf '# Staged\n\nTODO: staged and unreferenced.\n' >"$R/docs/staged.md"
git -C "$R" add docs/staged.md
printf '# Staged\n\nAll clean again.\n' >"$R/docs/staged.md" # worktree only
run_pf --staged
if [ "$RC" -eq 1 ] && has "docs/staged.md:3: [todo-links]"; then
  ok "content comes from the index, so line 3 is the staged line"
else
  bad "content comes from the index, so line 3 is the staged line" "rc=$RC out=$OUT"
fi

echo "=== --all treats every tracked line as added ==="
seed everything
run_pf
if [ "$RC" -eq 0 ] && has "preflight: clean (0 changed file(s))"; then
  ok "an untouched branch has nothing in the default scope"
else
  bad "an untouched branch has nothing in the default scope" "rc=$RC out=$OUT"
fi
run_pf --all
if [ "$RC" -eq 1 ] && has "docs/legacy.md:3: [todo-links]" && has "changed file(s)"; then
  ok "--all reaches the committed violation the default scope ignores"
else
  bad "--all reaches the committed violation the default scope ignores" "rc=$RC out=$OUT"
fi

echo "=== --base picks the comparison point ==="
seed based
printf '# Loose\n\nTODO: added in this commit.\n' >"$R/docs/loose.md"
git -C "$R" add -A
git -C "$R" commit -qm "add a todo"
run_pf --base main
if [ "$RC" -eq 1 ] && has "docs/loose.md:3: [todo-links]"; then
  ok "--base main sees the commit made on the branch"
else
  bad "--base main sees the commit made on the branch" "rc=$RC out=$OUT"
fi
run_pf --base HEAD
if [ "$RC" -eq 0 ] && has "preflight: clean"; then
  ok "--base HEAD compares against itself and finds nothing"
else
  bad "--base HEAD compares against itself and finds nothing" "rc=$RC out=$OUT"
fi

echo "=== --repo runs against a repository the caller is not standing in ==="
OUT=""
RC=0
OUT="$(cd "$TMP" && "$PF" --repo "$R" --base main 2>&1)" || RC=$?
if [ "$RC" -eq 1 ] && has "docs/loose.md:3: [todo-links]"; then
  ok "--repo relocates the run without a cd"
else
  bad "--repo relocates the run without a cd" "rc=$RC out=$OUT"
fi

echo "=== environment failures exit 2, never 0 or 1 ==="
run_pf --nonsense
if [ "$RC" -eq 2 ] && has "unknown argument"; then
  ok "an unknown flag is a usage error"
else
  bad "an unknown flag is a usage error" "rc=$RC out=$OUT"
fi

run_pf --base does-not-exist
if [ "$RC" -eq 2 ] && has "does not resolve to a commit"; then
  ok "a --base ref that resolves to nothing is an environment error"
else
  bad "a --base ref that resolves to nothing is an environment error" "rc=$RC out=$OUT"
fi

mkdir -p "$TMP/not-a-repo"
OUT=""
RC=0
OUT="$("$PF" --repo "$TMP/not-a-repo" 2>&1)" || RC=$?
if [ "$RC" -eq 2 ] && has "not inside a git repository"; then
  ok "a path outside any repository is an environment error"
else
  bad "a path outside any repository is an environment error" "rc=$RC out=$OUT"
fi

OUT=""
RC=0
OUT="$("$PF" --repo "$TMP/no-such-directory" 2>&1)" || RC=$?
if [ "$RC" -eq 2 ] && has "--repo path is not a directory"; then
  ok "a --repo path that does not exist is an environment error"
else
  bad "a --repo path that does not exist is an environment error" "rc=$RC out=$OUT"
fi

echo "=== the default base walks origin/HEAD, then origin/main, then main ==="
seed defaulted
printf '# Loose\n\nTODO: unreferenced.\n' >"$R/docs/loose.md"
git -C "$R" add -A
run_pf
if [ "$RC" -eq 1 ] && has "docs/loose.md:3: [todo-links]"; then
  ok "origin/HEAD names the default branch"
else
  bad "origin/HEAD names the default branch" "rc=$RC out=$OUT"
fi

git -C "$R" remote set-head origin --delete >/dev/null
run_pf
if [ "$RC" -eq 1 ] && has "docs/loose.md:3: [todo-links]"; then
  ok "a repository whose origin/HEAD was never set falls back to origin/main"
else
  bad "a repository whose origin/HEAD was never set falls back to origin/main" "rc=$RC out=$OUT"
fi

git -C "$R" update-ref -d refs/remotes/origin/main
run_pf
if [ "$RC" -eq 1 ] && has "docs/loose.md:3: [todo-links]"; then
  ok "with no remote-tracking refs left, the local main branch is the last fallback"
else
  bad "with no remote-tracking refs left, the local main branch is the last fallback" "rc=$RC out=$OUT"
fi

git -C "$R" branch -q -D main
run_pf
if [ "$RC" -eq 2 ] && has "could not resolve a default diff base"; then
  ok "with nothing left to compare against, the run fails closed instead of reporting clean"
else
  bad "with nothing left to compare against, the run fails closed instead of reporting clean" "rc=$RC out=$OUT"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
