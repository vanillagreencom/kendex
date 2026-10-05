#!/usr/bin/env bash
# Tests for the worktree-session-claim hook.
#
# The hook claims the linked worktree a session starts in through the
# worktree skill's session guard, found from the hook's own install. Each row
# installs the hook and the guard under a fixture HOME the way a global
# install lays them out, starts the hook in one directory of a fixture
# repository, and pins the hook's exit status, its stdout, the keyed first
# line of its stderr and the lease owner it leaves on the linked worktree.
#
# HOOK_UNDER_TEST overrides the script under test so the must-fail control (a
# hook that never runs the guard) can be run against these same assertions.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${HOOK_UNDER_TEST:-$(cd "$TEST_DIR/.." && pwd)/worktree-session-claim.sh}"
WORKTREE_SCRIPTS="$(cd "$TEST_DIR/../../skills/worktree/scripts" && pwd)"

PASS=0
FAIL=0
TMP_ROOT="$(mktemp -d)" || { echo "worktree-session-claim: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "worktree-session-claim: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "worktree-session-claim: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
ERR_FILE="$TMP_ROOT/stderr"
OUT_FILE="$TMP_ROOT/stdout"
# shellcheck source=lib/assert.sh
. "$TEST_DIR/lib/assert.sh"
# shellcheck source=lib/first-line.sh
. "$TEST_DIR/lib/first-line.sh"

MAIN="$TMP_ROOT/repo/main"
TREE="$TMP_ROOT/repo/tree"
OUTSIDE="$TMP_ROOT/outside"
mkdir -p "$MAIN" "$OUTSIDE"
git -C "$MAIN" init -q -b main
git -C "$MAIN" config user.email t@example.com
git -C "$MAIN" config user.name t
git -C "$MAIN" config gc.auto 0
git -C "$MAIN" config maintenance.auto false
git -C "$MAIN" commit -q --allow-empty -m init
git -C "$MAIN" worktree add -q -b tree "$TREE" main
mkdir -p "$TREE/sub"
GUARD="$WORKTREE_SCRIPTS/worktree-session-guard"

# The world a row names, setting WORLD_HOME and WORLD_HOOKS, the directory
# the hook runs from: `installed` lays the hook and the guard out where a
# global install puts them, `project` where a project install in the worktree
# does, `bare` installs the global hook alone, and `repo-only` puts the guard
# in the open worktree alone, which a global hook must not run.
install_world() { # WORLD
  WORLD_HOME="$TMP_ROOT/home.$1"
  WORLD_HOOKS="$WORLD_HOME/.claude/hooks"
  rm -rf -- "${WORLD_HOME:?}" "${TREE:?}/.agents" "${TREE:?}/.claude"
  mkdir -p "$WORLD_HOME"
  case "$1" in
    installed) install_guard "$WORLD_HOME" ;;
    project) WORLD_HOOKS="$TREE/.claude/hooks"; install_guard "$TREE" ;;
    repo-only) install_guard "$TREE" ;;
  esac
  mkdir -p "$WORLD_HOOKS"
  cp "$HOOK" "$WORLD_HOOKS/worktree-session-claim.sh"
}

install_guard() { # ROOT
  mkdir -p "$1/.agents/skills/worktree"
  cp -R "$WORKTREE_SCRIPTS" "$1/.agents/skills/worktree/scripts"
}

lease_owner() {
  "$GUARD" status "$TREE" --repo "$MAIN" 2>/dev/null | jq -r 'if .locked then .owner else "none" end'
}

# A row: label|world|before|dir|env|rc|first|owner
#   before  the lease the tree holds first: `-` none, else its owner
#   dir     where the session starts: main, tree, sub or outside
#   env     the owner ladder the session carries
#   first   the whole first line of stderr, `-` for silence; TREE stands for
#           the worktree root
#   owner   the lease owner after the hook, `none` for no lock
ROWS="a session in a linked worktree claims it under USER|installed|-|tree|USER=alice|0|-|alice
the ladder's top rung names the owner|installed|-|tree|KENDEX_SESSION_OWNER=ISSUE-1 USER=alice|0|-|ISSUE-1
a session in a subdirectory claims the worktree root|installed|-|sub|USER=alice|0|-|alice
a project install in the worktree claims it|project|-|tree|USER=alice|0|-|alice
a session already holding its lease keeps it|installed|alice|tree|USER=alice|0|-|alice
a main checkout claims nothing|installed|-|main|USER=alice|0|-|none
a directory outside any repository claims nothing|installed|-|outside|USER=alice|0|-|none
another owner's lease is reported and kept|installed|bob|tree|USER=alice|0|worktree-session-claim: held=TREE|bob
a guard that fails is reported|installed|-|tree|-|0|worktree-session-claim: unclaimed=TREE|none
a guard missing from the install is reported|bare|-|tree|USER=alice|0|worktree-session-claim: guard=HOOKDIR|none
a global hook does not run the open worktree's guard|repo-only|-|tree|USER=alice|0|worktree-session-claim: guard=HOOKDIR|none"

claim_rows() {
  local label world before dir envspec want_rc want_first want_owner cwd rc
  local -a row_env
  while IFS='|' read -r label world before dir envspec want_rc want_first want_owner; do
    "$GUARD" release "$TREE" --force --repo "$MAIN" >/dev/null 2>&1 || :
    [ "$before" = - ] || "$GUARD" claim "$TREE" --owner "$before" >/dev/null
    install_world "$world"
    case "$dir" in
      main) cwd=$MAIN ;;
      tree) cwd=$TREE ;;
      sub) cwd=$TREE/sub ;;
      outside) cwd=$OUTSIDE ;;
    esac
    row_env=()
    [ "$envspec" = - ] || read -r -a row_env <<<"$envspec"
    want_first=${want_first//TREE/$TREE}
    want_first=${want_first//HOOKDIR/$WORLD_HOOKS}
    rc=0
    (cd "$cwd" && env -u KENDEX_SESSION_OWNER -u HT_SESSION_OWNER -u USER HOME="$WORLD_HOME" \
      GIT_CEILING_DIRECTORIES="$TMP_ROOT" ${row_env[@]+"${row_env[@]}"} \
      bash "$WORLD_HOOKS/worktree-session-claim.sh" </dev/null >"$OUT_FILE" 2>"$ERR_FILE") || rc=$?
    assert_eq "rc=$rc stdout=$(wc -c <"$OUT_FILE" | tr -d ' ') first=$(first_line) owner=$(lease_owner)" \
      "rc=$want_rc stdout=0 first=$want_first owner=$want_owner" "$label"
    if [ "$want_first" != - ]; then
      assert_eq "$(cause_below)" present "$label: the cause stands under the keyed line"
    fi
  done <<<"$ROWS"
}

echo "=== worktree-session-claim ==="
claim_rows

# The workflow's claim under the issue ID after the hook's: one session, so
# the lease passes rather than refusing the workflow.
"$GUARD" release "$TREE" --force --repo "$MAIN" >/dev/null 2>&1 || :
install_world installed
(cd "$TREE" && env -u KENDEX_SESSION_OWNER -u HT_SESSION_OWNER HOME="$WORLD_HOME" USER=alice \
  bash "$WORLD_HOOKS/worktree-session-claim.sh" </dev/null >/dev/null 2>&1)
rc=0
env -u KENDEX_SESSION_OWNER -u HT_SESSION_OWNER USER=alice \
  "$GUARD" claim "$TREE" --owner ISSUE-1 >/dev/null 2>&1 || rc=$?
assert_eq "rc=$rc owner=$(lease_owner)" "rc=0 owner=ISSUE-1" "the workflow's issue claim takes over the hook's lease"

# Must-fail control: a hook that never runs the guard leaves the tree
# unclaimed, so the rows that claim go red.
if [ -z "${HOOK_UNDER_TEST:-}" ]; then
  awk '{ print } /^rc=0$/ { print "exit 0" }' "$HOOK" >"$TMP_ROOT/no-claim.sh"
  assert_eq "$(grep -cx 'rc=0' "$HOOK")" 1 "control: the guard call's anchor appears once"
  control_log=$(PASS=0 FAIL=0 HOOK="$TMP_ROOT/no-claim.sh" claim_rows) || :
  assert_eq "$(sed -n 's/^  FAIL  //p' <<<"$control_log" | grep -v ': the cause' | tr '\n' ';')" \
    "a session in a linked worktree claims it under USER;the ladder's top rung names the owner;a session in a subdirectory claims the worktree root;a project install in the worktree claims it;another owner's lease is reported and kept;a guard that fails is reported;" \
    "control: a hook that claims nothing turns every claiming and guard-reporting row red"

  # A hook that takes the open repository's guard whatever its own install
  # runs code the repository planted, which the repo-only row refuses.
  REPO_ANCHOR='if [ -z "$FOUND" ] && [ -x "$ROOT/.agents/skills/$GUARD" ]; then'
  awk -v anchor="$REPO_ANCHOR" '{ print } $0 == anchor { print "  FOUND=$ROOT/.agents/skills/$GUARD" }' \
    "$HOOK" >"$TMP_ROOT/repo-guard.sh"
  assert_eq "$(grep -cxF -- "$REPO_ANCHOR" "$HOOK")" 1 "control: the repository-copy anchor appears once"
  control_log=$(PASS=0 FAIL=0 HOOK="$TMP_ROOT/repo-guard.sh" claim_rows) || :
  assert_eq "$(sed -n 's/^  FAIL  //p' <<<"$control_log" | grep -v ': the cause' | tr '\n' ';')" \
    "a global hook does not run the open worktree's guard;" \
    "control: a hook that runs the open repository's guard turns the repo-only row red"
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
