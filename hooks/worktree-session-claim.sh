#!/usr/bin/env bash
# ---
# name: worktree-session-claim
# event: SessionStart
# matcher:
# description: Claims the linked git worktree a session starts in, so `worktree cleanup` and `worktree remove` leave a tree a session works in even when no workflow claimed it. It runs the worktree skill's `worktree-session-guard claim <worktree root>` from this hook's own install, never from the open repository, with no `--owner`, so the lease carries the guard's owner ladder: `KENDEX_SESSION_OWNER`, else `HT_SESSION_OWNER`, else `USER`. A later `claim --owner <ISSUE_ID>` from the orchestrating workflow takes that lease over rather than refusing it, and a start of a session already holding its lease refreshes its heartbeat. A session in a main checkout, outside a repository or in a submodule claims nothing and says nothing. It never refuses a session start: each case below is reported at exit 0 on stderr, with the guard's own words under the keyed line. A lock another owner or tool holds is `worktree-session-claim: held=<worktree root>`, a guard that fails is `unclaimed=<worktree root>`, and a guard the walk from this hook's directory does not find is `guard=<hook directory>`. Not run on antigravity: it has no SessionStart event. Not run on opencode: it runs no hooks, and a claim taken as an instruction claims nothing. Not run on cursor: kendex delivers a hook there only as advisory rule prose, and a claim taken as an instruction claims nothing.
# summary: Marks the git worktree a session starts in as that session's, so cleanup does not delete a worktree someone opened by hand and is still working in.
# safety: Runs git rev-parse in the session's directory and the worktree skill's worktree-session-guard from this hook's own install, which writes the worktree's git lock file under the repository's git directory. It refuses nothing and exits 0.
# timeout: 30
# harnesses: [claude, codex, pi, copilot, gemini]
# requires-skills: [worktree]
# ---

set -euo pipefail

notice() { # KEY VALUE ENGLISH [CAUSE]
  printf 'worktree-session-claim: %s=%s\n%s\n' "$1" "$2" "$3" >&2
  [ -z "${4:-}" ] || printf '%s\n' "$4" >&2
  exit 0
}

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

rc=0
CAUSE=$("$FOUND" claim "$ROOT" 2>&1 >/dev/null) || rc=$?
case "$rc" in
  0) ;;
  75) notice held "$ROOT" \
    "another owner's lock holds this worktree, so this session claimed nothing; cleanup leaves the worktree while that lock stands" "$CAUSE" ;;
  *) notice unclaimed "$ROOT" \
    "worktree-session-guard could not claim this worktree (exit $rc), so cleanup may remove it while this session works" "$CAUSE" ;;
esac
