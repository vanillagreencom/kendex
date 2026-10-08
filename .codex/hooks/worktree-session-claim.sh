#!/usr/bin/env bash
# ---
# name: worktree-session-claim
# event: SessionStart
# matcher:
# description: Claims the linked git worktree a session starts in when its private git directory carries the worktree skill's `kendex-issue` record. The worktree skill's `references/session-guard.md` defines the lease and its limits. It runs `worktree-session-guard claim <worktree root>` with the guard's owner ladder: `KENDEX_SESSION_OWNER`, else `HT_SESSION_OWNER`, else `USER`. A workflow can adopt that initial lease under its issue ID; resumed sessions must name that owner to refresh it. It clears Git's local repository variables plus discovery limits and namespace before resolving the checkout from the session directory. It makes one claim attempt: the guard can wait 60 seconds for its lock, and another attempt would exceed this hook's 75-second timeout. Guard output is limited to its first 4096 bytes. Set the process environment variable `KENDEX_WORKTREE_CLAIM=required` to require a claim; this hook loads no project settings or `.env.local`. In required mode a foreign lease, missing guard, failed claim or unexpected hook error returns `continue:false` with a keyed reason on Claude and Codex. Pi, Gemini and Copilot cannot refuse a SessionStart; they receive the same keyed result as context. Without the setting, failures are notices at exit 0, and a foreign lease stays silent. A main checkout, a repository without the issue record or a directory outside Git claims nothing and says nothing. Not run on antigravity: it has no SessionStart event. Not run on opencode: it runs no hooks, and a claim taken as an instruction claims nothing. Not run on cursor: kendex delivers a hook there only as advisory rule prose, and a claim taken as an instruction claims nothing.
# summary: Claims a git worktree the worktree skill created or adopted for the worktree session guard when a session starts in it.
# safety: Reads Git repository metadata and the worktree issue record, and runs the guard found beside this hook's install; a project install can use the repository's guard. The guard writes the worktree's lease under the repository's Git directory. Loads no project settings or `.env.local`. Exit 0 carries a structured stop on Claude and Codex only when `KENDEX_WORKTREE_CLAIM=required`; the other harnesses receive an advisory.
# timeout: 75
# harnesses: [claude, codex, pi, copilot, gemini]
# requires-skills: [worktree]
# ---

set -euo pipefail

notice() { # KEY VALUE ENGLISH [CAUSE]
  local text cause="${4:-}" answer fallback
  trap - EXIT
  # Keep the first cause within the context limits of session-start hooks.
  cause=${cause:0:4096}
  text=$(printf 'worktree-session-claim: %s=%s\n%s' "$1" "$2" "$3")
  [ -z "$cause" ] || text="$text"$'\n'"$cause"
  printf '%s\n' "$text" >&2
  if [ "${KENDEX_WORKTREE_CLAIM:-}" = required ]; then
    # Claude and Codex consume continue/stopReason. Gemini and Pi consume
    # the nested context, and Copilot consumes only additionalContext.
    if answer=$(jq -nc --arg reason "$text" '{continue:false,stopReason:$reason,additionalContext:$reason,hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$reason}}' 2>/dev/null); then
      printf '%s\n' "$answer"
    else
      # A missing or broken jq must still produce a valid stop answer.
      fallback='"worktree-session-claim: output=unavailable\nThe required claim failed. Repair jq and read the cause on stderr."'
      printf '{"continue":false,"stopReason":%s,"additionalContext":%s,"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":%s}}\n' "$fallback" "$fallback" "$fallback"
    fi
  fi
  exit 0
}

export LC_ALL=C
trap 'rc=$?; [ "$rc" -eq 0 ] || notice unexpected "${ROOT:-$PWD}" "The session claim hook failed; repair the hook before starting work." "exit=$rc"' EXIT

# A harness launched from a git hook inherits that hook's repository
# selection, which outranks the session's directory for git and the guard.
# Git tracing writes to stderr even on success. Only stdout is repository data.
GIT_ENV=$(git rev-parse --local-env-vars 2>/dev/null) || notice git-env "$PWD" \
  "Cannot read Git's repository-selection variables; repair Git before starting work." "git-exit=$?"
while IFS= read -r git_variable; do
  unset "$git_variable"
done <<<"$GIT_ENV"
unset GIT_CEILING_DIRECTORIES GIT_DISCOVERY_ACROSS_FILESYSTEM GIT_NAMESPACE

# A linked worktree is the one checkout whose git dir is not the common dir.
# Anything git cannot answer here is not a linked worktree, so it claims
# nothing.
GIT_DIR_PATH=$(git rev-parse --path-format=absolute --git-dir 2>/dev/null) || exit 0
COMMON_DIR=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || notice unclaimed "$PWD" \
  "Cannot resolve the repository's common Git directory; repair the checkout before starting work." "git-exit=$?"
[ "$GIT_DIR_PATH" != "$COMMON_DIR" ] || exit 0
ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || notice unclaimed "$PWD" \
  "Cannot resolve the worktree root; repair the checkout before starting work." "git-exit=$?"

# The skill's record is read here rather than asked of the skill's scripts,
# which load the repository's settings and `.env.local` as shell.
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
  "worktree-session-guard is not installed with this hook, so this start claims nothing; install the worktree skill in the same scope"

rc=0
# The guard can wait 60 seconds for its lock. One attempt fits timeout: 75;
# a retry could exceed the harness's budget before a refusal is delivered.
CAUSE=$("$FOUND" claim "$ROOT" 2>&1 >/dev/null) || rc=$?
# Exit 75 means a lock already holds the tree; this start leaves that lock as
# it stands.
case "$rc" in
  0) ;;
  75)
    [ "${KENDEX_WORKTREE_CLAIM:-}" != required ] || notice held "$ROOT" \
      "Another lease holds this worktree; use a worktree you own or ask its owner to release it before starting work." "$CAUSE"
    ;;
  *) notice unclaimed "$ROOT" \
    "worktree-session-guard could not claim this worktree (exit $rc); a lease taken before this start may still stand" "$CAUSE" ;;
esac
