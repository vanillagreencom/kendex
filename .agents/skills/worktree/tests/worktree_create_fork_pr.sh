#!/usr/bin/env bash
# `create --pr` against a fork pull request, and the remove and cleanup of
# the worktree it leaves: one table, a row per scenario. The head branch of a
# fork PR lives in the contributor's repository, so origin has no such head
# and the commit is reachable only through origin's refs/pull/<n>/head; the
# worktree branch is fork-pr-<n>, so the contributor's branch name never
# touches a local or origin branch of the same name, and a merged fork PR is
# proved by its number, never by ancestry or a head query. A row's fixture is
# a word list of steps that builds the base repository, its origin, the
# contributor's clone and gh's answers, and drives them to the state under
# test; the command runs from the main checkout, and the row pins its exit
# status, its stdout, its stderr, and what is left: every worktree under the
# trees base with its branch and head, every local branch beside main with
# its head and upstream, the main checkout's branch and head, origin's branch heads (refs/heads only, not its pull refs)
# and the remotes the main checkout has.
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

# gh as it answers `pr view <n> --json <fields> -q <query>`: the stored
# document is the field set gh returns, and the query runs over it.
mkdir -p "$TMP_ROOT/bin"
cat >"$TMP_ROOT/bin/gh" <<'STUB'
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
chmod +x "$TMP_ROOT/bin/gh"
export PATH="$TMP_ROOT/bin:$PATH"

# --- fixtures -----------------------------------------------------------------
# Every row's world lives under its own ROOT: the main checkout at ROOT/main,
# the bare origin at ROOT/origin.git, the contributor's clone at ROOT/fork,
# gh's documents at ROOT/gh-state, the worktrees under ROOT/trees.

ROOT=""
MAIN=""
FORK=""
OIDS=""   # "name=commit" words, for the renderer
PHANTOM="$(printf '%040d' 1)"

pr_doc() {
  local number="$1" name="$2" oid="$3" cross="$4" state="${5:-OPEN}" base="${6:-main}"
  printf '{"headRefName":"%s","headRefOid":"%s","isCrossRepository":%s,"state":"%s","baseRefName":"%s"}\n' \
    "$name" "$oid" "$cross" "$state" "$base" >"$ROOT/gh-state/pr-$number.json"
}

# A commit on the contributor's clone, on a branch off its main, pushed to
# origin as the head of a pull request and nothing else.
fork_pr() {
  local number="$1" branch="$2" file="$3" content="$4" name="$5"
  if [[ "$branch" == main ]]; then
    git -C "$FORK" checkout -q main
  else
    git -C "$FORK" checkout -q -b "$branch" main
  fi
  printf '%s\n' "$content" >"$FORK/$file"
  git -C "$FORK" add "$file"
  git -C "$FORK" commit -q -m "$file"
  OIDS="$OIDS $name=$(git -C "$FORK" rev-parse HEAD)"
  must git -C "$FORK" push -q -f origin "HEAD:refs/pull/$number/head"
  pr_doc "$number" "$branch" "$(oid_of "$name")" true
}

# The content of a fork PR lands on main as a new commit (a squash), so
# ancestry never proves the merge.
squash() {
  local number="$1" file="$2" content="$3"
  printf '%s\n' "$content" >"$MAIN/$file"
  git -C "$MAIN" add "$file"
  git -C "$MAIN" commit -q -m "$file (squashed)"
  git -C "$MAIN" push -q origin main
}

tool() {
  (cd "$MAIN" && "$WORKTREE_SCRIPT" "$@" >/dev/null 2>&1) || true
}

# A fixture command that must succeed; its failure is the fixture's, not a
# row's, and stops the suite with a FIXTURE: line.
must() {
  "$@" || { echo "FIXTURE: '$*' failed in $ROOT" >&2; exit 2; }
}

# The step vocabulary. `world` builds the base repository, its origin, the
# contributor's clone and the pull requests every row can name: #7 a fork PR
# on the contributor's branch, #8 a same-repository PR whose head is an
# origin branch, #9 a fork PR whose pull ref delivers the base's tip rather
# than the head gh reports, #10 a fork PR with no pull ref, #11 a fork PR
# opened from the contributor's own main.
step() {
  case "$1" in
    world)
      mkdir -p "$MAIN" "$ROOT/gh-state"
      git -C "$MAIN" init -q -b main
      git -C "$MAIN" config user.email test@example.com
      git -C "$MAIN" config user.name Test
      git -C "$MAIN" config commit.gpgsign false
      printf 'base\n' >"$MAIN/base.txt"
      git -C "$MAIN" add base.txt
      git -C "$MAIN" commit -q -m base
      printf 'WORKTREE_BASE_DIR="../trees"\n' >"$MAIN/.env.local"
      # HEAD names main so the clone checks it out whatever the host's default branch is.
      git init -q --bare -b main "$ROOT/origin.git"
      git -C "$MAIN" remote add origin "$ROOT/origin.git"
      git -C "$MAIN" push -q -u origin main
      OIDS="$OIDS base=$(git -C "$MAIN" rev-parse HEAD)"
      git clone -q "$ROOT/origin.git" "$FORK"
      git -C "$FORK" config user.email fork@example.com
      git -C "$FORK" config user.name Fork
      git -C "$FORK" config commit.gpgsign false
      fork_pr 7 fix/widget-expiry fix.txt 'fork fix' fork
      git -C "$MAIN" checkout -q -b feat/same
      printf 'same repo\n' >"$MAIN/same.txt"
      git -C "$MAIN" add same.txt
      git -C "$MAIN" commit -q -m 'same-repo feature'
      OIDS="$OIDS same=$(git -C "$MAIN" rev-parse HEAD)"
      git -C "$MAIN" push -q origin feat/same "HEAD:refs/pull/8/head"
      git -C "$MAIN" checkout -q main
      git -C "$MAIN" branch -q -D feat/same
      pr_doc 8 feat/same "$(oid_of same)" false
      git -C "$MAIN" push -q origin "main:refs/pull/9/head"
      pr_doc 9 fix/phantom "$PHANTOM" true
      pr_doc 10 fix/no-pull-ref "$(oid_of fork)" true
      fork_pr 11 main from-main.txt 'fork main fix' fork-main
      ;;
    inspect:*)
      tool create "issue-${1#inspect:}" --pr "${1#inspect:}"
      [[ -d "$ROOT/trees/issue-${1#inspect:}" ]] || { echo "FIXTURE: create --pr ${1#inspect:} left no worktree in $ROOT" >&2; exit 2; }
      ;;
    remove:*) tool remove "issue-${1#remove:}" ;;
    # The contributor pushed again since the worktree was made.
    advance-fork)
      git -C "$FORK" checkout -q fix/widget-expiry
      printf 'fork fix 2\n' >>"$FORK/fix.txt"
      git -C "$FORK" commit -q -am 'fork fix 2'
      OIDS="$OIDS fork2=$(git -C "$FORK" rev-parse HEAD)"
      git -C "$FORK" push -q -f origin "HEAD:refs/pull/7/head"
      pr_doc 7 fix/widget-expiry "$(oid_of fork2)" true
      ;;
    # Origin grew an unrelated branch under the contributor's branch name,
    # and the stale local branch tracks it.
    unrelated-branch)
      must git -C "$MAIN" push -q origin "main:refs/heads/fix/widget-expiry"
      must git -C "$MAIN" fetch -q origin
      must git -C "$MAIN" branch -q --set-upstream-to=origin/fix/widget-expiry fork-pr-7
      ;;
    # A commit of this checkout's own on the fork PR's branch.
    local-commit)
      git -C "$ROOT/trees/issue-7" config user.email test@example.com
      git -C "$ROOT/trees/issue-7" config user.name Test
      git -C "$ROOT/trees/issue-7" config commit.gpgsign false
      printf 'local only\n' >"$ROOT/trees/issue-7/local.txt"
      git -C "$ROOT/trees/issue-7" add local.txt
      git -C "$ROOT/trees/issue-7" commit -q -m 'local only'
      OIDS="$OIDS local=$(git -C "$ROOT/trees/issue-7" rev-parse HEAD)"
      ;;
    squash:11) squash 11 from-main.txt 'fork main fix' ;;
    squash:12) squash 12 cleanup.txt 'cleanup fix' ;;
    merged:11) pr_doc 11 main "$(oid_of fork-main)" true MERGED ;;
    merged:12) pr_doc 12 fix/cleanup "$(oid_of cleanup)" true MERGED ;;
    # #13's merged head is not this checkout's tip.
    merged:13-elsewhere) pr_doc 13 fix/still-open "$(oid_of fork)" true MERGED ;;
    # Two more fork PRs, #12 and #13, each checked out.
    two-more)
      fork_pr 12 fix/cleanup cleanup.txt 'cleanup fix' cleanup
      fork_pr 13 fix/still-open open.txt 'still open' open
      step inspect:12
      step inspect:13
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
  FORK="$ROOT/fork"
  OIDS=""
  export GH_STATE="$ROOT/gh-state"
  for word in "$@"; do
    step "$word"
  done
}

# --- rendering ------------------------------------------------------------------

oid_of() {
  local word
  for word in $OIDS; do
    [[ "${word%%=*}" == "$1" ]] && { printf '%s' "${word#*=}"; return; }
  done
}

oid_name() {
  local oid="$1" word
  [[ -n "$oid" ]] || { printf -- '-'; return; }
  for word in $OIDS; do
    if [[ "${word#*=}" == "$oid" ]]; then
      printf '%s' "${word%%=*}"
      return
    fi
  done
  if [[ "$oid" == "$(git -C "$MAIN" rev-parse origin/main)" ]]; then printf 'squashed'
  else printf '%s' "$oid"
  fi
}

alias_text() {
  local sed_args=() word
  for word in $OIDS; do
    sed_args+=(-e "s|${word#*=}|<${word%%=*}>|g")
  done
  sed -e "s|$ROOT|<root>|g" -e "s|$PHANTOM|<phantom>|g" ${sed_args[@]+"${sed_args[@]}"} -e 's/;/\\;/g' |
    paste -s -d ';' -
}

upstream_of() {
  git -C "$MAIN" rev-parse --abbrev-ref --symbolic-full-name "$1@{upstream}" 2>/dev/null || printf -- '-'
}

state() {
  local trees="" branches="" origin="" dir branch line
  for dir in "$ROOT"/trees/*; do
    [[ -e "$dir" ]] || continue
    if git -C "$MAIN" worktree list --porcelain | grep -qx "worktree $dir"; then
      branch="$(git -C "$dir" branch --show-current 2>/dev/null)"
      trees="$trees,${dir#"$ROOT"/trees/}=${branch:-detached}@$(oid_name "$(git -C "$dir" rev-parse HEAD 2>/dev/null)")"
    else
      trees="$trees,${dir#"$ROOT"/trees/}=unregistered"
    fi
  done
  while IFS=' ' read -r branch line; do
    [[ -n "$branch" && "$branch" != main ]] || continue
    branches="$branches,$branch@$(oid_name "$line")/$(upstream_of "$branch")"
  done <<<"$(git -C "$MAIN" for-each-ref --format='%(refname:short) %(objectname)' refs/heads)"
  while IFS=' ' read -r branch line; do
    [[ -n "$branch" ]] || continue
    origin="$origin,${branch#refs/heads/}@$(oid_name "$line")"
  done <<<"$(git --git-dir="$ROOT/origin.git" for-each-ref --format='%(refname) %(objectname)' refs/heads)"
  printf 'trees=%s branches=%s main=%s@%s origin=%s remotes=%s' \
    "${trees:-,-}" "${branches:-,-}" "$(git -C "$MAIN" branch --show-current)" \
    "$(oid_name "$(git -C "$MAIN" rev-parse HEAD)")" "${origin:-,-}" \
    "$(git -C "$MAIN" remote | paste -s -d ',' -)" | sed 's/=,/=/g'
}

run() {
  local -a argv
  local rc=0
  read -r -a argv <<<"$1"
  (cd "$MAIN" && "$WORKTREE_SCRIPT" "${argv[@]}" >"$ROOT/out" 2>"$ROOT/err") || rc=$?
  printf 'rc=%s out=%s err=%s %s' "$rc" \
    "$(alias_text <"$ROOT/out")" "$(alias_text <"$ROOT/err")" "$(state)"
}

# --- the expected text ----------------------------------------------------------

err_text() {
  case "$1" in
    -) printf '' ;;
    diverged) printf '%s' "Error: Local branch 'fork-pr-7' has commits that are not in the head of fork PR #7\; delete or rename that branch before inspecting the PR again." ;;
    phantom) printf '%s' "Error: refs/pull/9/head on origin did not deliver commit <phantom>, the head gh reports for PR #9" ;;
    no-ref) printf '%s' "Error: Could not fetch refs/pull/10/head from origin for fork PR #10;  fatal: couldn't find remote ref refs/pull/10/head" ;;
    deleted:*) printf '%s' "Deleted branch 'fork-pr-${1#deleted:}' — squash-merged in pull request #${1#deleted:}." ;;
    remove-open) printf '%s' "Error: Removed worktree but could not delete local branch 'fork-pr-7'.;  Remaining branch: fork-pr-7;  Worktree path removed/pruned: <root>/trees/issue-7;  Not merged into origin/main, and fork pull request #7 is OPEN, not merged;  After verifying it is safe, delete manually with: git -C \"<root>/main\" branch -D \"fork-pr-7\"" ;;
    open-kept) printf '%s' "Skipped (branch 'fork-pr-13' is not merged — not an ancestor of origin/main, and fork pull request #13 is OPEN, not merged): <root>/trees/issue-13" ;;
    moved-kept) printf '%s' "Skipped (branch 'fork-pr-13' is not merged — not an ancestor of origin/main, and carries work past its merged pull request (#13 merged head <fork>, not this tip <open>)): <root>/trees/issue-13" ;;
    *) printf 'UNKNOWN-ERR-SPEC:%s' "$1" ;;
  esac
}

out_text() {
  case "$1" in
    -) printf '' ;;
    wt:*) printf '<root>/trees/issue-%s' "${1#wt:}" ;;
    removed:*) printf 'Removed: <root>/trees/issue-%s' "${1#removed:}" ;;
    cleaned:*) printf 'Cleaned: <root>/trees/issue-%s' "${1#cleaned:}" ;;
    *) printf 'UNKNOWN-OUT-SPEC:%s' "$1" ;;
  esac
}

# --- the rows ---------------------------------------------------------------------
# label|fixture|command|rc|out|err|state
ROWS='a fork PR is checked out on fork-pr-<n> at the head gh reports, with no upstream, no fork remote and no contributor-named branch|world|create issue-7 --pr 7|0|wt:7|-|trees=issue-7=fork-pr-7@fork branches=fork-pr-7@fork/- main=main@base origin=feat/same@same,main@base remotes=origin
a same-repository PR keeps the tracked origin-branch checkout|world|create issue-8 --pr 8|0|wt:8|-|trees=issue-8=feat/same@same branches=feat/same@same/origin/feat/same main=main@base origin=feat/same@same,main@base remotes=origin
a fork PR opened from the contributor'"'"'s main leaves this checkout'"'"'s main untouched|world|create issue-11 --pr 11|0|wt:11|-|trees=issue-11=fork-pr-11@fork-main branches=fork-pr-11@fork-main/- main=main@base origin=feat/same@same,main@base remotes=origin
remove keeps the open fork PR'"'"'s local branch|world inspect:7|remove issue-7|1|removed:7|remove-open|trees=- branches=fork-pr-7@fork/- main=main@base origin=feat/same@same,main@base remotes=origin
re-inspecting after the contributor pushed resets the stale branch to the new head and clears the tracking an unrelated origin branch left|world inspect:7 advance-fork remove:7 unrelated-branch|create issue-7 --pr 7|0|wt:7|-|trees=issue-7=fork-pr-7@fork2 branches=fork-pr-7@fork2/- main=main@base origin=feat/same@same,fix/widget-expiry@base,main@base remotes=origin
a local branch that diverged from the PR head is refused by name, not reset|world inspect:7 local-commit remove:7|create issue-7 --pr 7|1|-|diverged|trees=- branches=fork-pr-7@local/- main=main@base origin=feat/same@same,main@base remotes=origin
a pull ref that delivers a commit other than the head gh reports is refused before any worktree exists|world|create issue-9 --pr 9|1|-|phantom|trees=- branches=- main=main@base origin=feat/same@same,main@base remotes=origin
a fork PR with no pull ref on origin is refused before any worktree exists|world|create issue-10 --pr 10|1|-|no-ref|trees=- branches=- main=main@base origin=feat/same@same,main@base remotes=origin
remove proves a squash-merged fork PR by its number and deletes the branch|world inspect:11 squash:11 merged:11|remove issue-11|0|removed:11|deleted:11|trees=- branches=- main=main@squashed origin=feat/same@same,main@squashed remotes=origin
cleanup collects the merged fork PR and keeps the open one, naming it|world two-more squash:12 merged:12|cleanup|0|cleaned:12|open-kept|trees=issue-13=fork-pr-13@open branches=fork-pr-13@open/- main=main@squashed origin=feat/same@same,main@squashed remotes=origin
cleanup keeps a fork branch whose tip is past its merged head, naming the mismatch|world two-more squash:12 merged:12 merged:13-elsewhere|cleanup|0|cleaned:12|moved-kept|trees=issue-13=fork-pr-13@open branches=fork-pr-13@open/- main=main@squashed origin=feat/same@same,main@squashed remotes=origin
'

echo "=== worktree create --pr, remove and cleanup on fork pull requests ==="
n=0
while IFS= read -r row; do
  [[ -n "$row" ]] || continue
  IFS='|' read -r label fixture command rc out err want_state <<<"$row"
  for field in "$label" "$fixture" "$command" "$rc" "$out" "$err" "$want_state"; do
    [[ -n "$field" ]] || { printf 'a row with an empty field asserts nothing: %s\n' "$row" >&2; exit 1; }
  done
  n=$((n + 1))
  # shellcheck disable=SC2086
  build "row-$n" $fixture
  # A rendering aid for writing rows: prints what each row produces instead of
  # asserting it. A run that asserted no row is refused after the loop.
  if [[ "${WORKTREE_TABLE_PROBE:-}" == 1 ]]; then
    printf '%s => %s\n' "$label" "$(run "$command")"
    continue
  fi
  assert_eq "$(run "$command")" "rc=$rc out=$(out_text "$out") err=$(err_text "$err") $want_state" "$label"
done <<<"$ROWS"
[[ "$((PASS + FAIL))" -gt 0 ]] || { echo "no row was asserted (a probe run renders rows instead)" >&2; exit 2; }

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
