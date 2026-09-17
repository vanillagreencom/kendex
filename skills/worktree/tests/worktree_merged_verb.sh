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
# A pre-commit hook exports GIT_DIR and GIT_INDEX_FILE, which point every git
# call below at the real repository; -C overrides neither.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/messages.sh
source "$TEST_DIR/lib/messages.sh"
PACKAGE_DIR="$(cd "$TEST_DIR/.." && pwd)"
WORKTREE_SCRIPT="${WORKTREE_SCRIPT:-$PACKAGE_DIR/scripts/worktree}"
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

# --- the forge ----------------------------------------------------------------
# GH_ROW is the answer for the row: "<head-oid> <number> <merge-commit>", empty
# for a branch no merged pull request carries. --state is honoured because the
# script asks this command for OPEN pull requests elsewhere and must never be
# handed a merged row as an ownership signal.
mkdir -p "$TMP_ROOT/bin"
cat >"$TMP_ROOT/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
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
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
