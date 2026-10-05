#!/usr/bin/env bash
# ---
# name: worktree-session-claim
# event: SessionStart
# matcher:
# description: Claims the linked git worktree a session starts in when the worktree skill created it, so `worktree cleanup` and `worktree remove` leave a tree a session works in even when no workflow claimed it. A tree counts as the skill's when its private git dir holds the `kendex-issue` record every `worktree create` that returns a tree writes; the hook reads that one file and runs no worktree command, so a tree a harness made for itself (`claude --worktree`, an isolation worktree) or one made before the record existed is not claimed. It runs the worktree skill's `worktree-session-guard claim <worktree root>` from this hook's own install, never from the open repository, with no `--owner`, so the lease carries the guard's owner ladder: `KENDEX_SESSION_OWNER`, else `HT_SESSION_OWNER`, else `USER`. A later `claim --owner <ISSUE_ID>` from the orchestrating workflow takes that lease over rather than refusing it, and a start under the owner the lease records refreshes its heartbeat. It clears the repository-selecting `GIT_*` variables a harness launched from a git hook inherits. The guard bounds its own wait on its repository-wide lock, and this hook's timeout sits above that bound. A session in a main checkout, outside a repository or in a submodule claims nothing and says nothing. It never refuses a session start. What it could not do is reported at exit 0 on stderr as a keyed line and a line of English, with the failing command's own output under them: `worktree-session-claim: held=<worktree root>` means a lock under another owner name or tool, the workflow's issue lease included, holds the tree and stays; `unclaimed=<worktree root>` means the claim failed and the tree holds no lease; `guard=<hook directory>` means no guard is installed beside this hook. Not run on antigravity: it has no SessionStart event. Not run on opencode: it runs no hooks, and a claim taken as an instruction claims nothing. Not run on cursor: kendex delivers a hook there only as advisory rule prose, and a claim taken as an instruction claims nothing.
# summary: Marks a git worktree the worktree skill created as the session's when a session starts in it, so cleanup does not delete a worktree someone opened by hand and is still working in.
# safety: Runs git rev-parse in the session's directory, reads one file in the worktree's private git dir, and runs the worktree skill's worktree-session-guard from this hook's own install, which writes the worktree's git lock file under the repository's git directory. It executes no file from the repository, loads no project settings or `.env.local`, refuses nothing and exits 0.
# timeout: 75
# harnesses: [claude, codex, pi, copilot, gemini]
# requires-skills: [worktree]
# ---

set -euo pipefail

notice() { # KEY VALUE ENGLISH [CAUSE]
  printf 'worktree-session-claim: %s=%s\n%s\n' "$1" "$2" "$3" >&2
  [ -z "${4:-}" ] || printf '%s\n' "$4" >&2
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

# Only a tree the worktree skill created is claimed, and that is a fact the
# skill recorded, never one this hook asks the skill's scripts for: they load
# the repository's settings and `.env.local` as shell. A harness's own
# worktree is removed by that harness, and a lock nothing releases at session
# end would make it refuse.
[ -f "$GIT_DIR_PATH/kendex-issue" ] || exit 0

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
    "a lock under another owner name than this session's holds this worktree, so cleanup leaves it while that lock stands" "$CAUSE" ;;
  *) notice unclaimed "$ROOT" \
    "worktree-session-guard could not claim this worktree (exit $rc), so cleanup may remove it while this session works" "$CAUSE" ;;
esac
