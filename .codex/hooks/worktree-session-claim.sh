#!/usr/bin/env bash
# ---
# name: worktree-session-claim
# event: SessionStart
# matcher:
# description: Claims the linked git worktree a session starts in when the worktree skill laid it out (`worktree managed`), so `worktree cleanup` and `worktree remove` leave a tree a session works in even when no workflow claimed it. It runs the worktree skill's `worktree-session-guard claim <worktree root>` from this hook's own install, never from the open repository, with no `--owner`, so the lease carries the guard's owner ladder: `KENDEX_SESSION_OWNER`, else `HT_SESSION_OWNER`, else `USER`. A later `claim --owner <ISSUE_ID>` from the orchestrating workflow takes that lease over rather than refusing it, and a start under the owner the lease records refreshes its heartbeat. It clears the repository-selecting `GIT_*` variables a harness launched from a git hook inherits, and bounds each claim with `timeout` or `gtimeout`, retrying once when the bound cuts it off. A session in a main checkout, outside a repository, in a submodule or in a worktree a harness made for itself claims nothing and says nothing. It never refuses a session start: each case below is reported at exit 0 on stderr as a keyed line and a line of English, with the guard's own output under them for `held=` and `unclaimed=`. A lock under another owner name or tool, the workflow's issue lease included, is `worktree-session-claim: held=<worktree root>`, a guard or worktree script that fails is `unclaimed=<worktree root>`, a guard the walk from this hook's directory does not find is `guard=<hook directory>`, and a claim run without a bound, where neither utility is on PATH, is first reported as `unbounded=<worktree root>`. Not run on antigravity: it has no SessionStart event. Not run on opencode: it runs no hooks, and a claim taken as an instruction claims nothing. Not run on cursor: kendex delivers a hook there only as advisory rule prose, and a claim taken as an instruction claims nothing.
# summary: Marks the git worktree a session starts in as that session's, so cleanup does not delete a worktree someone opened by hand and is still working in.
# safety: Runs git rev-parse in the session's directory and, from this hook's own install, the worktree skill's `worktree managed`, which loads the repository's kendex settings and `.env.local` as every worktree command does, and its worktree-session-guard, which writes the worktree's git lock file under the repository's git directory. It refuses nothing and exits 0.
# timeout: 30
# harnesses: [claude, codex, pi, copilot, gemini]
# requires-skills: [worktree]
# ---

set -euo pipefail

report() { # KEY VALUE ENGLISH [CAUSE]
  printf 'worktree-session-claim: %s=%s\n%s\n' "$1" "$2" "$3" >&2
  [ -z "${4:-}" ] || printf '%s\n' "$4" >&2
}

notice() { # KEY VALUE ENGLISH [CAUSE]
  report "$@"
  exit 0
}

# A harness launched from a git hook inherits that hook's repository
# selection, which outranks the session's directory for git and the guard.
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES

# A linked worktree is the one checkout whose git dir is not the common dir.
# Anything git cannot answer here is not a linked worktree, so it claims
# nothing.
GIT_DIR_PATH=$(git rev-parse --path-format=absolute --git-dir 2>/dev/null) || exit 0
COMMON_DIR=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || exit 0
[ "$GIT_DIR_PATH" != "$COMMON_DIR" ] || exit 0
ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0

# The guard comes from this hook's own install, by the walk
# hooks/lane-mail-check.sh owns for its reader: from the hook's physical
# directory up five levels, stopping at the open repository's root and after
# the home directory, each level's `skills/` and shared `.agents/skills/` tree;
# then the home's shared tree, for a harness root CODEX_HOME,
# PI_CODING_AGENT_DIR or COPILOT_HOME moved out of the home; then the
# repository's own copy, only where this hook is installed in that repository.
GUARD=worktree/scripts/worktree-session-guard
HOOK_DIR=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || HOOK_DIR=""
HOME_DIR=$(cd -P -- "${HOME:-/}" 2>/dev/null && pwd -P) || HOME_DIR=""
AT=$HOOK_DIR
FOUND=""
LEVELS=0
while [ -n "$AT" ] && [ "$LEVELS" -lt 5 ] && [ "$AT" != "$ROOT" ] && [ "$AT" != / ]; do
  for candidate in "$AT/skills/$GUARD" "$AT/.agents/skills/$GUARD"; do
    if [ -x "$candidate" ]; then
      FOUND=$candidate
      break
    fi
  done
  { [ -z "$FOUND" ] && [ "$AT" != "$HOME_DIR" ]; } || break
  AT=${AT%/*}
  [ -n "$AT" ] || AT=/
  LEVELS=$((LEVELS + 1))
done
if [ -z "$FOUND" ] && [ -n "$HOME_DIR" ] && [ "$HOME_DIR" != "$ROOT" ] \
  && [ -x "$HOME_DIR/.agents/skills/$GUARD" ]; then
  FOUND="$HOME_DIR/.agents/skills/$GUARD"
fi
if [ -z "$FOUND" ] && [ -x "$ROOT/.agents/skills/$GUARD" ]; then
  case "$HOOK_DIR" in
    "$ROOT"/*) FOUND="$ROOT/.agents/skills/$GUARD" ;;
  esac
fi
[ -n "$FOUND" ] || notice guard "${HOOK_DIR:-unlocatable}" \
  "worktree-session-guard is not installed with this hook, so this worktree is not claimed and cleanup may remove it; install the worktree skill in the same scope"

# A harness's own worktree (`claude --worktree`, an isolation worktree) is
# removed by that harness, and a lock nothing releases at session end would
# make it refuse; only a tree the worktree skill laid out is claimed.
rc=0
MANAGED=$("${FOUND%/*}/worktree" managed "$ROOT" 2>&1) || rc=$?
case "$rc:$MANAGED" in
  0:true) ;;
  0:false) exit 0 ;;
  *) notice unclaimed "$ROOT" \
    "the worktree skill could not say whether it laid out this worktree (exit $rc), so this session claimed nothing and cleanup may remove it" "$MANAGED" ;;
esac

# The guard waits on its repository-wide mutex, so each attempt is bounded and
# one the bound cuts off is retried once, both inside this hook's timeout.
BOUND=$(command -v timeout || command -v gtimeout) || BOUND=""
claim() {
  rc=0
  if [ -n "$BOUND" ]; then
    CAUSE=$("$BOUND" --kill-after=2 8 "$FOUND" claim "$ROOT" 2>&1 >/dev/null) || rc=$?
  else
    CAUSE=$("$FOUND" claim "$ROOT" 2>&1 >/dev/null) || rc=$?
  fi
}
[ -n "$BOUND" ] || report unbounded "$ROOT" \
  "neither timeout nor gtimeout is on PATH, so the claim runs once with no bound but this hook's own timeout; install coreutils for a bounded claim with a retry"
claim
case "$rc" in 124 | 137) claim ;; esac
case "$rc" in
  0) ;;
  75) notice held "$ROOT" \
    "a lock under another owner name than this session's holds this worktree, so cleanup leaves it while that lock stands; the guard's lines below name the lock" "$CAUSE" ;;
  *) notice unclaimed "$ROOT" \
    "worktree-session-guard could not claim this worktree (exit $rc), so cleanup may remove it while this session works" "$CAUSE" ;;
esac
