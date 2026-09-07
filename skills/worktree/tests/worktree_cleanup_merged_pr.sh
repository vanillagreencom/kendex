#!/usr/bin/env bash
# `cleanup` and `remove` against squash-merged branches: one table, a row per
# scenario. A squash merge rewrites the branch into a separate commit, so
# ancestry reports every merged worktree as pending and the forge's merged
# pull request is the only proof left; a lookup that cannot answer is not a
# merge, a pull request merged elsewhere (another base, a fork, a redirected
# repository) is not a merge here, and a branch whose tip is not the head the
# pull request merged is kept with its work.
#
# A row's fixture is a word list of steps building a fresh checkout with an
# issue worktree at trees/topic; the gh column is the answer the stub gives;
# the command runs from the main checkout; the row pins the exit status,
# stdout, stderr whole and what is left (the worktree, its index, the branch
# tip, a second worktree where the row has one).
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
# any of them from the implementation has to fail a row here.
#
# GH_FAIL=1 makes the query fail the way a network or auth error does.
# GH_STDERR_NOISE=1 prints gh's routine chatter on stderr beside a good answer.
# GH_NOISE=1 puts that chatter on STDOUT, where it contaminates the answer.
mkdir -p "$TMP_ROOT/bin"
cat >"$TMP_ROOT/bin/gh" <<'STUB'
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
# letting a row pass on a filter the implementation stopped sending.
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
chmod +x "$TMP_ROOT/bin/gh"
export PATH="$TMP_ROOT/bin:$PATH"

# A git that fails `worktree list` and passes everything else through.
mkdir -p "$TMP_ROOT/failgit"
cat >"$TMP_ROOT/failgit/git" <<STUB
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
exec "$(command -v git)" "\$@"
STUB
chmod +x "$TMP_ROOT/failgit/git"

# A PATH holding every tool the script reaches for EXCEPT gh: shadowing gh is
# impossible, `command -v` answers from PATH alone. bash and sh are on the
# list so a shebang resolved through PATH keeps working.
mkdir -p "$TMP_ROOT/nogh"
for tool in bash sh git grep sed awk cat cut tr sort uniq wc head tail find ln rm rmdir \
            mkdir mv cp ls readlink realpath dirname basename mktemp date id \
            hostname ps kill sleep touch chmod stat printf env flock jq paste; do
  tool_path="$(command -v "$tool" 2>/dev/null || true)"
  [[ -n "$tool_path" ]] && ln -sf "$tool_path" "$TMP_ROOT/nogh/$tool"
done

# --- fixtures -----------------------------------------------------------------

ROOT=""
MAIN=""
WT=""
OTHER=""
TIP=""     # topic's tip at the end of the fixture
MERGED=""  # the tip the squash merge landed, when a later commit moved past it
ROW_PATH=""
ROW_ENV=()

make_repo() {
  mkdir -p "$MAIN"
  git -C "$MAIN" init -q -b main
  git -C "$MAIN" config user.email test@example.com
  git -C "$MAIN" config user.name Test
  git -C "$MAIN" config commit.gpgsign false
  printf 'base\n' >"$MAIN/base.txt"
  git -C "$MAIN" add base.txt
  git -C "$MAIN" commit -q -m base
  printf 'WORKTREE_BASE_DIR="../trees"\n' >"$MAIN/.env.local"
  git init -q --bare "$ROOT/origin.git"
  git -C "$MAIN" remote add origin "$ROOT/origin.git"
  git -C "$MAIN" push -q -u origin main
}

# A branch with one commit of its own, checked out in its own worktree.
# Nothing lands on main, so it is unmerged by both proofs until squashed.
add_branch_tree() {
  local name="$1"
  git -C "$MAIN" worktree add -q -b "$name" "$ROOT/trees/$name" main
  printf '%s\n' "$name" >"$ROOT/trees/$name/$name.txt"
  git -C "$ROOT/trees/$name" add "$name.txt"
  git -C "$ROOT/trees/$name" commit -q -m "$name: work"
}

step() {
  case "$1" in
    tree)
      make_repo
      add_branch_tree topic
      ;;
    # Land the branch's content on main as a separate commit, exactly as a
    # squash merge does: the branch tip stays outside main's history forever.
    squash)
      printf 'topic\n' >"$MAIN/topic.txt"
      git -C "$MAIN" add topic.txt
      git -C "$MAIN" commit -q -m 'topic: work (squashed)'
      git -C "$MAIN" push -q origin main
      MERGED="$(git -C "$MAIN" rev-parse refs/heads/topic)"
      if ! git -C "$MAIN" cat-file -e origin/main:topic.txt; then
        echo "FIXTURE: the squash did not land on origin/main" >&2
        exit 2
      fi
      # Ancestry must genuinely fail, or a row proves nothing about the
      # pull-request lookup: it would pass on the ancestry arm alone.
      if git -C "$MAIN" merge-base --is-ancestor topic origin/main; then
        echo "FIXTURE: the squashed branch is an ancestor of origin/main" >&2
        exit 2
      fi
      ;;
    other) add_branch_tree other; OTHER="$ROOT/trees/other" ;;
    follow-up)
      printf 'follow-up\n' >"$WT/followup.txt"
      git -C "$WT" add followup.txt
      git -C "$WT" commit -q -m 'topic: follow-up work'
      ;;
    scratch) printf 'uncommitted\n' >"$WT/scratch.txt" ;;
    detach) git -C "$WT" checkout -q --detach ;;
    drop-ref) git -C "$MAIN" update-ref -d refs/heads/topic ;;
    # `git branch -d` accepts a branch merged into its configured upstream;
    # the tracking it sets is what the row's remove must not decide on.
    upstream)
      git -C "$WT" push -q -u origin topic
      if ! git -C "$MAIN" branch --format='%(refname:short) %(upstream:short)' | grep -qx 'topic origin/topic'; then
        echo "FIXTURE: the pushed branch does not track origin/topic" >&2
        exit 2
      fi
      ;;
    *)
      echo "UNKNOWN-STEP: $1" >&2
      exit 2
      ;;
  esac
}

build() {
  local word
  ROOT="$TMP_ROOT/$1"
  shift
  MAIN="$ROOT/main"
  WT="$ROOT/trees/topic"
  OTHER="" TIP="" MERGED="" ROW_PATH="$PATH"
  ROW_ENV=()
  for word in "$@"; do step "$word"; done
  TIP="$(git -C "$MAIN" rev-parse --verify --quiet refs/heads/topic || true)"
  [[ -n "$MERGED" && "$MERGED" != "$TIP" ]] || MERGED=""
}

# The gh column: what the stub answers, as environment for the run.
gh_env() {
  case "$1" in
    none) ;;
    merged) ROW_ENV=("GH_MERGED_PRS=topic main $TIP 42") ;;
    merged-old) ROW_ENV=("GH_MERGED_PRS=topic main $MERGED 42") ;;
    side-base) ROW_ENV=("GH_MERGED_PRS=topic feature-x $TIP 42") ;;
    fork) ROW_ENV=("GH_MERGED_PRS=topic main $TIP 42 1") ;;
    redirect) ROW_ENV=("GH_REPO=someone-else/other-repo" "GH_REDIRECT_OID=$TIP") ;;
    fail) ROW_ENV=("GH_FAIL=1") ;;
    noise-out) ROW_ENV=("GH_NOISE=1") ;;
    noise-err) ROW_ENV=("GH_STDERR_NOISE=1" "GH_MERGED_PRS=topic main $TIP 42") ;;
    no-gh) ROW_PATH="$TMP_ROOT/nogh" ;;
    failing-git) ROW_PATH="$TMP_ROOT/failgit:$PATH" ;;
    *)
      echo "UNKNOWN-GH-SPEC: $1" >&2
      exit 2
      ;;
  esac
}

# --- rendering ------------------------------------------------------------------

# Paths and commits by their names; a literal semicolon is escaped before the
# lines are joined on it.
alias_text() {
  sed -e "s|$WT|<wt>|g" -e "s|${OTHER:-NONE}|<other>|g" -e "s|$MAIN|<main>|g" \
    -e "s|$WORKTREE_SCRIPT|<worktree>|g" -e "s|${TIP:-NONE}|<tip>|g" -e "s|${MERGED:-NONE}|<merged>|g" \
    -e 's/;/\\;/g' |
    paste -s -d ';' -
}

state() {
  local tree=absent dirty="-" branch=absent other="-" oid=""
  if [[ -e "$WT" ]]; then
    tree=present
    dirty="$(git -C "$WT" status --porcelain | paste -s -d ',' -)"
  fi
  oid="$(git -C "$MAIN" rev-parse --verify --quiet refs/heads/topic || true)"
  if [[ -n "$oid" && "$oid" == "$TIP" ]]; then branch=tip
  elif [[ -n "$oid" ]]; then branch="$oid"
  fi
  if [[ -n "$OTHER" ]]; then
    other=absent
    [[ -e "$OTHER" ]] && other=present
  fi
  printf 'tree=%s dirty=%s branch=%s other=%s' "$tree" "${dirty:--}" "$branch" "$other"
}

run() {
  local -a argv
  local rc=0 i
  read -r -a argv <<<"$1"
  for i in "${!argv[@]}"; do
    [[ "${argv[i]}" == @topic ]] && argv[i]="$WT"
  done
  (cd "$MAIN" && env PATH="$ROW_PATH" ${ROW_ENV[@]+"${ROW_ENV[@]}"} "$WORKTREE_SCRIPT" "${argv[@]}" >"$ROOT/out" 2>"$ROOT/err") || rc=$?
  printf 'rc=%s out=%s err=%s %s' "$rc" "$(alias_text <"$ROOT/out")" "$(alias_text <"$ROOT/err")" "$(state)"
}

# --- the expected text ----------------------------------------------------------

UNMERGED='not an ancestor of origin/main, and no pull request merged into main carries this branch name'
MOVED='carries work past its merged pull request (merged under this name: #42\; none has this tip <tip> as its head)'
UNDETERMINED='  A lookup that cannot answer never authorizes a removal\; restore the gh query and re-run cleanup.'
MANUAL='  After verifying it is safe, delete manually with: git -C "<main>" branch -D "topic"'

skip() { printf 'Skipped (%s): %s' "$1" "$2"; }
drop() { printf '  Drop it explicitly with: <worktree> remove "%s"' "$1"; }
kept() { printf '%s' "Error: Removed worktree but could not delete local branch 'topic'.;  Remaining branch: topic;  Worktree path removed/pruned: <wt>;  $1;$MANUAL"; }

out_text() {
  case "$1" in
    -) printf '' ;;
    cleaned) printf 'Cleaned: <wt>' ;;
    removed) printf 'Removed: <wt>' ;;
    *) printf 'UNKNOWN-OUT-SPEC:%s' "$1" ;;
  esac
}

err_text() {
  case "$1" in
    -) printf '' ;;
    other-unmerged) skip "branch 'other' is not merged — $UNMERGED" '<other>' ;;
    unmerged) skip "branch 'topic' is not merged — $UNMERGED" '<wt>' ;;
    moved) skip "branch 'topic' is not merged — not an ancestor of origin/main, and $MOVED" '<wt>' ;;
    undetermined:*) printf '%s;%s' "$(skip "merge status of branch 'topic' could not be determined: ${1#undetermined:}" '<wt>')" "$UNDETERMINED" ;;
    detached) printf '%s;%s' "$(skip 'no branch checked out — detached HEAD, so there is nothing to prove merged' '<wt>')" "$(drop '<wt>')" ;;
    no-ref) printf '%s;%s' "$(skip "branch 'topic' has no ref in the main checkout" '<wt>')" "$(drop '<wt>')" ;;
    enumeration-failed) printf '%s' "fatal: not a git repository (stubbed failure);Error: 'git -C \"<main>\" worktree list --porcelain -z' failed (exit 128).;  No worktree was inspected and none was collected\; this is not a clean sweep." ;;
    deleted) printf "Deleted branch 'topic' — squash-merged in pull request #42." ;;
    kept-unmerged) kept "Not merged into origin/main, and no pull request merged into main carries this branch name" ;;
    kept-moved) kept "Not merged into origin/main, and $MOVED" ;;
    kept-undetermined:*) kept "Merged-pull-request lookup could not answer: ${1#kept-undetermined:}" ;;
    *) printf 'UNKNOWN-ERR-SPEC:%s' "$1" ;;
  esac
}

# --- the rows ---------------------------------------------------------------------
# label|fixture|gh|command|rc|out|err|state
ROWS='
cleanup collects the squash-merged worktree on the merged pull request and names the one it keeps|tree squash other|merged|cleanup|0|cleaned|other-unmerged|tree=absent dirty=- branch=absent other=present
a lookup that fails keeps the worktree and says the status could not be determined|tree squash|fail|cleanup|0|-|undetermined:gh: could not reach api.github.com |tree=present dirty=- branch=tip other=-
gh chatter on stdout is an unreadable answer, not a row that did not match|tree squash|noise-out|cleanup|0|-|undetermined:gh returned a row this cannot read: A new release of gh is available: 2.40.0 -> 2.63.2|tree=present dirty=- branch=tip other=-
a missing gh keeps the worktree and is named|tree squash|no-gh|cleanup|0|-|undetermined:gh is not installed|tree=present dirty=- branch=tip other=-
a detached worktree is named, not passed over|tree detach|none|cleanup|0|-|detached|tree=present dirty=- branch=tip other=-
a worktree whose branch ref is gone is named|tree drop-ref|none|cleanup|0|-|no-ref|tree=present dirty=A  base.txt,A  topic.txt branch=absent other=-
gh chatter on stderr neither disables the proof nor counts as a row|tree squash other|noise-err|cleanup|0|cleaned|other-unmerged|tree=absent dirty=- branch=absent other=present
a branch past its merged pull request is kept with its work|tree squash follow-up scratch|merged-old|cleanup|0|-|moved|tree=present dirty=?? scratch.txt branch=tip other=-
a pull request merged into another base collects nothing|tree|side-base|cleanup|0|-|unmerged|tree=present dirty=- branch=tip other=-
a fork pull request does not vouch for this branch|tree|fork|cleanup|0|-|unmerged|tree=present dirty=- branch=tip other=-
a GH_REPO redirect does not answer for this checkout|tree|redirect|cleanup|0|-|unmerged|tree=present dirty=- branch=tip other=-
a failed enumeration is not a clean sweep|tree|failing-git|cleanup|1|-|enumeration-failed|tree=present dirty=- branch=tip other=-
remove keeps a branch past its merged pull request|tree squash follow-up scratch|merged-old|remove @topic|1|removed|kept-moved|tree=absent dirty=- branch=tip other=-
remove deletes a squash-merged branch on the merged pull request|tree squash|merged|remove @topic|0|removed|deleted|tree=absent dirty=- branch=absent other=-
remove keeps an unmerged branch|tree|none|remove @topic|1|removed|kept-unmerged|tree=absent dirty=- branch=tip other=-
remove keeps a branch merged only into its own upstream|tree upstream|none|remove @topic|1|removed|kept-unmerged|tree=absent dirty=- branch=tip other=-
remove tells an unanswered lookup apart from a proven-unmerged branch|tree squash|fail|remove @topic|1|removed|kept-undetermined:gh: could not reach api.github.com |tree=absent dirty=- branch=tip other=-
'

echo "=== cleanup and remove against squash-merged branches ==="
n=0
while IFS='|' read -r label fixture gh command rc out err want_state; do
  [[ -n "$label$fixture$gh$command$rc$out$err$want_state" ]] || continue
  n=$((n + 1))
  # shellcheck disable=SC2086
  build "row-$n" $fixture
  gh_env "$gh"
  assert_eq "$(run "$command")" "rc=$rc out=$(out_text "$out") err=$(err_text "$err") $want_state" "$label"
done <<<"$ROWS"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
