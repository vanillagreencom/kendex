#!/usr/bin/env bash
# Tests for the worktree-session-claim hook.
#
# The hook claims the linked worktree a session starts in through the
# worktree skill's session guard, found from the hook's own install, when the
# worktree skill laid that tree out. Each row installs the hook and the guard
# under a fixture HOME the way a global install lays them out, starts the hook
# in one directory of a fixture repository, and pins the hook's exit status,
# its stdout, the keyed first line of its stderr, the guard's keyed line under
# it and the lease owner it leaves on the worktree.
#
# HOOK_UNDER_TEST overrides the script under test so the must-fail controls (a
# planted copy per rule) can be run against these same assertions.
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

# TREE sits where the worktree skill lays an issue tree out, under the default
# base dir beside the checkout; HARNESS_TREE where Claude Code's
# `claude --worktree` puts its own.
MAIN="$TMP_ROOT/repo/main"
TREE="$TMP_ROOT/repo/.worktrees/main/tree"
HARNESS_TREE="$MAIN/.claude/worktrees/agent"
OUTSIDE="$TMP_ROOT/outside"
mkdir -p "$MAIN" "$OUTSIDE"
git -C "$MAIN" init -q -b main
git -C "$MAIN" config user.email t@example.com
git -C "$MAIN" config user.name t
git -C "$MAIN" config gc.auto 0
git -C "$MAIN" config maintenance.auto false
git -C "$MAIN" commit -q --allow-empty -m init
git -C "$MAIN" worktree add -q -b tree "$TREE" main
git -C "$MAIN" worktree add -q -b agent "$HARNESS_TREE" main
mkdir -p "$TREE/sub"
GUARD="$WORKTREE_SCRIPTS/worktree-session-guard"

# A PATH holding every command the test's own PATH holds but timeout and
# gtimeout, for the row where neither utility is installed.
NO_BOUND="$TMP_ROOT/no-bound"
mkdir -p "$NO_BOUND"
IFS=: read -r -a path_dirs <<<"$PATH"
for dir in "${path_dirs[@]}"; do
  [ -d "$dir" ] || continue
  ln -s "$dir"/* "$NO_BOUND/" 2>/dev/null || :
done
rm -f -- "$NO_BOUND/timeout" "$NO_BOUND/gtimeout"
if [ ! -x "$NO_BOUND/git" ] || PATH="$NO_BOUND" command -v timeout >/dev/null; then
  echo "worktree-session-claim: fixture=no-bound-path" >&2
  exit 1
fi

# The world a row names, setting WORLD_HOME and WORLD_HOOKS, the directory
# the hook runs from: `installed` lays the hook and the guard out where a
# global install puts them, `project` where a project install in the worktree
# does, `relocated` puts the hook in a harness root outside the home (a
# CODEX_HOME elsewhere) beside the home's shared guard, `bare` installs the
# global hook alone, and `repo-only` puts the guard in the open worktree
# alone, which a global hook must not run.
install_world() { # WORLD
  WORLD_HOME="$TMP_ROOT/home.$1"
  WORLD_HOOKS="$WORLD_HOME/.claude/hooks"
  rm -rf -- "${WORLD_HOME:?}" "$TMP_ROOT/harness.$1" "${TREE:?}/.agents" "${TREE:?}/.claude"
  mkdir -p "$WORLD_HOME"
  case "$1" in
    installed) install_guard "$WORLD_HOME" ;;
    project) WORLD_HOOKS="$TREE/.claude/hooks"; install_guard "$TREE" ;;
    relocated) WORLD_HOOKS="$TMP_ROOT/harness.$1/hooks"; install_guard "$WORLD_HOME" ;;
    repo-only) install_guard "$TREE" ;;
  esac
  mkdir -p "$WORLD_HOOKS"
  cp "$HOOK" "$WORLD_HOOKS/worktree-session-claim.sh"
}

install_guard() { # ROOT
  mkdir -p "$1/.agents/skills/worktree"
  cp -R "$WORKTREE_SCRIPTS" "$1/.agents/skills/worktree/scripts"
}

lease_owner() { # TREE
  "$GUARD" status "$1" --repo "$MAIN" 2>/dev/null | jq -r 'if .locked then .owner else "none" end'
}

release_all() {
  "$GUARD" release "$TREE" --force --repo "$MAIN" >/dev/null 2>&1 || :
  "$GUARD" release "$HARNESS_TREE" --force --repo "$MAIN" >/dev/null 2>&1 || :
}

run_hook_in() { # DIR [ENV...]
  local cwd="$1"
  shift
  (cd "$cwd" && env -u KENDEX_SESSION_OWNER -u HT_SESSION_OWNER -u USER HOME="$WORLD_HOME" \
    GIT_CEILING_DIRECTORIES="$TMP_ROOT" "$@" \
    bash "$WORLD_HOOKS/worktree-session-claim.sh" </dev/null >"$OUT_FILE" 2>"$ERR_FILE")
}

# A row: label|world|before|dir|env|rc|first|guard|owner
#   before  the lease the tree holds first: `-` none, else its owner
#   dir     where the session starts: main, tree, sub, harness or outside
#   env     the owner ladder and environment the session carries
#   first   the whole first line of stderr, `-` for silence; TREE stands for
#           the worktree root and HOOKDIR for the hook's directory
#   guard   the guard's keyed line the hook replays under its own, as a whole
#           line of stderr (worktree-session-guard's messages.sh records),
#           `-` for a row where the guard does not run or says nothing
#   owner   the lease owner after the hook on the session's worktree, `none`
#           for no lock
ROWS="a session in a linked worktree claims it under USER|installed|-|tree|USER=alice|0|-|-|alice
the ladder's top rung names the owner|installed|-|tree|KENDEX_SESSION_OWNER=ISSUE-1 USER=alice|0|-|-|ISSUE-1
a session in a subdirectory claims the worktree root|installed|-|sub|USER=alice|0|-|-|alice
a project install in the worktree claims it|project|-|tree|USER=alice|0|-|-|alice
a hook in a harness root outside the home claims through the home's guard|relocated|-|tree|USER=alice|0|-|-|alice
a session already holding its lease keeps it|installed|alice|tree|USER=alice|0|-|-|alice
an inherited GIT_DIR does not move the claim|installed|-|tree|GIT_DIR=$MAIN/.git USER=alice|0|-|-|alice
a claim with no timeout utility runs unbounded and says so|installed|-|tree|PATH=$NO_BOUND USER=alice|0|worktree-session-claim: unbounded=TREE|-|alice
a main checkout claims nothing|installed|-|main|USER=alice|0|-|-|none
a worktree a harness made for itself claims nothing|installed|-|harness|USER=alice|0|-|-|none
a directory outside any repository claims nothing|installed|-|outside|USER=alice|0|-|-|none
another owner's lease is reported and kept|installed|bob|tree|USER=alice|0|worktree-session-claim: held=TREE|worktree-guard-owner-conflict: path=TREE owner=bob|bob
a guard that fails is reported|installed|-|tree|-|0|worktree-session-claim: unclaimed=TREE|worktree-guard-owner-required: claim|none
a guard missing from the install is reported|bare|-|tree|USER=alice|0|worktree-session-claim: guard=HOOKDIR|-|none
a global hook does not run the open worktree's guard|repo-only|-|tree|USER=alice|0|worktree-session-claim: guard=HOOKDIR|-|none"

claim_rows() {
  local label world before dir envspec want_rc want_first want_guard want_owner cwd tree rc
  local -a row_env
  while IFS='|' read -r label world before dir envspec want_rc want_first want_guard want_owner; do
    release_all
    [ "$before" = - ] || "$GUARD" claim "$TREE" --owner "$before" >/dev/null
    install_world "$world"
    tree=$TREE
    case "$dir" in
      main) cwd=$MAIN ;;
      tree) cwd=$TREE ;;
      sub) cwd=$TREE/sub ;;
      harness) cwd=$HARNESS_TREE; tree=$HARNESS_TREE ;;
      outside) cwd=$OUTSIDE ;;
    esac
    row_env=()
    [ "$envspec" = - ] || read -r -a row_env <<<"$envspec"
    want_first=${want_first//TREE/$TREE}
    want_first=${want_first//HOOKDIR/$WORLD_HOOKS}
    rc=0
    run_hook_in "$cwd" ${row_env[@]+"${row_env[@]}"} || rc=$?
    assert_eq "rc=$rc stdout=$(wc -c <"$OUT_FILE" | tr -d ' ') first=$(first_line) owner=$(lease_owner "$tree")" \
      "rc=$want_rc stdout=0 first=$want_first owner=$want_owner" "$label"
    if [ "$want_guard" != - ]; then
      assert_eq "$(grep -Fxc -- "${want_guard//TREE/$TREE}" "$ERR_FILE" || :)" 1 "$label: the guard's keyed line is replayed"
    fi
  done <<<"$ROWS"
}

echo "=== worktree-session-claim ==="
claim_rows

# The workflow's claim under the issue ID after the hook's: one session, so
# the lease passes rather than refusing the workflow. A later start of that
# session under the env ladder reports the issue lease held and leaves it.
release_all
install_world installed
run_hook_in "$TREE" USER=alice
rc=0
env -u KENDEX_SESSION_OWNER -u HT_SESSION_OWNER USER=alice \
  "$GUARD" claim "$TREE" --owner ISSUE-1 >/dev/null 2>&1 || rc=$?
assert_eq "rc=$rc owner=$(lease_owner "$TREE")" "rc=0 owner=ISSUE-1" "the workflow's issue claim takes over the hook's lease"
rc=0
run_hook_in "$TREE" USER=alice || rc=$?
assert_eq "rc=$rc first=$(first_line) guard=$(grep -Fxc -- "worktree-guard-owner-conflict: path=$TREE owner=ISSUE-1" "$ERR_FILE" || :) owner=$(lease_owner "$TREE")" \
  "rc=0 first=worktree-session-claim: held=$TREE guard=1 owner=ISSUE-1" \
  "a session restarted under its issue lease reports it held and keeps it"

# A claim waits on the guard's repository-wide mutex. One holder keeps it past
# the first bounded attempt and lets go before the second ends, so the claim
# lands only through the retry. Real time is the point of this row: it proves
# the bound and the retry are wired, nothing about their exact lengths.
retry_row() { # LABEL
  local lock="$MAIN/.git/kendex-worktree-session-guard.lock" ready holder rc=0
  release_all
  install_world installed
  ready="$TMP_ROOT/held.$RANDOM"
  if command -v flock >/dev/null 2>&1; then
    flock -x "$lock" sh -c ': >"$1"; sleep 9' _ "$ready" &
  else
    mkdir -- "$lock.d"
    sh -c ': >"$1"; sleep 9; rmdir -- "$2"' _ "$ready" "$lock.d" &
  fi
  holder=$!
  until [ -e "$ready" ]; do sleep 0.1; done
  run_hook_in "$TREE" USER=alice || rc=$?
  wait "$holder"
  assert_eq "rc=$rc first=$(first_line) owner=$(lease_owner "$TREE")" "rc=0 first=- owner=alice" "$1"
}
HAS_BOUND=false
if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
  HAS_BOUND=true
  retry_row "a claim the guard mutex holds past one attempt lands on the retry"
fi

# A planted copy of the hook with LINE, which must stand once as a whole line,
# replaced by REPLACEMENT; the rows it names are the ones that go red.
control() { # NAME LINE REPLACEMENT ROWS-FUNCTION EXPECTED-FAILS [ARG]
  local name="$1" line="$2" replacement="$3" rows="$4" expected="$5" log
  assert_eq "$(grep -cxF -- "$line" "$HOOK" || :)" 1 "control $name: its anchor stands once"
  # Through the environment, since awk -v would decode the backslashes a line holds.
  LINE=$line REPLACEMENT=$replacement awk '$0 == ENVIRON["LINE"] { print ENVIRON["REPLACEMENT"]; next } { print }' \
    "$HOOK" >"$TMP_ROOT/$name.sh"
  ! cmp -s "$HOOK" "$TMP_ROOT/$name.sh" || { echo "worktree-session-claim: control=$name mutation=unchanged" >&2; exit 2; }
  log=$(PASS=0 FAIL=0 HOOK="$TMP_ROOT/$name.sh" "$rows" ${6:+"$6"}) || :
  assert_eq "$(sed -n 's/^  FAIL  //p' <<<"$log" | tr '\n' ';')" "$expected" "control $name: the planted defect turns its rows red"
}

if [ -z "${HOOK_UNDER_TEST:-}" ]; then
  # A hook that never runs the guard leaves the tree unclaimed.
  control no-claim 'claim' 'exit 0' claim_rows \
    "a session in a linked worktree claims it under USER;the ladder's top rung names the owner;a session in a subdirectory claims the worktree root;a project install in the worktree claims it;a hook in a harness root outside the home claims through the home's guard;an inherited GIT_DIR does not move the claim;a claim with no timeout utility runs unbounded and says so;another owner's lease is reported and kept;another owner's lease is reported and kept: the guard's keyed line is replayed;a guard that fails is reported;a guard that fails is reported: the guard's keyed line is replayed;"

  # A hook that drops what the guard wrote.
  control no-cause '  [ -z "${4:-}" ] || printf '"'"'%s\n'"'"' "$4" >&2' '  :' claim_rows \
    "another owner's lease is reported and kept: the guard's keyed line is replayed;a guard that fails is reported: the guard's keyed line is replayed;"

  # A hook that takes the open repository's guard whatever its own install
  # runs code the repository planted.
  control repo-guard '  case "$HOOK_DIR" in' '  case "$ROOT/" in' claim_rows \
    "a global hook does not run the open worktree's guard;"

  # A hook without the home's shared tree misses a guard a harness root
  # outside the home relies on.
  control no-home-fallback 'if [ -z "$FOUND" ] && [ -n "$HOME_DIR" ] && [ "$HOME_DIR" != "$ROOT" ] \' 'if false \' claim_rows \
    "a hook in a harness root outside the home claims through the home's guard;"

  # A hook that keeps an inherited GIT_DIR reads the main checkout.
  control git-env 'unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES' ':' claim_rows \
    "an inherited GIT_DIR does not move the claim;"

  # A hook that claims whatever tree it starts in locks a harness's own.
  control unmanaged '  0:false) exit 0 ;;' '  0:false) ;;' claim_rows \
    "a worktree a harness made for itself claims nothing;"

  # A hook that claims unbounded in silence.
  control silent-unbounded '[ -n "$BOUND" ] || report unbounded "$ROOT" \' '[ -n "$BOUND" ] || : \' claim_rows \
    "a claim with no timeout utility runs unbounded and says so;"

  if [ "$HAS_BOUND" = true ]; then
    control no-retry 'case "$rc" in 124 | 137) claim ;; esac' ':' retry_row "no retry;" "no retry"
  fi
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
