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
#   * gh's stderr chatter never becomes part of the answer, and chatter on
#     stdout is an unreadable answer rather than a row that did not match;
#   * a worktree cleanup can prove nothing about — detached HEAD, or a branch
#     whose ref is gone from the main checkout — is named, never passed over,
#     and a listing that fails outright exits nonzero instead of reporting the
#     empty sweep as a clean one;
#   * `remove` distinguishes a lookup that could not answer from a branch
#     proven unmerged, because one is a retry and the other is a decision;
#   * a branch whose tip is NOT the head the pull request merged is kept, with
#     its follow-up commits and uncommitted files intact. One branch name serves
#     every worktree an issue ever had, so matching on the name alone handed an
#     old merged record to new work and force-deleted it;
#   * a pull request merged into some other base is not a merge into the
#     default branch, so it collects nothing; nor is a fork's pull request,
#     nor an answer from whatever repository a GH_REPO redirect points at;
#   * `remove` deletes a squash-merged branch and still keeps an unmerged one,
#     a moved-on one, and one merged only into its own tracking upstream —
#     `git branch -d` accepted that last case and no longer decides anything.
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

# `gh pr list --state merged --head <branch> --base <default>` answers from
# GH_MERGED_PRS, a newline-separated "<branch> <base> <head-oid> <number>
# <cross-repo 0|1>" table, printed back in the
# `--jq '.[] | "\(.headRefOid) \(.number)"'` shape the script asks for.
#
# The stub honours every filter, because each one guards a forced delete: the
# oid column makes a name-only match visible, a row is answered only when the
# query asked for merged pull requests on the base it names, a cross-repository
# row is answered only when the query did not ask to exclude them, and a query
# carrying a GH_REPO redirect is answered for that OTHER repository. Dropping
# any of them from the implementation has to fail a scenario here.
#
# GH_FAIL=1 makes the query fail the way a network or auth error does.
# GH_STDERR_NOISE=1 prints gh's routine chatter on stderr beside a good answer.
# GH_NOISE=1 puts that chatter on STDOUT, where it contaminates the answer.
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
if [[ "${GH_STDERR_NOISE:-0}" == "1" ]]; then
  echo "A new release of gh is available: 2.40.0 -> 2.63.2" >&2
fi
if [[ "${GH_NOISE:-0}" == "1" ]]; then
  echo "A new release of gh is available: 2.40.0 -> 2.63.2"
fi
branch=""
base=""
state=""
jq_expr=""
json_fields=""
prev=""
for arg in "$@"; do
  case "$prev" in
    --head) branch="$arg" ;;
    --base) base="$arg" ;;
    --state) state="$arg" ;;
    --json) json_fields="$arg" ;;
    --jq) jq_expr="$arg" ;;
  esac
  prev="$arg"
done
# An unfiltered query is not the query under test: answer nothing rather than
# letting a scenario pass on a filter the implementation stopped sending.
[[ "$state" == "merged" ]] || exit 0
# A redirected query answers for the repository it was pointed at, not this
# checkout. GH_REDIRECT_OID is that other repository's same-named branch.
if [[ -n "${GH_REPO:-}${GITHUB_REPOSITORY:-}" ]]; then
  printf '%s %s\n' "${GH_REDIRECT_OID:-0000000}" 999
  exit 0
fi
excludes_forks=0
case "$json_fields:$jq_expr" in
  *isCrossRepository*:*isCrossRepository*) excludes_forks=1 ;;
esac
while read -r want want_base oid number cross; do
  [[ -n "$want" ]] || continue
  [[ "$want" == "$branch" ]] || continue
  [[ -z "$base" || "$want_base" == "$base" ]] || continue
  [[ "$excludes_forks" == 1 && "${cross:-0}" == 1 ]] && continue
  printf '%s %s\n' "$oid" "$number"
done <<<"${GH_MERGED_PRS:-}"
exit 0
STUB
  chmod +x "$bin/gh"
}

branch_tip() {
  git -C "$1/main" rev-parse --verify "refs/heads/$2"
}

# A git that fails `worktree list` and passes everything else through, for
# driving the enumeration failure. Lives in its own directory so only the
# scenario that prepends it is affected.
make_failing_git_stub() {
  local bin="$1" real_git
  real_git="$(command -v git)"
  mkdir -p "$bin"
  cat >"$bin/git" <<STUB
#!/usr/bin/env bash
set -uo pipefail
prev=""
for arg in "\$@"; do
  if [[ "\$prev" == "worktree" && "\$arg" == "list" ]]; then
    echo "fatal: not a git repository (stubbed failure)" >&2
    exit 128
  fi
  prev="\$arg"
done
exec "$real_git" "\$@"
STUB
  chmod +x "$bin/git"
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

GH_MERGED_PRS="issue-merged main $(branch_tip "$ROOT" issue-merged) 4242"
export GH_MERGED_PRS
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

echo "=== an unreadable answer keeps the worktree ==="

# gh chatter on STDOUT lands in the answer itself. Nothing in a response this
# cannot parse may authorize a delete, so an unreadable row is exit 2, the same
# arm as a failed query — never a row that simply did not match.
noise_out_code=0
noise_out_out=$(cd "$ROOT/main" && GH_NOISE=1 "$WORKTREE_SCRIPT" cleanup 2>"$ROOT/noiseout.err") || noise_out_code=$?
noise_out_err="$(cat "$ROOT/noiseout.err")"

assert_eq "$noise_out_code" "0" "an unreadable answer is a kept worktree, not a cleanup error"
assert_path_exists "$OPEN_TREE" "an unreadable answer never removes the worktree"
assert_contains "$noise_out_err" "gh returned a row this cannot read" \
  "cleanup names the row it could not read"
if grep -qF "Cleaned:" <<<"$noise_out_out"; then
  fail "an unreadable answer collects nothing"
else
  pass "an unreadable answer collects nothing"
fi

echo "=== a missing gh keeps the worktree ==="

# A PATH holding every tool the script reaches for EXCEPT gh. Dropping the real
# PATH wholesale would fail for the wrong reason (no git), and shadowing gh is
# impossible — `command -v` answers from PATH alone. `bash` and `sh` are on the
# list so a shebang resolved through PATH keeps working: this script's is
# absolute today, and a scenario that died at exec would otherwise look like a
# scenario that reached the gh probe.
NOGH_BIN="$ROOT/bin-nogh"
mkdir -p "$NOGH_BIN"
for tool in bash sh git grep sed awk cat cut tr sort uniq wc head tail find ln rm rmdir \
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
# The script must still RUN under that PATH. Without this, an exec failure
# (127) would satisfy every "the worktree survived" assertion below while
# never reaching the code under test.
nogh_runs=0
(cd "$ROOT/main" && PATH="$NOGH_BIN" "$WORKTREE_SCRIPT" --help >/dev/null 2>&1) || nogh_runs=$?
assert_eq "$nogh_runs" "0" "precondition: the script executes under the gh-free PATH"

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

echo "=== a worktree with no branch to prove is named, not passed over ==="

# Detached HEAD is reachable in this tool: a paused restack replay leaves the
# worktree that way (worktree_restack_replay.sh). The arm exists so the help's
# "every skip is reported" holds for a worktree cleanup can prove nothing about.
git -C "$OPEN_TREE" checkout -q --detach
det_code=0
det_out=$(cd "$ROOT/main" && "$WORKTREE_SCRIPT" cleanup 2>"$ROOT/detached.err") || det_code=$?
det_err="$(cat "$ROOT/detached.err")"

assert_eq "$det_code" "0" "cleanup exits 0 with a detached worktree present"
assert_path_exists "$OPEN_TREE" "the detached worktree survives"
assert_contains "$det_err" "no branch checked out" "cleanup names the detached HEAD as the reason"
assert_contains "$det_err" "$OPEN_TREE" "the detached skip names the path"
if grep -qF "Cleaned:" <<<"$det_out"; then
  fail "a detached worktree is collected by nothing"
else
  pass "a detached worktree is collected by nothing"
fi

echo "=== a worktree whose branch ref is gone is named too ==="

git -C "$OPEN_TREE" checkout -q issue-open
git -C "$ROOT/main" update-ref -d refs/heads/issue-open
noref_code=0
noref_out=$(cd "$ROOT/main" && "$WORKTREE_SCRIPT" cleanup 2>"$ROOT/noref.err") || noref_code=$?
noref_err="$(cat "$ROOT/noref.err")"

assert_eq "$noref_code" "0" "cleanup exits 0 with a ref-less worktree present"
assert_path_exists "$OPEN_TREE" "the ref-less worktree survives"
assert_contains "$noref_err" "has no ref in the main checkout" \
  "cleanup names the missing branch ref as the reason"
if grep -qF "Cleaned:" <<<"$noref_out"; then
  fail "a ref-less worktree is collected by nothing"
else
  pass "a ref-less worktree is collected by nothing"
fi

echo "=== gh chatter on stderr does not disable the proof ==="

# gh writes its update notice and auth warnings to stderr. Folded into the
# answer they are read as pull-request rows: a branch with NO merged pull
# request then looks like one whose rows simply did not match, and the skip
# blames the wrong cause. The streams stay separate so the empty answer is
# still empty.
NOISE_ROOT="$TMP_ROOT/noise"
make_repo "$NOISE_ROOT"
add_branch_tree "$NOISE_ROOT" "issue-noise"
add_branch_tree "$NOISE_ROOT" "issue-noise-open"
squash_onto_main "$NOISE_ROOT" "issue-noise"

GH_MERGED_PRS="issue-noise main $(branch_tip "$NOISE_ROOT" issue-noise) 31"
export GH_MERGED_PRS
noise_code=0
noise_out=$(cd "$NOISE_ROOT/main" && GH_STDERR_NOISE=1 \
  "$WORKTREE_SCRIPT" cleanup 2>"$NOISE_ROOT/noise.err") || noise_code=$?
noise_err="$(cat "$NOISE_ROOT/noise.err")"

assert_eq "$noise_code" "0" "cleanup exits 0 with gh chatter on stderr"
assert_contains "$noise_out" "Cleaned: $NOISE_ROOT/trees/issue-noise" \
  "the proof still reads its answer past gh's stderr chatter"
assert_contains "$noise_err" "Skipped (branch 'issue-noise-open' is not merged" \
  "gh chatter is not counted as a pull-request row for a branch that has none"
if grep -qF "could not be determined" <<<"$noise_err"; then
  fail "gh chatter is not mistaken for an unreadable answer"
else
  pass "gh chatter is not mistaken for an unreadable answer"
fi

echo "=== a branch past its merged pull request is kept ==="

# The data-loss case the name-only match allowed. One branch name serves every
# worktree an issue ever had, so a merged record from an earlier PR would match
# a branch whose tip is newer work: cleanup force-removed the tree and ran
# branch -D, leaving the follow-up commit reachable from no ref.
MOVED_ROOT="$TMP_ROOT/moved"
make_repo "$MOVED_ROOT"
add_branch_tree "$MOVED_ROOT" "issue-moved"
MERGED_OID="$(branch_tip "$MOVED_ROOT" issue-moved)"
squash_onto_main "$MOVED_ROOT" "issue-moved"

MOVED_TREE="$MOVED_ROOT/trees/issue-moved"
printf 'follow-up\n' >"$MOVED_TREE/followup.txt"
git -C "$MOVED_TREE" add followup.txt
git -C "$MOVED_TREE" commit -q -m "issue-moved: follow-up work"
FOLLOWUP_OID="$(branch_tip "$MOVED_ROOT" issue-moved)"
printf 'uncommitted\n' >"$MOVED_TREE/scratch.txt"

# The stub still reports the merged PR under this branch NAME, carrying the head
# it actually merged. Only the commit compare can tell the two apart.
export GH_MERGED_PRS="issue-moved main $MERGED_OID 100"
moved_code=0
moved_out=$(cd "$MOVED_ROOT/main" && "$WORKTREE_SCRIPT" cleanup 2>"$MOVED_ROOT/moved.err") || moved_code=$?
moved_err="$(cat "$MOVED_ROOT/moved.err")"

assert_eq "$moved_code" "0" "cleanup exits 0 with a moved-on branch present"
assert_path_exists "$MOVED_TREE" "the worktree with work past the merge survives"
assert_path_exists "$MOVED_TREE/scratch.txt" "the uncommitted file survives"
assert_contains "$moved_err" "is not merged" \
  "an identity mismatch reads as not merged, not as a failed lookup"
assert_contains "$moved_err" "carries work past its merged pull request" \
  "cleanup names the moved-on branch as the reason it kept the worktree"
if grep -qF "Cleaned:" <<<"$moved_out"; then
  fail "cleanup collects nothing when the tip is not the merged head"
else
  pass "cleanup collects nothing when the tip is not the merged head"
fi
if [[ "$(branch_tip "$MOVED_ROOT" issue-moved)" == "$FOLLOWUP_OID" ]]; then
  pass "the follow-up commit is still reachable from the branch"
else
  fail "the follow-up commit is still reachable from the branch"
fi

echo "=== remove keeps a branch past its merged pull request ==="

movedrm_code=0
movedrm_out=$(cd "$MOVED_ROOT/main" && "$WORKTREE_SCRIPT" remove "$MOVED_TREE" 2>"$MOVED_ROOT/movedrm.err") || movedrm_code=$?
movedrm_err="$(cat "$MOVED_ROOT/movedrm.err")"

assert_eq "$movedrm_code" "1" "remove exits nonzero rather than force-deleting a moved-on branch"
assert_contains "$movedrm_err" "carries work past its merged pull request" \
  "remove names the moved-on branch as the reason it kept it"
if [[ "$(branch_tip "$MOVED_ROOT" issue-moved)" == "$FOLLOWUP_OID" ]]; then
  pass "remove leaves the follow-up commit reachable"
else
  fail "remove leaves the follow-up commit reachable"
fi
: "${movedrm_out:=}"

echo "=== remove deletes a squash-merged branch ==="

RM_ROOT="$TMP_ROOT/remove"
make_repo "$RM_ROOT"
add_branch_tree "$RM_ROOT" "issue-rm"
squash_onto_main "$RM_ROOT" "issue-rm"

GH_MERGED_PRS="issue-rm main $(branch_tip "$RM_ROOT" issue-rm) 77"
export GH_MERGED_PRS
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
assert_contains "$keep_err" "Not merged into origin/main, and no pull request merged into main" \
  "remove says which proof failed and how"
if git -C "$RM_ROOT/main" show-ref --verify --quiet refs/heads/issue-keep; then
  pass "remove leaves the unmerged branch alone"
else
  fail "remove leaves the unmerged branch alone"
fi
: "${keep_out:=}"

echo "=== remove keeps a branch merged only into its own upstream ==="

# `git branch -d` deletes a branch merged into its configured UPSTREAM, and
# `worktree push` sets one, so every pushed branch satisfied it however far it
# was from the default branch. It decided nothing here now: the branch goes on
# ancestry into the default branch or on the merged-PR proof, and on nothing
# else.
add_branch_tree "$RM_ROOT" "issue-pushed"
git -C "$RM_ROOT/trees/issue-pushed" push -q -u origin issue-pushed
if git -C "$RM_ROOT/main" merge-base --is-ancestor issue-pushed origin/main; then
  fail "precondition: the pushed branch must NOT be merged into the default branch"
else
  pass "precondition: the pushed branch is not merged into the default branch"
fi
if git -C "$RM_ROOT/main" branch --format='%(refname:short) %(upstream:short)' \
     | grep -qx "issue-pushed origin/issue-pushed"; then
  pass "precondition: the pushed branch tracks an upstream branch -d would accept"
else
  fail "precondition: the pushed branch tracks an upstream branch -d would accept"
fi

pushed_code=0
pushed_out=$(cd "$RM_ROOT/main" && "$WORKTREE_SCRIPT" remove "$RM_ROOT/trees/issue-pushed" 2>"$RM_ROOT/pushed.err") || pushed_code=$?
pushed_err="$(cat "$RM_ROOT/pushed.err")"

assert_eq "$pushed_code" "1" "remove exits nonzero on a branch merged only into its upstream"
assert_contains "$pushed_err" "Remaining branch: issue-pushed" "remove names the branch it kept"
if git -C "$RM_ROOT/main" show-ref --verify --quiet refs/heads/issue-pushed; then
  pass "the branch merged only into its upstream survives remove"
else
  fail "the branch merged only into its upstream survives remove"
fi
: "${pushed_out:=}"

echo "=== a pull request merged into another base does not count ==="

# --base is a guard on a forced delete: work merged into a feature branch has
# not reached the default branch, and its worktree is not collectable.
BASE_ROOT="$TMP_ROOT/otherbase"
make_repo "$BASE_ROOT"
add_branch_tree "$BASE_ROOT" "issue-sidebase"
GH_MERGED_PRS="issue-sidebase feature-x $(branch_tip "$BASE_ROOT" issue-sidebase) 55"
export GH_MERGED_PRS
sidebase_code=0
sidebase_out=$(cd "$BASE_ROOT/main" && "$WORKTREE_SCRIPT" cleanup 2>"$BASE_ROOT/sidebase.err") || sidebase_code=$?
sidebase_err="$(cat "$BASE_ROOT/sidebase.err")"

assert_eq "$sidebase_code" "0" "cleanup exits 0 with a side-base merge present"
assert_path_exists "$BASE_ROOT/trees/issue-sidebase" "a pull request merged elsewhere never collects the worktree"
assert_contains "$sidebase_err" "is not merged" "cleanup names the side-base branch as unmerged"
if grep -qF "Cleaned:" <<<"$sidebase_out"; then
  fail "a pull request merged into another base collects nothing"
else
  pass "a pull request merged into another base collects nothing"
fi

echo "=== a fork's pull request does not vouch for this branch ==="

# A cross-repository pull request is someone else's merge into someone else's
# base. Answering with it would let a fork carrying the same branch name and
# commit authorize a delete here.
FORK_ROOT="$TMP_ROOT/fork"
make_repo "$FORK_ROOT"
add_branch_tree "$FORK_ROOT" "issue-fork"
GH_MERGED_PRS="issue-fork main $(branch_tip "$FORK_ROOT" issue-fork) 61 1"
export GH_MERGED_PRS
fork_code=0
fork_out=$(cd "$FORK_ROOT/main" && "$WORKTREE_SCRIPT" cleanup 2>"$FORK_ROOT/fork.err") || fork_code=$?
fork_err="$(cat "$FORK_ROOT/fork.err")"

assert_eq "$fork_code" "0" "cleanup exits 0 with only a fork's merged pull request"
assert_path_exists "$FORK_ROOT/trees/issue-fork" "a fork's pull request never collects the worktree"
assert_contains "$fork_err" "is not merged" "cleanup names the fork-only branch as unmerged"
if grep -qF "Cleaned:" <<<"$fork_out"; then
  fail "a fork's pull request collects nothing"
else
  pass "a fork's pull request collects nothing"
fi

echo "=== a GH_REPO redirect does not answer for this checkout ==="

# gh reads GH_REPO and GITHUB_REPOSITORY from the environment, and a session
# that inherited either would be asking a DIFFERENT repository whether this
# branch is merged. Another repository's same-named branch at the same commit
# must not authorize a delete here.
REDIR_ROOT="$TMP_ROOT/redirect"
make_repo "$REDIR_ROOT"
add_branch_tree "$REDIR_ROOT" "issue-redirect"
GH_MERGED_PRS=""
export GH_MERGED_PRS
GH_REDIRECT_OID="$(branch_tip "$REDIR_ROOT" issue-redirect)"
export GH_REDIRECT_OID
redir_code=0
redir_out=$(cd "$REDIR_ROOT/main" && GH_REPO="someone-else/other-repo" \
  "$WORKTREE_SCRIPT" cleanup 2>"$REDIR_ROOT/redirect.err") || redir_code=$?
redir_err="$(cat "$REDIR_ROOT/redirect.err")"

assert_eq "$redir_code" "0" "cleanup exits 0 under a GH_REPO redirect"
assert_path_exists "$REDIR_ROOT/trees/issue-redirect" \
  "another repository's merged pull request never collects the worktree"
assert_contains "$redir_err" "is not merged" "cleanup names the branch as unmerged under a redirect"
if grep -qF "Cleaned:" <<<"$redir_out"; then
  fail "a redirected lookup collects nothing"
else
  pass "a redirected lookup collects nothing"
fi
unset GH_REDIRECT_OID

echo "=== a failed enumeration is not a clean sweep ==="

# Process substitution discards the command's exit status, so a failing
# `worktree list` used to leave the candidate set empty and cleanup reported
# success having inspected nothing.
ENUM_ROOT="$TMP_ROOT/enum"
make_repo "$ENUM_ROOT"
add_branch_tree "$ENUM_ROOT" "issue-enum"
make_failing_git_stub "$ENUM_ROOT/failgit"
enum_code=0
enum_out=$(cd "$ENUM_ROOT/main" && PATH="$ENUM_ROOT/failgit:$PATH" \
  "$WORKTREE_SCRIPT" cleanup 2>"$ENUM_ROOT/enum.err") || enum_code=$?
enum_err="$(cat "$ENUM_ROOT/enum.err")"

if [[ "$enum_code" -ne 0 ]]; then
  pass "cleanup exits nonzero when it could not enumerate worktrees"
else
  fail "cleanup exits nonzero when it could not enumerate worktrees (got 0)"
fi
assert_contains "$enum_err" "worktree list --porcelain -z' failed" \
  "cleanup names the enumeration command that failed"
assert_contains "$enum_err" "this is not a clean sweep" \
  "cleanup says the run inspected nothing rather than implying success"
assert_path_exists "$ENUM_ROOT/trees/issue-enum" "a failed enumeration removes nothing"
if grep -qF "Cleaned:" <<<"$enum_out"; then
  fail "a failed enumeration collects nothing"
else
  pass "a failed enumeration collects nothing"
fi

echo "=== remove tells an unanswered lookup apart from a proven-unmerged branch ==="

# The operator has to be able to act on the difference: a branch that is not
# merged is a decision, a lookup that could not run is a retry.
add_branch_tree "$RM_ROOT" "issue-down"
squash_onto_main "$RM_ROOT" "issue-down"
down_code=0
down_out=$(cd "$RM_ROOT/main" && GH_FAIL=1 \
  "$WORKTREE_SCRIPT" remove "$RM_ROOT/trees/issue-down" 2>"$RM_ROOT/down.err") || down_code=$?
down_err="$(cat "$RM_ROOT/down.err")"

assert_eq "$down_code" "1" "remove exits nonzero when the lookup could not answer"
assert_contains "$down_err" "Merged-pull-request lookup could not answer" \
  "remove says the lookup could not answer rather than calling the branch unmerged"
if grep -qF "Not merged into origin/main" <<<"$down_err"; then
  fail "an unanswered lookup is not reported as a proven-unmerged branch"
else
  pass "an unanswered lookup is not reported as a proven-unmerged branch"
fi
if git -C "$RM_ROOT/main" show-ref --verify --quiet refs/heads/issue-down; then
  pass "remove keeps the branch when the lookup could not answer"
else
  fail "remove keeps the branch when the lookup could not answer"
fi
: "${down_out:=}"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
