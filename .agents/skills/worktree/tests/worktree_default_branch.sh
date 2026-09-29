#!/usr/bin/env bash
# The default branch the worktree commands read: WORKTREE_DEFAULT_BRANCH when
# set, else the repository's default branch on GitHub, read through the github
# skill beside this package. A checkout with no GitHub repository, and a
# failed GitHub read with a warning, take git's record of origin's HEAD and
# refuse where git holds none. The first table runs `merged`, whose forge
# query carries the default branch as its --base; one `create` then starts a
# tree from GitHub's default branch; a table with no default branch known
# runs the create modes, the reuse and the removal that need none beside
# those that refuse; the last table runs `check`, which reports the default branch's
# unpushed commits, none where only origin holds the branch, and refuses
# where git cannot list them.
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
# read GitHub refuses; any other repository's default_branch is foreign. No
# merged pull request carries any branch.
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
    if [[ "$2" != "repos/$GH_SLUG" ]]; then
      printf 'foreign\n'
    elif [[ "$GH_DEFAULT" == FAIL ]]; then
      echo "gh: Not Found (HTTP 404)" >&2
      exit 1
    else
      printf '%s\n' "$GH_DEFAULT"
    fi
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
git -C "$MAIN" config gc.auto 0
git -C "$MAIN" config maintenance.auto false
git -C "$MAIN" config user.email test@example.com
git -C "$MAIN" config user.name Test
git -C "$MAIN" config commit.gpgsign false
printf 'orig\n' >"$MAIN/file.txt"
git -C "$MAIN" add file.txt
git -C "$MAIN" commit -q -m base
printf 'WORKTREE_BASE_DIR="../trees"\n' >"$MAIN/.env.local"
git init -q --bare "$TMP_ROOT/origin.git"
git -C "$TMP_ROOT/origin.git" config gc.auto 0
git -C "$TMP_ROOT/origin.git" config maintenance.auto false
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

# The must-fail controls: copies of the two packages whose worktree script
# has one whole line replaced, and, where NEXT is given, only the copy of that
# line the line NEXT follows. `read` takes main in place of the github skill's
# answer; `inherited` reads it under the caller's GH_REPO; `refusing` refuses on a failed GitHub read where the script falls
# back to git's record; `uncalled` cuts check's resolve call; `eager-create`
# and `eager-remove` resolve whatever create or remove was asked for; `loud`
# prints the refusal where the caller works without the branch; `lazy-remove`
# cuts remove's resolve call, so the tree goes before the branch proof reads
# the default branch; `eager-reuse` resolves before --reuse reads the tree's
# branch; `local-less` lists the range with no local default branch;
# `origin-less` skips the range where origin lacks the branch too;
# `silent` reads a failed listing as no unpushed commits.
mutant() { # NAME FROM TO [NEXT]
  local script="$TMP_ROOT/$1/worktree/scripts/worktree" rc=0
  mkdir -p "$TMP_ROOT/$1"
  cp -R "$PACKAGE_DIR" "$TMP_ROOT/$1/worktree"
  cp -R "$SKILLS_DIR/github" "$TMP_ROOT/$1/github"
  F="$2" T="$3" N="${4:-}" awk '
    BEGIN { f = ENVIRON["F"]; t = ENVIRON["T"]; n = ENVIRON["N"] }
    { line[NR] = $0 }
    END {
      for (i = 1; i <= NR; i++) {
        if (line[i] == f && (n == "" || line[i + 1] == n)) { line[i] = t; hits++ }
        print line[i]
      }
      exit hits == 1 ? 0 : 3
    }' "$WORKTREE_SCRIPT" >"$TMP_ROOT/$1.edit" || rc=$?
  assert_eq "$rc" 0 "control: the $1 edit replaced exactly one line"
  cat -- "$TMP_ROOT/$1.edit" >"$script"
}
# shellcheck disable=SC2016 # each line is the script's own text, not expanded
mutant read '    answer="$( (cd "$PROJECT_ROOT" && unset GH_REPO && kendex_github_default_branch "$PROJECT_ROOT") 2>&1)" || rc=$?' '    answer=main'
# shellcheck disable=SC2016 # each line is the script's own text, not expanded
mutant inherited '    answer="$( (cd "$PROJECT_ROOT" && unset GH_REPO && kendex_github_default_branch "$PROJECT_ROOT") 2>&1)" || rc=$?' \
  '    answer="$( (cd "$PROJECT_ROOT" && kendex_github_default_branch "$PROJECT_ROOT") 2>&1)" || rc=$?'
mutant refusing "        sed 's/^/  /' <<<\"\$answer\" >&2" "        sed 's/^/  /' <<<\"\$answer\" >&2; return 1"
# shellcheck disable=SC2016 # each line is the script's own text, not expanded
mutant uncalled '    resolve_default_branch || exit 1' '    :' \
  '    # A default branch GitHub names can exist only as origin/NAME, after the'
# shellcheck disable=SC2016 # each line is the script's own text, not expanded
mutant local-less '    if { git -C "$PROJECT_ROOT" rev-parse --verify --quiet "refs/heads/$DEFAULT_BRANCH" >/dev/null ||' '    if { true ||'
# shellcheck disable=SC2016 # each line is the script's own text, not expanded
mutant origin-less '      ! git -C "$PROJECT_ROOT" rev-parse --verify --quiet "refs/remotes/origin/$DEFAULT_BRANCH" >/dev/null; } &&' '      false; } &&'
# shellcheck disable=SC2016 # each line is the script's own text, not expanded
mutant silent '      ! UNPUSHED_COMMITS=$(git -C "$PROJECT_ROOT" log "origin/$DEFAULT_BRANCH..refs/heads/$DEFAULT_BRANCH" --oneline 2>/dev/null); then' \
  '      UNPUSHED_COMMITS=$(git -C "$PROJECT_ROOT" log "origin/$DEFAULT_BRANCH..refs/heads/$DEFAULT_BRANCH" --oneline 2>/dev/null) && false; then'
# shellcheck disable=SC2016 # each line is the script's own text, not expanded
mutant eager-create '    [[ -z "$BRANCH" ]] || resolve_default_branch || exit 1' '    resolve_default_branch || exit 1' \
  '    if [[ -n "$BRANCH" && "$BRANCH" == "$DEFAULT_BRANCH" ]]; then'
# shellcheck disable=SC2016 # each line is the script's own text, not expanded
mutant loud '    [[ "${1:-}" == optional ]] && return 1' '    :'
# shellcheck disable=SC2016 # each line is the script's own text, not expanded
mutant eager-remove '    [[ -z "$BRANCH" ]] || resolve_default_branch || exit 1' '    resolve_default_branch || exit 1' \
  '    if [[ -d "$WT_PATH" ]]; then'
# shellcheck disable=SC2016 # each line is the script's own text, not expanded
mutant lazy-remove '    [[ -z "$BRANCH" ]] || resolve_default_branch || exit 1' '    :' \
  '    if [[ -d "$WT_PATH" ]]; then'
# shellcheck disable=SC2016 # each line is the script's own text, not expanded
mutant eager-reuse '      CURRENT_BRANCH=$(git -C "$WT_PATH" branch --show-current 2>/dev/null)' \
  '      resolve_default_branch || exit 1; CURRENT_BRANCH=$(git -C "$WT_PATH" branch --show-current 2>/dev/null)' \
  '      if [[ -n "$CURRENT_BRANCH" ]]; then'

# --- the rows -------------------------------------------------------------------
# Every row runs one verb in the main checkout with the row's environment and
# reports its exit, its stderr records, and how many times GitHub was asked
# for the repository. `-` is an empty field.

records() {
  local text
  text="$(message_records <"$1" | sed "s|$MAIN|<root>|g" | paste -s -d ';' -)" || return 1
  printf '%s' "${text:--}"
}

run_verb() { # SCRIPT ENV_WORDS VERB [ARG...]
  local script="$1" env_words="$2" rc=0
  shift 2
  : >"$GH_LOG"
  [[ "$script" == real ]] && script="$WORKTREE_SCRIPT" || script="$TMP_ROOT/$script/worktree/scripts/worktree"
  # shellcheck disable=SC2086 # the row's environment is words
  (cd "$MAIN" && env -u WORKTREE_DEFAULT_BRANCH -u GH_REPO PATH="$TMP_ROOT/bin:$PATH" GH_LOG="$GH_LOG" $env_words \
    "$script" "$@" >"$TMP_ROOT/out" 2>"$TMP_ROOT/err") || rc=$?
  printf 'rc=%s err=%s reads=%s' "$rc" "$(records "$TMP_ROOT/err")" "$(grep -c '^api repos/' "$GH_LOG" || true)"
}

# label|script|environment|exit|stderr records|GitHub repository reads|the
# --base merged asked the forge about. From the first `no record` row on,
# git holds no record of origin's HEAD.
echo "=== the default branch merged asks the forge about ==="
while IFS='|' read -r label script env_words rc err reads base; do
  [[ -z "$label" ]] && continue
  if [[ "$label" == *"no record"* ]]; then git -C "$MAIN" remote set-head origin -d; fi
  got="$(run_verb "$script" "$env_words" merged lonely)"
  asked="$(sed -n 's/^pr list .*--base \([^ ]*\) .*/\1/p' "$GH_LOG" | paste -s -d , -)"
  assert_eq "$got base=${asked:--}" "rc=$rc err=$err reads=$reads base=$base" "$label"
done <<'ROWS'
GitHub's default branch is the one the forge is asked about|real|GH_SLUG=acme/widgets GH_DEFAULT=develop|1|worktree-unmerged: lonely|1|develop
must-fail: with the read replaced by main, develop's repository is asked about main|read|GH_SLUG=acme/widgets GH_DEFAULT=develop|1|worktree-unmerged: lonely|0|main
a GH_REPO naming another repository still reads this checkout's default branch|real|GH_SLUG=acme/widgets GH_DEFAULT=develop GH_REPO=other/elsewhere|1|worktree-unmerged: lonely|1|develop
must-fail: with GH_REPO kept, the other repository's default branch is asked about|inherited|GH_SLUG=acme/widgets GH_DEFAULT=develop GH_REPO=other/elsewhere|1|worktree-unmerged: lonely|1|foreign
WORKTREE_DEFAULT_BRANCH overrides, and GitHub is not asked|real|GH_SLUG=acme/widgets GH_DEFAULT=develop WORKTREE_DEFAULT_BRANCH=trunk|1|worktree-unmerged: lonely|0|trunk
a default branch GitHub cannot name warns and takes git's record of origin's HEAD|real|GH_SLUG=acme/widgets GH_DEFAULT=FAIL|1|worktree-default-branch-unreadable: <root>;worktree-unmerged: lonely|1|main
must-fail: with the fallback cut, a failed GitHub read refuses where git holds a record|refusing|GH_SLUG=acme/widgets GH_DEFAULT=FAIL|2|worktree-default-branch-unreadable: <root>|1|-
a checkout with no GitHub repository takes git's record of origin's HEAD|real|GH_SLUG=- GH_DEFAULT=develop|1|worktree-unmerged: lonely|0|main
a failed GitHub read with no record refuses|real|GH_SLUG=acme/widgets GH_DEFAULT=FAIL|2|worktree-default-branch-unreadable: <root>;worktree-default-branch-unknown: <root>|1|-
a checkout with no GitHub repository and no record refuses|real|GH_SLUG=- GH_DEFAULT=develop|2|worktree-default-branch-unknown: <root>|0|-
ROWS
git -C "$MAIN" remote set-head origin main

echo "=== create starts from GitHub's default branch ==="
rc=0
(cd "$MAIN" && env -u WORKTREE_DEFAULT_BRANCH -u GH_REPO PATH="$TMP_ROOT/bin:$PATH" GH_LOG="$GH_LOG" \
  GH_SLUG=acme/widgets GH_DEFAULT=develop "$WORKTREE_SCRIPT" create dev1 >"$TMP_ROOT/out" 2>"$TMP_ROOT/err") || rc=$?
assert_eq "$rc" 0 "create exits 0"
assert_eq "$(git -C "$(cat "$TMP_ROOT/out")" rev-parse HEAD 2>/dev/null || true)" "$DEVELOP" \
  "the new tree starts at origin/develop"

# label|script|exit|stderr records|verb and arguments, {detached} the path
# of a detached worktree; origin's inspect-a and inspect-b are branches
# --base can inspect; dev7's tree is detached and registered for its issue.
# gh names no GitHub repository and git holds no record of origin's HEAD, so
# no default branch resolves, and only the create modes and the removals that
# read one refuse.
echo "=== with no default branch, only what reads it refuses ==="
git -C "$MAIN" remote set-head origin -d
DETACHED="$TMP_ROOT/trees/detached"
git -C "$MAIN" worktree add -q --detach "$DETACHED" main
REUSED="$TMP_ROOT/trees/dev7"
git -C "$MAIN" worktree add -q --detach "$REUSED" main
printf 'dev7\n' >"$(git -C "$REUSED" rev-parse --absolute-git-dir)/kendex-issue"
git -C "$MAIN" push -q origin main:refs/heads/inspect-a main:refs/heads/inspect-b
while IFS='|' read -r label script rc err args; do
  [[ -z "$label" ]] && continue
  # shellcheck disable=SC2086 # the row's arguments are words
  got="$(run_verb "$script" "GH_SLUG=- GH_DEFAULT=develop" ${args//\{detached\}/$DETACHED})"
  assert_eq "$got" "rc=$rc err=$err reads=0" "$label"
done <<'ROWS'
create --from starts from its own ref|real|0|-|create dev2 --from develop
must-fail: with create resolving eagerly, create --from refuses|eager-create|1|worktree-default-branch-unknown: <root>|create dev3 --from develop
plain create starts from the default branch, so it refuses|real|1|worktree-default-branch-unknown: <root>|create dev4
create --base inspects the named branch without a refusal|real|0|-|create dev5 --base inspect-a
must-fail: with the optional resolve refusing, create --base prints the refusal|loud|0|worktree-default-branch-unknown: <root>|create dev6 --base inspect-b
must-fail: with remove resolving eagerly, a detached worktree is kept|eager-remove|1|worktree-default-branch-unknown: <root>|remove {detached}
remove of a detached worktree removes it|real|0|-|remove {detached}
remove of a worktree on a branch refuses before anything is removed|real|1|worktree-default-branch-unknown: <root>|remove dev2
must-fail: with remove's resolve cut, a worktree on a branch is removed before the branch proof fails|lazy-remove|1|worktree-branch-delete-failed: inspect-a|remove dev5
must-fail: with reuse resolving eagerly, --reuse of a detached tree refuses|eager-reuse|1|worktree-default-branch-unknown: <root>|create dev7 --reuse
--reuse of a detached tree reads no default branch|real|0|-|create dev7 --reuse
ROWS
assert_eq "$([[ -e $DETACHED ]] && echo kept || echo gone)" gone "the detached worktree is gone"
DEV2="$TMP_ROOT/trees/dev2"
assert_eq "$([[ -d $DEV2 ]] && echo kept || echo gone)" kept "the refused removal keeps dev2's tree"
assert_eq "$(git -C "$MAIN" worktree list --porcelain | grep -Fxc "worktree $DEV2" || true)" 1 \
  "the refused removal keeps dev2's tree registered"
git -C "$MAIN" remote set-head origin main

# The main checkout's develop now holds one commit origin/develop lacks, and
# its main none, so only a check that resolved develop reports it unpushed.
git -C "$MAIN" checkout -q develop
printf 'ahead\n' >"$MAIN/file.txt"
git -C "$MAIN" commit -q -am ahead
AHEAD="$(git -C "$MAIN" log -1 --format='%h ahead')"
git -C "$MAIN" checkout -q main
UNPUSHED="{\"uncommitted\": false, \"unpushed\": true, \"unpushed_commits\": [\"$AHEAD\"]}"
CLEAN='{"uncommitted": false, "unpushed": false, "unpushed_commits": []}'
# trunk exists only as origin/trunk, as after the repository's default
# changed; solo exists only in the main checkout.
git -C "$MAIN" push -q origin main:refs/heads/trunk
git -C "$MAIN" branch solo

# label|script|environment|git's record of origin's HEAD (- for none)|exit|
# stderr records|GitHub repository reads|stdout (UNPUSHED, CLEAN or -)
echo "=== check reads the default branch's unpushed commits ==="
while IFS='|' read -r label script env_words record rc err reads out; do
  [[ -z "$label" ]] && continue
  if [[ "$record" == - ]]; then
    git -C "$MAIN" remote set-head origin -d
  else
    git -C "$MAIN" remote set-head origin "$record"
  fi
  [[ "$out" != UNPUSHED ]] || out="$UNPUSHED"
  [[ "$out" != CLEAN ]] || out="$CLEAN"
  got="$(run_verb "$script" "$env_words" check)"
  printed="$(cat -- "$TMP_ROOT/out")"
  assert_eq "$got out=${printed:--}" "rc=$rc err=$err reads=$reads out=$out" "$label"
done <<'ROWS'
GitHub's default branch develop holds the unpushed commit|real|GH_SLUG=acme/widgets GH_DEFAULT=develop|main|0|-|1|UNPUSHED
must-fail: with check's resolve call cut, check reads no branch and refuses the empty range|uncalled|GH_SLUG=acme/widgets GH_DEFAULT=develop|main|1|worktree-unpushed-unreadable: origin/..|0|-
a default branch only origin holds has no unpushed commits in the checkout|real|GH_SLUG=acme/widgets GH_DEFAULT=trunk|main|0|-|1|CLEAN
must-fail: with the local branch unchecked, a default branch only origin holds refuses|local-less|GH_SLUG=acme/widgets GH_DEFAULT=trunk|main|1|worktree-unpushed-unreadable: origin/trunk..trunk|1|-
a local default branch origin lacks refuses|real|GH_SLUG=acme/widgets GH_DEFAULT=solo|main|1|worktree-unpushed-unreadable: origin/solo..solo|1|-
must-fail: with a failed listing read as none, a default branch origin lacks reports nothing unpushed|silent|GH_SLUG=acme/widgets GH_DEFAULT=solo|main|0|-|1|CLEAN
a default branch neither the checkout nor origin holds refuses|real|GH_SLUG=acme/widgets WORKTREE_DEFAULT_BRANCH=trnuk|main|1|worktree-unpushed-unreadable: origin/trnuk..trnuk|0|-
must-fail: with origin's branch unchecked, a default branch neither holds reports nothing unpushed|origin-less|GH_SLUG=acme/widgets WORKTREE_DEFAULT_BRANCH=trnuk|main|0|-|0|CLEAN
a default branch GitHub cannot name warns and takes git's record of origin's HEAD|real|GH_SLUG=acme/widgets GH_DEFAULT=FAIL|develop|0|worktree-default-branch-unreadable: <root>|1|UNPUSHED
a failed GitHub read with no record refuses|real|GH_SLUG=acme/widgets GH_DEFAULT=FAIL|-|1|worktree-default-branch-unreadable: <root>;worktree-default-branch-unknown: <root>|1|-
ROWS
git -C "$MAIN" remote set-head origin main

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
