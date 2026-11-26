#!/usr/bin/env bash
# `worktree merged <ID>`: the read-only merge question, for a caller that must
# decide before it asks for a tree. One table, a row per forge answer.
#
# The question ancestry cannot answer: a squash merge rewrites the branch into
# a fresh commit on the default branch, so the branch tip is an ancestor of
# nothing and every merged branch reads as pending forever. The proof is
# COMMIT identity — the tip this repository holds right now must be the exact
# head some merged pull request carried — so a later commit on the branch is a
# definite "not merged", and a lookup that cannot answer is never read as one.
#
# A row names the forge's answer, and pins the exit status, stdout, and the
# message record on stderr. The three statuses are the whole contract the
# launcher reads: 0 keeps the tree, 1 rebases it, 2 says the question went
# unanswered.
set -euo pipefail
# The fixtures' origin is a local path that names no GitHub repository, so
# the suite names the default branch.
export WORKTREE_DEFAULT_BRANCH=main
# A pre-commit hook exports GIT_DIR and GIT_INDEX_FILE, which point every git
# call below at the real repository; -C overrides neither.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/messages.sh
source "$TEST_DIR/lib/messages.sh"
PACKAGE_DIR="$(cd "$TEST_DIR/.." && pwd)"
WORKTREE_SCRIPT="${WORKTREE_SCRIPT:-$PACKAGE_DIR/scripts/worktree}"
TMP_ROOT="$(mktemp -d)" || { echo "worktree_merged_verb: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "worktree_merged_verb: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "worktree_merged_verb: scratch=resolve-failed" >&2; exit 1; }
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
# GH_ROW is the answer for the row: "<head-oid> <number> <merge-commit>", empty
# for a branch no merged pull request carries. --state is honoured because the
# script asks this command for OPEN pull requests elsewhere and must never be
# handed a merged row as an ownership signal. lib/gh-credential.sh answers for
# the credential first.
mkdir -p "$TMP_ROOT/bin"
{
  printf '#!/usr/bin/env bash\nset -euo pipefail\nsource %q\n' "$TEST_DIR/lib/gh-credential.sh"
  cat <<'STUB'
if [[ "${GH_ROW:-}" == FAIL ]]; then
  echo "gh: could not reach api.github.com" >&2
  exit 1
fi
read -r head number commit <<<"${GH_ROW:-}"
want_state=""
prev=""
for arg in "$@"; do
  [[ "$prev" != "--state" ]] || want_state="$arg"
  prev="$arg"
done
case "${1:-}:${2:-}" in
  pr:list) [[ -n "${head:-}" && "$want_state" == merged ]] && printf '%s %s\n' "$head" "$number" ;;
  pr:view) printf '%s\n' "${commit:-}" ;;
esac
exit 0
STUB
} >"$TMP_ROOT/bin/gh"
chmod +x "$TMP_ROOT/bin/gh"

# A PATH carrying every tool the script reaches for EXCEPT gh: shadowing gh is
# impossible, `command -v` answers from PATH alone.
mkdir -p "$TMP_ROOT/nogh"
for tool in bash sh git grep sed awk cat cut tr sort uniq wc head tail find ln rm rmdir \
            mkdir mv cp ls readlink realpath dirname basename mktemp date id \
            hostname ps kill sleep touch chmod stat printf env flock jq paste; do
  tool_path="$(command -v "$tool" 2>/dev/null || true)"
  [[ -n "$tool_path" ]] && ln -sf "$tool_path" "$TMP_ROOT/nogh/$tool"
done

# --- the world ----------------------------------------------------------------
# One checkout whose `topic` branch holds a commit that is not on main, and a
# main whose tip carries that work as a separate commit: the squash-merge
# shape, where ancestry proves nothing in either direction.

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
git -C "$MAIN" branch topic
git -C "$MAIN" worktree add -q "$TMP_ROOT/trees/topic" topic
printf 'feature\n' >"$TMP_ROOT/trees/topic/file.txt"
git -C "$TMP_ROOT/trees/topic" add file.txt
git -C "$TMP_ROOT/trees/topic" commit -q -m 'topic: work'
TIP="$(git -C "$MAIN" rev-parse refs/heads/topic)"
printf 'feature\n' >"$MAIN/file.txt"
git -C "$MAIN" add file.txt
git -C "$MAIN" commit -q -m 'topic: work (squashed)'
git -C "$MAIN" push -q origin main
SQUASH="$(git -C "$MAIN" rev-parse refs/heads/main)"
if git -C "$MAIN" merge-base --is-ancestor topic origin/main; then
  echo "FIXTURE: the squashed branch is an ancestor of origin/main" >&2
  exit 2
fi
STALE="$(git -C "$MAIN" rev-parse refs/heads/main~1)"

# A second tree whose ISSUE ID and CHECKED-OUT BRANCH differ, the shape a
# positional branch name, --from, or a fork-pr-<n> inspection tree produces.
# refs/heads/alias is left standing at the merged tip, so a lookup that asks
# about the id rather than the tree answers "merged" for a tree whose real
# branch never was.
git -C "$MAIN" branch alias "$TIP"
git -C "$MAIN" branch sidework main
git -C "$MAIN" worktree add -q "$TMP_ROOT/trees/alias" sidework
printf 'side\n' >"$TMP_ROOT/trees/alias/file.txt"
git -C "$TMP_ROOT/trees/alias" add file.txt
git -C "$TMP_ROOT/trees/alias" commit -q -m 'sidework: work'

# A registered worktree with nothing checked out, the state a paused restack
# leaves behind, and an id with no registered worktree at all: the two ends of
# the branch resolution.
git -C "$MAIN" branch detachwork main
git -C "$MAIN" worktree add -q "$TMP_ROOT/trees/detached" detachwork
git -C "$TMP_ROOT/trees/detached" checkout -q --detach
# The stale ref the fallback would read: refs/heads/detached stands at the
# merged tip while the tree it names has nothing checked out, so falling back
# to the id's own name answers "merged" for a tree whose work never was. The
# assertion named "a registered worktree with nothing checked out leaves the
# question unanswered, never falling back to the id's name" is what reddens.
git -C "$MAIN" branch detached "$TIP"
git -C "$MAIN" branch lonely "$TIP"

# --- rendering ------------------------------------------------------------------

alias_text() {
  message_records |
    sed -e "s|$SQUASH|<squash>|g" -e "s|$TIP|<tip>|g" |
    paste -s -d ';' -
}

run() { run_id topic "$@"; }

run_id() {
  local id="$1" row="$2" path="$3" rc=0
  ( cd "$MAIN" && PATH="$path" GH_ROW="$row" "$WORKTREE_SCRIPT" merged "$id" \
      >"$TMP_ROOT/out" 2>"$TMP_ROOT/err" ) || rc=$?
  printf 'rc=%s out=%s err=%s' "$rc" "$(alias_text <"$TMP_ROOT/out")" "$(alias_text <"$TMP_ROOT/err")"
}

# --- the rows -------------------------------------------------------------------
# label|forge answer|expected

GH_PATH="$TMP_ROOT/bin:$PATH"
NOGH_PATH="$TMP_ROOT/nogh"

echo "=== worktree merged: the read-only merge question ==="

assert_eq "$(run "$TIP 42 $SQUASH" "$GH_PATH")" "rc=0 out=<squash> err=" \
  "a pull request merged at this exact tip answers with its merge commit"
assert_eq "$(run "" "$GH_PATH")" "rc=1 out= err=worktree-unmerged: topic" \
  "a branch no merged pull request carries is not merged"
assert_eq "$(run "$STALE 42 $SQUASH" "$GH_PATH")" "rc=1 out= err=worktree-unmerged: topic" \
  "a merged pull request whose head is not this tip is not this tip's merge"
assert_eq "$(run "$TIP 42" "$GH_PATH")" "rc=2 out= err=worktree-merge-unverified: topic" \
  "a merged pull request with no readable merge commit leaves the question unanswered"
assert_eq "$(run FAIL "$GH_PATH")" "rc=2 out= err=worktree-merge-unverified: topic" \
  "a failing forge query leaves the question unanswered"
assert_eq "$(run "$TIP 42 $SQUASH" "$NOGH_PATH")" "rc=2 out= err=worktree-merge-unverified: topic" \
  "no gh on PATH leaves the question unanswered"
assert_eq "$(run_id alias "$TIP 42 $SQUASH" "$GH_PATH")" "rc=1 out= err=worktree-unmerged: sidework" \
  "the question is asked of the branch the issue tree has checked out, not of the id's own name"
assert_eq "$(run_id detached "$TIP 42 $SQUASH" "$GH_PATH")" "rc=2 out= err=worktree-merge-unverified: detached" \
  "a registered worktree with nothing checked out leaves the question unanswered, never falling back to the id's name"
assert_eq "$(run_id lonely "$TIP 42 $SQUASH" "$GH_PATH")" "rc=0 out=<squash> err=" \
  "an id with no registered worktree is answered from the id's own branch name"

echo
echo "=== the credential the reads use ==="

# The restack and reuse paths ask this same question. The caller's own tokens
# never reach these rows; a row names the credentials it holds, and `reads`
# lists the one each pull-request read used.
run_credential() { # SCRIPT ENV...
  local script="$1" rc=0
  shift
  : >"$TMP_ROOT/credential.log"
  ( cd "$MAIN" && env -u GH_TOKEN -u GITHUB_TOKEN -u GH_BOT_TOKEN -u KENDEX_GITHUB_VALIDATED_TOKEN \
      PATH="$GH_PATH" GH_ROW="$TIP 42 $SQUASH" GH_CREDENTIAL_LOG="$TMP_ROOT/credential.log" "$@" \
      "$script" merged topic >"$TMP_ROOT/out" 2>"$TMP_ROOT/err" ) || rc=$?
  printf 'rc=%s out=%s err=%s reads=%s' "$rc" "$(alias_text <"$TMP_ROOT/out")" "$(alias_text <"$TMP_ROOT/err")" \
    "$(awk '$2 == "pr" { print $1 }' "$TMP_ROOT/credential.log" | paste -s -d , -)"
}

# label|credentials|expected
CREDENTIAL_ROWS='
a stale GH_TOKEN yields to the keyring login, which answers the question|GH_TOKEN=ghp_stale|rc=0 out=<squash> err=worktree-github-auth: fallback=keyring reads=keyring,keyring
a stale GITHUB_TOKEN yields to the keyring login, which answers the question|GITHUB_TOKEN=ghp_stale|rc=0 out=<squash> err=worktree-github-auth: fallback=keyring reads=keyring,keyring
a working GH_TOKEN keeps its identity beside a keyring login|GH_TOKEN=ghp_good|rc=0 out=<squash> err= reads=ghp_good,ghp_good
a stale token with no keyring login leaves the question unanswered, never unmerged|GH_TOKEN=ghp_stale GH_KEYRING=none|rc=2 out= err=worktree-merge-unverified: topic reads=ghp_stale
a refused GH_TOKEN placeholder yields to a working GITHUB_TOKEN, never to the keyring|GH_TOKEN=stale_placeholder GITHUB_TOKEN=ghp_good|rc=0 out=<squash> err= reads=ghp_good,ghp_good
a GH_BOT_TOKEN beside a working GITHUB_TOKEN leaves the reads to GITHUB_TOKEN|GITHUB_TOKEN=ghp_good GH_BOT_TOKEN=ghp_stale_bot|rc=0 out=<squash> err= reads=ghp_good,ghp_good
a GH_BOT_TOKEN alone is no read credential, so the keyring login answers|GH_BOT_TOKEN=ghp_stale_bot|rc=0 out=<squash> err= reads=keyring,keyring
'
while IFS='|' read -r label credentials want; do
  [[ -n "$label$credentials$want" ]] || continue
  # shellcheck disable=SC2086
  assert_eq "$(run_credential "$WORKTREE_SCRIPT" $credentials)" "$want" "$label"
done <<<"$CREDENTIAL_ROWS"

echo
echo "=== must-fail control: with the keyring fallback cut, a stale token leaves the question unanswered ==="

# The package and the github skill it reads auth through, copied as installed
# side by side; the planted defect skips the sanitizer and keeps its text.
mkdir -p "$TMP_ROOT/auth-pkg"
cp -R "$PACKAGE_DIR" "$TMP_ROOT/auth-pkg/worktree"
cp -R "$PACKAGE_DIR/../github" "$TMP_ROOT/auth-pkg/github"
AUTH_MUTANT="$TMP_ROOT/auth-pkg/worktree/scripts/worktree"
assert_eq "$(grep -c '^  kendex_github_sanitize_gh_env >/dev/null$' "$AUTH_MUTANT")" "1" \
  "control finds the sanitizer call"
sed -i.bak 's/^  kendex_github_sanitize_gh_env >\/dev\/null$/  : kendex_github_sanitize_gh_env >\/dev\/null/' "$AUTH_MUTANT"
assert_eq "$(cmp -s "$AUTH_MUTANT.bak" "$AUTH_MUTANT" && printf unchanged || printf changed)" "changed" \
  "control disarms it only in its private copy"
rm -f -- "${AUTH_MUTANT:?}.bak"
assert_eq "$(run_credential "$AUTH_MUTANT" GH_TOKEN=ghp_stale)" \
  "rc=2 out= err=worktree-merge-unverified: topic reads=ghp_stale" \
  "control: the mutant reads with the stale token and answers nothing"

echo
echo "=== must-fail control: with the merge-commit check cut, an unreadable answer passes as merged ==="

# Row four is the whole fail-closed claim: a pull request the forge calls
# merged, with nothing readable where its merge commit belongs, must not
# authorize keeping a tree. The defect planted here is the check that reads the
# value, on a private package copy; the same query then answers 0 with a commit
# nobody can resolve.
mkdir -p "$TMP_ROOT/pkg"
cp -R "$PACKAGE_DIR" "$TMP_ROOT/pkg/worktree"
MUTANT="$TMP_ROOT/pkg/worktree/scripts/worktree"
assert_eq "$(grep -c 'if ! \[\[ "$oid" =~ \^\[0-9a-f\]{7,64}\$ \]\]; then' "$MUTANT")" "1" \
  "control finds the merge-commit check"
sed -i.bak 's/if ! \[\[ "$oid" =~ \^\[0-9a-f\]{7,64}\$ \]\]; then/if false; then/' "$MUTANT"
rm -f -- "${MUTANT:?}.bak"
assert_eq "$(grep -c 'if false; then' "$MUTANT")" "1" "control disarms it only in its private copy"
MUTANT_RC=0
( cd "$MAIN" && PATH="$GH_PATH" GH_ROW="$TIP 42" "$MUTANT" merged topic \
    >"$TMP_ROOT/mutant.out" 2>"$TMP_ROOT/mutant.err" ) || MUTANT_RC=$?
assert_eq "$MUTANT_RC" "0" "control: the mutant answers merged on an unreadable merge commit"
assert_eq "$(grep -c '^worktree-merge-unverified: ' "$TMP_ROOT/mutant.err" || true)" "0" \
  "control: the mutant leaves the unanswered question unrecorded"

echo
echo "=== worktree release-branches: what a local setting cannot make the base hold ==="

# orch's close test runs the release through a lane close: a squash-merged
# head, a probe at an ancestor, an unmerged branch, a recovery/ branch, a
# refused delete and a branch named for another item. These rows hold what
# the checkout's own Git state could otherwise turn into a delete of work the
# base lacks. Each row is a fresh checkout whose origin holds main and the
# item's branch ken-r at a commit whose change conflicts with main's: main
# edits line two, ken-r deletes lines two and three, so a union merge of the
# two writes main's own file.
release_world() { # NAME -> RELEASE_MAIN RELEASE_ORIGIN RELEASE_TIP
  local root="$TMP_ROOT/release-$1"
  RELEASE_MAIN="$root/main"
  RELEASE_ORIGIN="$root/origin.git"
  git init -q -b main "$RELEASE_MAIN"
  git init -q --bare "$RELEASE_ORIGIN"
  fixture_quiet "$RELEASE_MAIN"
  fixture_quiet "$RELEASE_ORIGIN"
  git -C "$RELEASE_MAIN" config user.email test@example.com
  git -C "$RELEASE_MAIN" config user.name Test
  git -C "$RELEASE_MAIN" config commit.gpgsign false
  git -C "$RELEASE_MAIN" remote add origin "$RELEASE_ORIGIN"
  printf 'one\ntwo\nthree\nfour\n' >"$RELEASE_MAIN/file.txt"
  git -C "$RELEASE_MAIN" add file.txt
  git -C "$RELEASE_MAIN" commit -q -m base
  git -C "$RELEASE_MAIN" switch -q -c ken-r
  printf 'one\nfour\n' >"$RELEASE_MAIN/file.txt"
  git -C "$RELEASE_MAIN" commit -q -a -m 'item work'
  RELEASE_TIP="$(git -C "$RELEASE_MAIN" rev-parse HEAD)"
  git -C "$RELEASE_MAIN" switch -q main
  printf 'one\nTWO\nthree\nfour\n' >"$RELEASE_MAIN/file.txt"
  git -C "$RELEASE_MAIN" commit -q -a -m 'main work'
  git -C "$RELEASE_MAIN" push -q origin main ken-r
}

# Git's background maintenance stays off in a fixture repository the suite
# removes, set before its first commit, fetch or push.
fixture_quiet() { # REPO
  git -C "$1" config gc.auto 0
  git -C "$1" config maintenance.auto false
}

# RELEASE_SCRIPT runs the release, the package's own script unless a row
# names a private copy; ENV... is added to the run's environment.
release_run() { # [ENV...] -> rc, stdout records, origin heads
  local rc=0
  ( cd "$RELEASE_MAIN" && env "$@" "${RELEASE_SCRIPT:-$WORKTREE_SCRIPT}" release-branches KEN-R \
      >"$TMP_ROOT/out" 2>"$TMP_ROOT/err" ) || rc=$?
  printf 'rc=%s out=%s err=%s heads=%s' "$rc" \
    "$(message_records <"$TMP_ROOT/out" | sed "s|$RELEASE_TIP|<tip>|g" | paste -s -d ';' -)" \
    "$(message_records <"$TMP_ROOT/err" | paste -s -d ';' -)" \
    "$(git --git-dir="$RELEASE_ORIGIN" for-each-ref --format='%(refname:short)' refs/heads/ | paste -s -d , -)"
}

# A keep-current merge driver the checkout configures resolves the trial
# merge's conflict to main's own tree.
release_world driver
printf 'file.txt merge=keep\n' >"$RELEASE_MAIN/.git/info/attributes"
git -C "$RELEASE_MAIN" config merge.keep.driver true
assert_eq "$(release_run)" \
  "rc=0 out=worktree-branch-kept: ken-r <tip> unmerged err= heads=ken-r,main" \
  "a checkout's keep-current merge driver does not make the base hold a conflicting branch"

# A union merge driver set in the global attributes file, which Git reads
# whatever GIT_CONFIG_GLOBAL names, resolves the conflict to main's own tree.
release_world global-attributes
mkdir -p "$TMP_ROOT/release-global-attributes/xdg/git"
printf '* merge=union\n' >"$TMP_ROOT/release-global-attributes/xdg/git/attributes"
assert_eq "$(release_run XDG_CONFIG_HOME="$TMP_ROOT/release-global-attributes/xdg")" \
  "rc=0 out=worktree-branch-kept: ken-r <tip> unmerged err= heads=ken-r,main" \
  "a union merge driver in the global attributes file does not make the base hold a conflicting branch"

# A union merge driver both branches commit in .gitattributes.
release_world tree-attributes
printf '* merge=union\n' >"$RELEASE_MAIN/.gitattributes"
git -C "$RELEASE_MAIN" add .gitattributes
git -C "$RELEASE_MAIN" commit -q -m 'main: union attributes'
git -C "$RELEASE_MAIN" switch -q ken-r
printf '* merge=union\n' >"$RELEASE_MAIN/.gitattributes"
git -C "$RELEASE_MAIN" add .gitattributes
git -C "$RELEASE_MAIN" commit -q -m 'item: union attributes'
RELEASE_TIP="$(git -C "$RELEASE_MAIN" rev-parse HEAD)"
git -C "$RELEASE_MAIN" switch -q main
git -C "$RELEASE_MAIN" push -q origin main ken-r
assert_eq "$(release_run)" \
  "rc=0 out=worktree-branch-kept: ken-r <tip> unmerged err= heads=ken-r,main" \
  "a union merge driver the branches' own .gitattributes set does not make the base hold a conflicting branch"

# A graft the checkout records makes the item's tip a parent of main's.
release_world graft
git -C "$RELEASE_MAIN" replace --graft main main~1 "$RELEASE_TIP"
assert_eq "$(release_run)" \
  "rc=0 out=worktree-branch-kept: ken-r <tip> unmerged err= heads=ken-r,main" \
  "a checkout's graft does not make the base hold a branch the stored history keeps apart"

# origin's fetch URL names a repository whose main holds the item's tip; its
# push URL, which the deletes reach, names one whose main lacks it.
release_world split
git init -q --bare "$TMP_ROOT/release-split/fetch.git"
fixture_quiet "$TMP_ROOT/release-split/fetch.git"
git -C "$RELEASE_MAIN" push -q "$TMP_ROOT/release-split/fetch.git" "$RELEASE_TIP:refs/heads/main" "$RELEASE_TIP:refs/heads/ken-r"
git -C "$RELEASE_MAIN" remote set-url origin "$TMP_ROOT/release-split/fetch.git"
git -C "$RELEASE_MAIN" remote set-url --push origin "$RELEASE_ORIGIN"
assert_eq "$(release_run)" \
  "rc=2 out= err=worktree-branch-release-unread: origin-split heads=ken-r,main" \
  "split fetch and push URLs judge no branch, and the push destination keeps the item's branch"

# An SSH GitHub origin, which the GitHub route rewrites to HTTPS when gh is
# signed in: its fetch and push URLs are one remote, so the release passes
# the split check and reaches the listing, which GIT_ALLOW_PROTOCOL refuses
# here so the row reaches no network. Git's refusal precedes the record.
release_world ssh
git -C "$RELEASE_MAIN" remote set-url origin git@github.com:example/repo.git
SSH_RUN="$(release_run -u GH_TOKEN -u GITHUB_TOKEN -u GH_BOT_TOKEN -u KENDEX_GITHUB_VALIDATED_TOKEN \
  -u ORCH_GH_READ_TOKEN_FILE -u KENDEX_GITHUB_GIT_HTTPS_FALLBACK PATH="$GH_PATH" GIT_ALLOW_PROTOCOL=file)"
assert_eq "${SSH_RUN%% *} ${SSH_RUN##* } $(grep '^worktree-' "$TMP_ROOT/err" | paste -s -d ';' -)" \
  "rc=2 heads=ken-r,main worktree-branch-release-unread: list-failed status=128" \
  "an SSH GitHub origin's fetch and push URLs read as one remote under the GitHub route's rewrites"

# A branch alias named for the item, whose target is main.
release_world alias
git --git-dir="$RELEASE_ORIGIN" symbolic-ref refs/heads/ken-r-alias refs/heads/main
git -C "$RELEASE_MAIN" push -q origin --delete ken-r
assert_eq "$(release_run | sed "s|$(git -C "$RELEASE_MAIN" rev-parse main)|<main>|g")" \
  "rc=0 out=worktree-branch-kept: ken-r-alias <main> symbolic err= heads=ken-r-alias,main" \
  "a branch alias named for the item is kept, and its target with it"

echo
echo "=== must-fail control: past its budget the release judges no branch, and records each delete it ran ==="

# A private package copy whose budget is 5 seconds, and an origin whose
# pre-receive hook takes 6 seconds a push: the first held branch's delete
# starts inside the budget and ends past it. Without the budget every held
# branch is deleted.
release_world deadline
for n in 1 2 3; do
  git -C "$RELEASE_MAIN" push -q origin "main~1:refs/heads/ken-r-$n"
done
printf '#!/bin/sh\nsleep 6\n' >"$RELEASE_ORIGIN/hooks/pre-receive"
chmod +x "$RELEASE_ORIGIN/hooks/pre-receive"
mkdir -p "$TMP_ROOT/deadline-pkg"
cp -R "$PACKAGE_DIR" "$TMP_ROOT/deadline-pkg/worktree"
cp -R "$PACKAGE_DIR/../github" "$TMP_ROOT/deadline-pkg/github"
DEADLINE_SCRIPT="$TMP_ROOT/deadline-pkg/worktree/scripts/worktree"
assert_eq "$(grep -c '^RELEASE_BUDGET=60$' "$DEADLINE_SCRIPT")" "1" "control finds the release budget"
sed -i.bak 's/^RELEASE_BUDGET=60$/RELEASE_BUDGET=5/' "$DEADLINE_SCRIPT"
rm -f -- "${DEADLINE_SCRIPT:?}.bak"
DEADLINE_BASE="$(git -C "$RELEASE_MAIN" rev-parse main~1)"
assert_eq "$(RELEASE_SCRIPT="$DEADLINE_SCRIPT" release_run | sed "s|$DEADLINE_BASE|<base>|g")" \
  "rc=0 out=worktree-branch-kept: ken-r <tip> unmerged;worktree-branch-deleted: ken-r-1;worktree-branch-kept: ken-r-2 <base> unread deadline;worktree-branch-kept: ken-r-3 <base> unread deadline err= heads=ken-r,ken-r-2,ken-r-3,main" \
  "control: the delete that ran is recorded, and each branch past the budget is kept unjudged"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
