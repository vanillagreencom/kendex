#!/usr/bin/env bash
# `worktree create` against active work: the ownership guards, the option
# parsing and `--base <default>` as one table, then the concurrent claim.
set -euo pipefail
# A pre-commit hook exports GIT_DIR and GIT_INDEX_FILE, which point every git
# call below at the real repository; -C overrides neither.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKTREE_SCRIPT="${WORKTREE_SCRIPT:-$(cd "$TEST_DIR/.." && pwd)/scripts/worktree}"
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT
# The real git, resolved before any row puts a stub ahead of it on PATH.
REAL_GIT="$(command -v git)"

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

# A checkout with a bare origin, the sibling trees/ base, and a `gh` stub that
# answers `pr list` from GH_STATE (an open PR #42 when open-pr exists, a
# failure when fail-gh does, a pause when slow-gh does) and `pr view` from the
# stored document pr-42.json.
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
  printf 'WORKTREE_BASE_DIR="../trees"\n' >"$root/main/.env.local"
  printf '.env.local\n' >>"$root/main/.git/info/exclude"
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
    # `pr view <n> --json <fields> -q <query>`: the stored document is the
    # field set gh returns, and the query runs over it.
    shift 3
    query=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -q | --jq) query="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    jq -r "$query" "${GH_STATE:?}/pr-42.json"
    ;;
esac
STUB
  chmod +x "$root/bin/gh"
}

# --- create against active work: one table -------------------------------------
# A row builds its own checkout from a step word list, runs one `create` line
# from the main checkout under the row's environment, and pins the exit
# status, stdout (usage text by its first line), stderr whole, and what is
# left: the main checkout's branch, head and dirty files, the per-worktree
# config, every directory under the trees base with its registration, branch
# and head, the local branches beside main, and the topic worktree's dirty
# files.

ROOT=""
MAIN=""
TREES_DIR=""
WT=""
PRE=""
END=""
ROW_ENV=()

# Create the topic worktree through the script itself, so its shape is the
# one `create` leaves rather than a hand-built approximation.
fixture_create() {
  (cd "$MAIN" && env PATH="$ROOT/bin:$PATH" GH_STATE="$ROOT/gh-state" "$WORKTREE_SCRIPT" create "$@" >/dev/null 2>"$ROOT/fixture.err") && return 0
  echo "FIXTURE: create $* failed: $(cat "$ROOT/fixture.err")" >&2
  exit 2
}

step() {
  case "$1" in
    # The bare world: the checkout and its origin, nothing else.
    -) ;;
    wt) fixture_create topic ;;
    # The topic branch has a commit of its own and is published.
    push)
      printf 'feature\n' >"$WT/feature.txt"
      git -C "$WT" add feature.txt
      git -C "$WT" commit -q -m feature
      git -C "$WT" push -q -u origin topic
      ;;
    # A commit of its own, never pushed, and an uncommitted file beside it.
    local-work)
      printf 'local commit\n' >"$WT/local.txt"
      git -C "$WT" add local.txt
      git -C "$WT" commit -q -m 'unpublished local work'
      printf 'dirty\n' >"$WT/dirty.txt"
      ;;
    # main moves on after the topic branch, so an implicit reuse would rebase.
    advance)
      printf 'main advance\n' >"$MAIN/main-advance.txt"
      git -C "$MAIN" add main-advance.txt
      git -C "$MAIN" commit -q -m 'advance main'
      git -C "$MAIN" push -q origin main
      ;;
    open-pr) touch "$ROOT/gh-state/open-pr" ;;
    pr-json)
      printf '{"headRefName":"topic","headRefOid":"%s","isCrossRepository":false}\n' \
        "$(git -C "$MAIN" rev-parse origin/topic)" >"$ROOT/gh-state/pr-42.json"
      ;;
    lock) git -C "$MAIN" worktree lock --reason 'owner session is active' "$WT" ;;
    # The checkout and its local branch are gone; only the remote and the PR remain.
    dropped)
      git -C "$MAIN" worktree remove "$WT"
      git -C "$MAIN" branch -D topic >/dev/null
      ;;
    # A branch on the remote only.
    remote:*) remote_only "${1#remote:}" ;;
    # A second remote that cannot be reached, or one that holds the branch.
    flaky-remote) git -C "$MAIN" remote add flaky "$ROOT/does-not-exist.git" ;;
    second:*)
      git init -q --bare -b main "$ROOT/second.git"
      git -C "$MAIN" remote add second "$ROOT/second.git"
      git -C "$MAIN" branch "${1#second:}" main
      git -C "$MAIN" push -q second "${1#second:}"
      git -C "$MAIN" branch -D "${1#second:}" >/dev/null
      ;;
    no-origin) git -C "$MAIN" remote remove origin ;;
    # A local branch beside main.
    local:*) git -C "$MAIN" branch "${1#local:}" main ;;
    # The topic branch checked out in the main checkout itself.
    main-checkout) git -C "$MAIN" checkout -q -b topic ;;
    # A worktree for another branch, published.
    other-wt)
      fixture_create other
      git -C "$TREES_DIR/other" push -q -u origin other
      ;;
    # The target directory exists with no .git: a concurrent or interrupted creator.
    orphan)
      mkdir -p "$WT"
      printf 'keep\n' >"$WT/owner-marker"
      ;;
    # The trees base inside the checkout, where `git -C` could search upward.
    in-repo)
      printf 'WORKTREE_BASE_DIR="trees"\n' >"$MAIN/.env.local"
      TREES_DIR="$MAIN/trees"
      WT="$TREES_DIR/topic"
      ;;
    fail-gh) touch "$ROOT/gh-state/fail-gh" ;;
    # A git whose every `fetch` fails, ahead of the real one on the row's PATH.
    fail-fetch)
      cat >"$ROOT/bin/git" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
for arg in "$@"; do
  if [[ "$arg" == "fetch" ]]; then
    printf 'simulated fetch failure\n' >&2
    exit 42
  fi
done
exec "${GIT_REAL:?}" "$@"
STUB
      chmod +x "$ROOT/bin/git"
      ROW_ENV+=(GIT_REAL="$REAL_GIT")
      ;;
    bad-origin) git -C "$MAIN" remote set-url origin "$ROOT/missing-origin.git" ;;
    bot) ROW_ENV+=(BOT_NAME=robot BOT_EMAIL=robot@example.test) ;;
    *)
      echo "UNKNOWN-STEP: $1" >&2
      exit 2
      ;;
  esac
}

remote_only() {
  git -C "$MAIN" branch "$1" main
  git -C "$MAIN" push -q origin "$1"
  git -C "$MAIN" branch -D "$1" >/dev/null
}

build() {
  local word
  ROOT="$TMP_ROOT/$1"
  shift
  MAIN="$ROOT/main"
  TREES_DIR="$ROOT/trees"
  WT="$TREES_DIR/topic"
  ROW_ENV=()
  make_repo "$ROOT"
  for word in "$@"; do step "$word"; done
  PRE="$(topic_head)"
  END="$(git -C "$MAIN" rev-parse HEAD)"
}

# The topic branch's head: the registered worktree's, else the remote's, else
# none. A bare directory is never asked, since `git -C` would search upward
# from it and answer for the main checkout.
topic_head() {
  if [[ -e "$WT/.git" ]]; then
    git -C "$WT" rev-parse HEAD 2>/dev/null || { echo "FIXTURE: the topic worktree at $WT has no readable HEAD" >&2; exit 2; }
  else
    git -C "$MAIN" rev-parse origin/topic 2>/dev/null || true
  fi
}

# An oid by name: main's head at fixture end, the topic head the row was
# built with, a commit built on main's head, or other.
head_alias() {
  local oid="$1"
  if [[ "$oid" == "$END" ]]; then
    printf 'end'
  elif [[ "$oid" == "$PRE" ]]; then
    printf 'pre'
  elif [[ "$(git -C "$MAIN" rev-parse "$oid~1" 2>/dev/null)" == "$END" ]]; then
    printf 'on-end'
  else
    printf 'other'
  fi
}

# main=<branch>@<head>/<porcelain> cfg=<extensions.worktreeConfig> trees=<dir:reg@branch@head|dir:dir[file:line]>,... branches=<beside main> dirty=<topic porcelain>
state() {
  local trees="" name dir dirty branches main_dirty
  for dir in "$TREES_DIR"/*; do
    [[ -e "$dir" ]] || continue
    name="${dir##*/}"
    if git -C "$MAIN" worktree list --porcelain | grep -qxF "worktree $dir"; then
      trees="$trees,$name:reg@$(git -C "$dir" branch --show-current)@$(head_alias "$(git -C "$dir" rev-parse HEAD)")"
    else
      trees="$trees,$name:dir[$(for f in "$dir"/* "$dir"/.[!.]*; do [[ -e "$f" ]] || continue; printf '%s:%s' "${f##*/}" "$(head -1 "$f" 2>/dev/null || printf dir)"; done)]"
    fi
  done
  branches="$(git -C "$MAIN" for-each-ref --format='%(refname)' refs/heads | sed 's|^refs/heads/||' | grep -vx main | paste -s -d ',' -)"
  dirty=""
  [[ -e "$WT/.git" ]] && dirty="$(git -C "$WT" status --porcelain | paste -s -d ',' -)"
  main_dirty="$(git -C "$MAIN" status --porcelain | paste -s -d ',' -)"
  printf 'main=%s@%s/%s cfg=%s trees=%s branches=%s dirty=%s' \
    "$(git -C "$MAIN" branch --show-current)" "$(head_alias "$(git -C "$MAIN" rev-parse HEAD)")" "${main_dirty:-clean}" \
    "$(git -C "$MAIN" config --get extensions.worktreeConfig 2>/dev/null || printf '%s' -)" \
    "${trees#,}" "${branches:--}" "${dirty:--}"
}

# Paths by their names; stdout is cut at its first Usage line, which pins
# which usage text printed without pinning the help body.
alias_text() {
  { if [[ "${1:-}" == usage ]]; then sed '/^Usage: /q'; else cat; fi; } |
    sed -e "s|$WT|<topic>|g" -e "s|$TREES_DIR/other|<other>|g" -e "s|$MAIN|<main>|g" -e "s|$ROOT|<root>|g" -e "s|$WORKTREE_SCRIPT|<worktree>|g" \
      -e 's/;/\\;/g' | paste -s -d ';' -
}

run() {
  local -a argv
  local rc=0
  read -r -a argv <<<"$1"
  (cd "$MAIN" && env PATH="$ROOT/bin:$PATH" GH_STATE="$ROOT/gh-state" ${ROW_ENV[@]+"${ROW_ENV[@]}"} "$WORKTREE_SCRIPT" ${argv[@]+"${argv[@]}"} >"$ROOT/out" 2>"$ROOT/err") || rc=$?
  printf 'rc=%s out=%s err=%s %s' "$rc" "$(alias_text usage <"$ROOT/out")" "$(alias_text <"$ROOT/err")" "$(state)"
}

out_text() {
  case "$1" in
    -) printf '' ;;
    topic) printf '<topic>' ;;
    other) printf '<other>' ;;
    usage) printf 'Usage: worktree create <ID> [BRANCH] [options]' ;;
    *) printf 'UNKNOWN-OUT-SPEC:%s' "$1" ;;
  esac
}

# The implicit-reuse refusal of the topic worktree for an issue, with the
# lines its state adds: `clean|dirty`, `up` (a tracking upstream) or `noup`,
# `pr` (the open PR), `lock`.
implicit_reuse() {
  local issue="$1" tree="$2" upstream="$3" pr="${4:-}" lock="${5:-}"
  printf "Active work already exists for '%s'\\; refusing implicit reuse.;  Worktree: <topic>;  Branch: topic;  Working tree: %s" "$issue" "$tree"
  case "$upstream" in
    up) printf ';  Upstream: origin/topic (ahead 0, behind 0)' ;;
    noup) printf ';  Upstream: none (branch is unpublished or not tracking a remote)' ;;
  esac
  [[ "$pr" == pr ]] && printf ';  Open PR: #42 https://example.test/pull/42'
  [[ "$lock" == lock ]] && printf ';  Worktree lock: owner session is active'
  printf ';No local branch was rebased or modified.;Inspect or monitor the existing work instead of spawning another implementer.;If this session owns the worktree, opt in explicitly:;  <worktree> create %s --reuse;Use --restack instead only when intentionally resolving a rebase conflict.' "$issue"
}

# The duplicate-branch refusal for a branch with a signal: `pr`, `local`, or
# `remote`.
duplicate() {
  local branch="$1" signal="$2"
  printf "Active work already exists for 'topic'\\; refusing to create a duplicate worktree.;  Branch: %s;  Signal: " "$branch"
  case "$signal" in
    pr) printf 'open pull request (#42)' ;;
    local) printf 'existing local branch' ;;
    remote) printf 'existing remote branch (origin/%s)' "$branch" ;;
    second) printf 'existing remote branch (second/%s)' "$branch" ;;
  esac
  printf ';No worktree was created and no local branch was rebased or modified.;Inspect or monitor the existing work instead of spawning another implementer.;'
  if [[ "$signal" == pr ]]; then
    printf 'To inspect that PR in a worktree intentionally, pass --pr <number>.'
  else
    printf 'To check out that branch intentionally, pass --base %s.' "$branch"
  fi
}

err_text() {
  local spec a b c d
  case "$1" in
    -) printf '' ;;
    # implicit:<issue>:<tree>,<upstream>[,pr][,lock]
    implicit:*) spec="${1#implicit:}"; IFS=, read -r a b c d <<<"${spec#*:}"; implicit_reuse "${spec%%:*}" "$a" "$b" "${c:-}" "${d:-}" ;;
    dup:*) spec="${1#dup:}"; duplicate "${spec%:*}" "${spec##*:}" ;;
    main-checkout) printf "Active work already exists for 'topic'\\; refusing to create a duplicate worktree.;  Branch: topic;  Signal: checked out in the main checkout (<main>);No worktree was created and no local branch was rebased or modified.;The main checkout is never issue work and the branch cannot be checked out twice.;Move that work off the main checkout (or pick another issue id), then retry." ;;
    incomplete) printf "Active or incomplete worktree path already exists for 'topic': <topic>;The exact path is not a registered worktree of <main>.;Refusing to delete, replace, or reuse it automatically. Inspect it, then remove it explicitly if abandoned." ;;
    gh-fail) printf "Error: Could not query open pull requests for branch 'topic'\\; refusing to assume it is unowned.;  simulated gh failure" ;;
    fetch-fail) printf "Error: Could not refresh remote 'origin' for authoritative worktree ownership discovery.;  simulated fetch failure" ;;
    # `+` composes two specs: discovery runs before and after the claim lock, so
    # its warning prints once per pass.
    *+*) err_text "${1%%+*}"; printf ';'; err_text "${1#*+}" ;;
    skipped-remote:*) printf "warning: skipping unreachable remote '%s' for ownership discovery" "${1#skipped-remote:}" ;;
    no-origin) printf "Error: Remote 'origin' is required for authoritative worktree ownership discovery." ;;
    remote-fail) printf "Error: Could not query remote 'origin' for authoritative worktree ownership discovery.;  fatal: '<root>/missing-origin.git' does not appear to be a git repository;  fatal: Could not read from remote repository.;  ;  Please make sure you have the correct access rights;  and the repository exists." ;;
    unknown-option) printf "Error: unknown option '--bogus' for create;Run: <worktree> create --help" ;;
    default-branch) printf "Error: 'main' is the default branch and cannot be claimed as an issue work branch.;To base new work on it, run: <worktree> create topic --base main" ;;
    *) printf 'UNKNOWN-ERR-SPEC:%s' "$1" ;;
  esac
}

# label|fixture (- for the bare world)|command|rc|out|err|state
ROWS='
a published, locked, PR-backed worktree refuses implicit reuse with every signal and moves nothing|wt push advance open-pr lock|create topic|75|-|implicit:topic:clean,up,pr,lock|main=main@end/clean cfg=true trees=topic:reg@topic@pre branches=topic dirty=-
--reuse rebases the owned branch onto the advanced main|wt push advance open-pr|create topic --reuse|0|topic|-|main=main@end/clean cfg=true trees=topic:reg@topic@on-end branches=topic dirty=-
an open PR still owns the branch after its checkout is dropped|wt push open-pr dropped|create topic|75|-|dup:topic:pr|main=main@end/clean cfg=true trees= branches=- dirty=-
--pr checks the PR head out for inspection|wt push open-pr dropped pr-json|create topic --pr 42|0|topic|-|main=main@end/clean cfg=true trees=topic:reg@topic@pre branches=topic dirty=-
dirty, unpublished local work is ownership on its own|wt local-work|create topic|75|-|implicit:topic:dirty,noup|main=main@end/clean cfg=true trees=topic:reg@topic@pre branches=topic dirty=?? dirty.txt
a remote branch is ownership with no PR and no checkout|remote:topic|create topic|75|-|dup:topic:remote|main=main@end/clean cfg=- trees= branches=- dirty=-
an unreachable secondary remote is skipped with a warning and the claim proceeds|flaky-remote|create topic|0|topic|skipped-remote:flaky+skipped-remote:flaky|main=main@end/clean cfg=true trees=topic:reg@topic@end branches=topic dirty=-
a branch on a reachable secondary remote is ownership, naming that remote|flaky-remote second:topic|create topic|75|-|skipped-remote:flaky+dup:topic:second|main=main@end/clean cfg=- trees= branches=- dirty=-
no origin remote at all refuses before any write|no-origin|create topic|1|-|no-origin|main=main@end/clean cfg=- trees= branches=- dirty=-
an unregistered target directory is preserved, not replaced|orphan|create topic|75|-|incomplete|main=main@end/clean cfg=- trees=topic:dir[owner-marker:keep] branches=- dirty=-
--reuse of an unregistered target inside the checkout registers nothing and keeps its bytes|in-repo orphan|create topic --reuse|75|-|incomplete|main=main@end/?? trees/ cfg=- trees=topic:dir[owner-marker:keep] branches=- dirty=-
--from is stopped by a remote branch before a divergent checkout exists|remote:topic|create topic --from main|75|-|dup:topic:remote|main=main@end/clean cfg=- trees= branches=- dirty=-
BOT_NAME/<id> as a local branch is a candidate|local:robot/topic bot|create topic|75|-|dup:robot/topic:local|main=main@end/clean cfg=- trees= branches=robot/topic dirty=-
BOT_NAME/<id> on the remote is a candidate|remote:robot/topic bot|create topic|75|-|dup:robot/topic:remote|main=main@end/clean cfg=- trees= branches=- dirty=-
a failed PR query is uncertainty: nothing is created|fail-gh|create topic|1|-|gh-fail|main=main@end/clean cfg=- trees= branches=- dirty=-
a failed final fetch stops before any mutation|fail-fetch|create topic|1|-|fetch-fail|main=main@end/clean cfg=- trees= branches=- dirty=-
an unreachable origin stops before the claim lock|bad-origin|create topic|1|-|remote-fail|main=main@end/clean cfg=- trees= branches=- dirty=-
--help prints usage and creates nothing|-|create --help|0|usage|-|main=main@end/clean cfg=- trees= branches=- dirty=-
-h prints usage and creates nothing|-|create -h|0|usage|-|main=main@end/clean cfg=- trees= branches=- dirty=-
an option-looking issue id is refused before it becomes a path|-|create --bogus|1|-|unknown-option|main=main@end/clean cfg=- trees= branches=- dirty=-
an unknown flag after the id creates neither branch nor worktree|-|create topic --bogus|1|-|unknown-option|main=main@end/clean cfg=- trees= branches=- dirty=-
a positional branch name is accepted beside the id|-|create topic custom-branch-name|0|topic|-|main=main@end/clean cfg=true trees=topic:reg@custom-branch-name@end branches=custom-branch-name dirty=-
--base <default> with no prior work checks out a new issue branch on origin/<default>|-|create topic --base main|0|topic|-|main=main@end/clean cfg=true trees=topic:reg@topic@end branches=topic dirty=-
--base origin/<default> does the same|-|create topic --base origin/main|0|topic|-|main=main@end/clean cfg=true trees=topic:reg@topic@end branches=topic dirty=-
a positional work branch named as the default branch is refused loudly|-|create topic main|1|-|default-branch|main=main@end/clean cfg=- trees= branches=- dirty=-
--base <default> for an owned issue still refuses, naming the issue worktree (the registered worktree stops it before --base is read; the row guards the composite #1034 regression)|wt|create topic --base main|75|-|implicit:topic:clean,noup|main=main@end/clean cfg=true trees=topic:reg@topic@end branches=topic dirty=-
the topic branch checked out in the main checkout blocks the id without offering --reuse|main-checkout|create topic|75|-|main-checkout|main=topic@end/clean cfg=- trees= branches=topic dirty=-
a local branch literally named origin/<default> keeps its ownership checks|local:origin/main|create topic origin/main|75|-|dup:origin/main:local|main=main@end/clean cfg=- trees= branches=origin/main dirty=-
a non-default --base with a live worktree refuses with that worktree|wt push|create other --base topic|75|-|implicit:other:clean,up|main=main@end/clean cfg=true trees=topic:reg@topic@pre branches=topic dirty=-
a non-default --base of an unclaimed remote branch checks that branch out|remote:feature|create other --base feature|0|other|-|main=main@end/clean cfg=true trees=other:reg@feature@end branches=feature dirty=-
'

echo "=== create against active work ==="
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

# --- the concurrent claim -------------------------------------------------------
# Two claimers both pass their read-only preliminary discovery (the gh stub
# pauses so they overlap). The repository-local issue lock makes exactly one
# add; the waiter reruns the final checks and exits 75 without a duplicate
# mutation. Which one wins is not deterministic, so this stays beside the table.
build concurrent
touch "$ROOT/gh-state/slow-gh"
set +e
(cd "$MAIN" && env PATH="$ROOT/bin:$PATH" GH_STATE="$ROOT/gh-state" "$WORKTREE_SCRIPT" create topic >"$ROOT/a.out" 2>"$ROOT/a.err") &
race_pid_a=$!
(cd "$MAIN" && env PATH="$ROOT/bin:$PATH" GH_STATE="$ROOT/gh-state" "$WORKTREE_SCRIPT" create TOPIC >"$ROOT/b.out" 2>"$ROOT/b.err") &
race_pid_b=$!
wait "$race_pid_a"
race_code_a=$?
wait "$race_pid_b"
race_code_b=$?
set -e
race_codes="$race_code_a:$race_code_b"
[[ "$race_codes" == "75:0" ]] && race_codes="0:75"
assert_eq "$race_codes $(state)" "0:75 main=main@end/clean cfg=true trees=topic:reg@topic@end branches=topic dirty=-" \
  "a concurrent claim makes one registered worktree and one active-work exit"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
