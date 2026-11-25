#!/usr/bin/env bash
# ---
# name: worktree-session-claim
# event: SessionStart
# matcher:
# description: Claims the linked git worktree a session starts in when its private git directory carries the worktree skill's `kendex-issue` record. The worktree skill's `references/session-guard.md` defines the lease and its limits. It runs `worktree-session-guard claim <worktree root>` with the guard's owner ladder: `KENDEX_SESSION_OWNER`, else `HT_SESSION_OWNER`, else `USER`. A workflow can adopt that initial lease under its issue ID with `--adopt`, which records the session's owner in the lease. Every claim passes `--session`, so a later start under that same owner, and on Claude a prompt in required mode, refreshes the issue lease and keeps the issue owner; a lease with no matching association stays foreign. It clears Git's local repository variables plus discovery limits and namespace before resolving the checkout from the session directory. It makes one claim attempt: the guard can wait 60 seconds for its lock, and another attempt would exceed this hook's 75-second timeout. The guard records in the lease the harness process the hook runs under, where it can read one, and takes over an expired foreign lease only when the lease records at least one process and every one it records is verified dead; a lease that records none is never taken over. A start, compaction, clear or Claude prompt on a lease that already records this process is established: its claim does not wait for the lock, and a guard lock that is busy or cannot be taken, or a failed lease write, gives the keyed `maintenance` notice on stderr at exit 0, never a refusal. Guard output is limited to its first 4096 bytes. Set the process environment variable `KENDEX_WORKTREE_CLAIM=required` to require a claim; this hook loads no project settings or `.env.local`. In required mode a foreign lease, missing guard, failed claim or unexpected hook error refuses a SessionStart on Codex with `continue:false` and a keyed reason. Claude, Pi, Gemini and Copilot cannot refuse a SessionStart; they receive the same keyed result as advisory context. Without the setting, failures are notices at exit 0, and a foreign lease stays silent. A main checkout, a repository without the issue record or a directory outside Git claims nothing and says nothing. Not run on antigravity: it has no SessionStart event. Not run on opencode: it runs no hooks, and a claim taken as an instruction claims nothing. Not run on cursor: kendex delivers a hook there only as advisory rule prose, and a claim taken as an instruction claims nothing.
# summary: Claims a git worktree the worktree skill created or adopted for the worktree session guard when a session starts in it.
# safety: Reads Git repository metadata and the worktree issue record, and runs the guard from the Pi carrier's registration or, on other harnesses, from this hook's own install. The guard writes the worktree's lease under the repository's Git directory. Loads no project settings or `.env.local`. Exit 0 carries a structured stop on Codex only when `KENDEX_WORKTREE_CLAIM=required`; Claude, Pi, Gemini and Copilot receive an advisory at SessionStart.
# timeout: 75
# harnesses: [claude, codex, pi, copilot, gemini]
# requires-skills: [worktree]
# requires: [worktree-prompt-claim]
# requires-on: [claude]
# ---
# kendex: a pi-hooks carrier before 0.19.3 names no registration, so this
# render reads it from the path the registry spawned (docs/adapters/pi.md).
if [ -z "${KENDEX_HOOK_SCOPE+set}${KENDEX_HOOK_ROOT+set}" ]; then
  kendex_hook_at=${BASH_SOURCE[0]-}
  kendex_hook_tail='/kendex/hooks/worktree-session-claim.sh'
  kendex_hook_scope=''
  case ${kendex_hook_at//\\//} in
    */.pi"$kendex_hook_tail") kendex_hook_scope=project ;;
    *"$kendex_hook_tail") kendex_hook_scope=global ;;
  esac
  if [ "$kendex_hook_scope" = project ]; then
    kendex_hook_win=''
    case ${OSTYPE-} in msys* | cygwin* | win32*) kendex_hook_win=1 ;; esac
    kendex_hook_home=${HOME-}
    [ -z "$kendex_hook_win" ] || kendex_hook_home=${USERPROFILE-}
    kendex_hook_rest=${PI_CODING_AGENT_DIR-}
    kendex_hook_rest=${kendex_hook_rest#"${kendex_hook_rest%%[![:space:]]*}"}
    kendex_hook_rest=${kendex_hook_rest%"${kendex_hook_rest##*[![:space:]]}"}
    case $kendex_hook_rest in
      '~') kendex_hook_rest=$kendex_hook_home ;;
      '~/'*) kendex_hook_rest=$kendex_hook_home/${kendex_hook_rest:2} ;;
    esac
    kendex_hook_rest=${kendex_hook_rest//\\//}
    kendex_hook_lead=''
    if [ -z "$kendex_hook_win" ]; then
      case $kendex_hook_rest in /*) ;; *) kendex_hook_rest='' ;; esac
    else
      case $kendex_hook_rest in
        [A-Za-z]:/*) kendex_hook_lead=${kendex_hook_rest:0:2} kendex_hook_rest=${kendex_hook_rest:2} ;;
        //[!/]*/[!/]*) kendex_hook_lead=/ ;;
        *) kendex_hook_rest='' ;;
      esac
    fi
    kendex_hook_global=''
    if [ -n "$kendex_hook_rest" ]; then
      while [ -n "$kendex_hook_rest" ]; do
        kendex_hook_part=${kendex_hook_rest%%/*}
        case $kendex_hook_rest in */*) kendex_hook_rest=${kendex_hook_rest#*/} ;; *) kendex_hook_rest='' ;; esac
        case $kendex_hook_part in
          '' | .) ;;
          ..) kendex_hook_global=${kendex_hook_global%/*} ;;
          *) kendex_hook_global=$kendex_hook_global/$kendex_hook_part ;;
        esac
      done
      kendex_hook_global=$kendex_hook_lead${kendex_hook_global:-/}
    fi
    kendex_hook_pi=${kendex_hook_at//\\//}
    kendex_hook_pi=${kendex_hook_pi%"$kendex_hook_tail"}
    if [ -n "$kendex_hook_global" ] && [ "$kendex_hook_global" = "$kendex_hook_pi" ]; then
      kendex_hook_scope=global
      kendex_hook_project=${kendex_hook_pi%/.pi}
      case $kendex_hook_project in '' | [A-Za-z]:) kendex_hook_project=$kendex_hook_project/ ;; esac
      # The carrier's project: config.ts::walkProjectRoot from its cwd.
      kendex_hook_here=$(pwd -P 2>/dev/null) || kendex_hook_here=''
      while [ -n "$kendex_hook_here" ]; do
        [ ! -f "$kendex_hook_here/.kendex-lock.json" ] || break
        if [ "$kendex_hook_here" -ef "$kendex_hook_home" ]; then
          kendex_hook_here=''
          break
        fi
        for kendex_hook_marker in .claude .codex .opencode .cursor .pi .agents .gemini; do
          [ ! -d "$kendex_hook_here/$kendex_hook_marker" ] || break 2
        done
        case $kendex_hook_here in
          */?*)
            kendex_hook_here=${kendex_hook_here%/*}
            kendex_hook_here=${kendex_hook_here:-/}
            ;;
          *) kendex_hook_here='' ;;
        esac
      done
      if [ -n "$kendex_hook_here" ] && [ "$kendex_hook_here" -ef "$kendex_hook_project" ]; then
        kendex_hook_scope=both
      fi
    else
      kendex_hook_tail=/.pi$kendex_hook_tail
    fi
  fi
  case $kendex_hook_scope in
    project | global)
      kendex_hook_root=${kendex_hook_at:0:${#kendex_hook_at}-${#kendex_hook_tail}}
      case ${kendex_hook_root//\\//} in
        '') kendex_hook_root=${kendex_hook_at:0:1} ;;
        [A-Za-z]:) kendex_hook_root+=${kendex_hook_at:2:1} ;;
      esac
      case ${kendex_hook_root//\\//} in
        /* | [A-Za-z]:/*) export KENDEX_HOOK_SCOPE=$kendex_hook_scope KENDEX_HOOK_ROOT="$kendex_hook_root" ;;
      esac
      ;;
  esac
  unset kendex_hook_at kendex_hook_tail kendex_hook_scope kendex_hook_win kendex_hook_home \
    kendex_hook_rest kendex_hook_lead kendex_hook_global kendex_hook_part kendex_hook_pi \
    kendex_hook_project kendex_hook_here kendex_hook_marker kendex_hook_root
fi

set -euo pipefail

# Claude's SessionStart cannot block. Its prompt companion uses this same
# claim decision, but UserPromptSubmit can refuse through exit 2.
PROMPT=false
[ "${1:-}" != prompt ] || PROMPT=true
[ "$PROMPT" != true ] || [ "${KENDEX_WORKTREE_CLAIM:-}" = required ] || exit 0

# Copilot consumes top-level context; Codex 0.162.0 treats that field as a
# context-only answer and misses continue:false. These are the install
# markers used by lane-mail-check, including relocated Copilot account roots.
COPILOT=false
case "${BASH_SOURCE[0]%/*}" in
  */.github/hooks | .github/hooks) COPILOT=true ;;
esac
[ ! -f "${BASH_SOURCE[0]%.sh}.json" ] || COPILOT=true

# Prints the keyed record, its English and the cause on stderr, and keeps the
# text in NOTICE_TEXT for the structured answer.
record() { # KEY VALUE ENGLISH [CAUSE]
  local text cause="${4:-}"
  trap - EXIT
  # Keep the first cause within the context limits of session-start hooks.
  cause=${cause:0:4096}
  text=$(printf 'worktree-session-claim: %s=%s\n%s' "$1" "$2" "$3")
  [ -z "$cause" ] || text="$text"$'\n'"$cause"
  printf '%s\n' "$text" >&2
  NOTICE_TEXT=$text
}

# An established session whose lease maintenance failed keeps its lease and
# continues on every harness and event, Claude's prompt included.
advise() { # KEY VALUE ENGLISH [CAUSE]
  record "$@"
  exit 0
}

notice() { # KEY VALUE ENGLISH [CAUSE]
  local text answer fallback
  record "$@"
  text=$NOTICE_TEXT
  [ "$PROMPT" != true ] || exit 2
  if [ "${KENDEX_WORKTREE_CLAIM:-}" = required ]; then
    if answer=$(jq -nc --arg reason "$text" --argjson copilot "$COPILOT" '{continue:false,stopReason:$reason} + (if $copilot then {additionalContext:$reason} else {hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$reason}} end)' 2>/dev/null); then
      printf '%s\n' "$answer"
    else
      # A broken encoder must preserve the Codex stop and advisory context.
      fallback='"worktree-session-claim: output=unavailable\nThe required claim failed. Repair jq and read the cause on stderr."'
      if [ "$COPILOT" = true ]; then
        printf '{"continue":false,"stopReason":%s,"additionalContext":%s}\n' "$fallback" "$fallback"
      else
        printf '{"continue":false,"stopReason":%s,"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":%s}}\n' "$fallback" "$fallback"
      fi
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
# which load the repository's settings and `.env.local`.
[ -f "$GIT_DIR_PATH/kendex-issue" ] || exit 0

GUARD=worktree/scripts/worktree-session-guard
HOOK_DIR=${BASH_SOURCE[0]%/*}
FOUND=""
# Use the Pi carrier's registration so a global root inside a checkout
# cannot select the checkout's guard.
# A registered Codex home can also end in kendex.
install_harness=unknown
case "${KENDEX_HOOK_SCOPE:-}:$HOOK_DIR" in
  :*/kendex/hooks | :kendex/hooks)
    if [[ "$HOOK_DIR" = "${CODEX_HOME:-}/hooks" ||
          ( "${CODEX_HOME:-}" = /* && "$HOOK_DIR" -ef "$CODEX_HOME/hooks" ) ]]; then
      install_harness=codex
    else
      install_harness=pi
    fi
    ;;
esac
case "${KENDEX_HOOK_SCOPE:-}:$install_harness" in
  global:* | project:*)
    pi_root=${KENDEX_HOOK_ROOT:-}
    if [ -n "$pi_root" ]; then
      if [ "$KENDEX_HOOK_SCOPE" = project ]; then
        native="$pi_root/.pi"
        shared="$pi_root"
      else
        native="$pi_root"
        shared=${HOME:-}
      fi
      for candidate in "$native/skills/$GUARD" "${shared:+$shared/.agents/skills/$GUARD}"; do
        if [ -x "$candidate" ]; then FOUND=$candidate; break; fi
      done
    fi
    ;;
  *:pi) ;; # An older Pi carrier supplies no install.
  *)
    # Other harnesses find the guard by the same walk that lane-mail-check
    # uses for its reader, bounded by the home and the open repository.
    HOOK_DIR=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || HOOK_DIR=""
    HOME_DIR=$(cd -P -- "${HOME:-/}" 2>/dev/null && pwd -P) || HOME_DIR=""
    AT=$HOOK_DIR
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
    ;;
esac
[ -n "$FOUND" ] || notice guard "${HOOK_DIR:-unlocatable}" \
  "worktree-session-guard is not installed with this hook, so this start claims nothing; install the worktree skill in the same scope"

rc=0
# The guard can wait 60 seconds for its lock. One attempt fits timeout: 75;
# a retry could exceed the harness's budget before the result is delivered.
# A resume, /clear or compaction starts again under the owner that the
# workflow's --adopt recorded, so --session keeps that adopted issue lease, and
# a session the lease already records does not wait for the lock at all.
CAUSE=$("$FOUND" claim "$ROOT" --session 2>&1 >/dev/null) || rc=$?
# Exit 75 means a lock already holds the tree; this start leaves that lock as
# it stands. Exit 6 is the guard's established session, whose lease already
# lists this harness process: a lock it cannot take or a failed write leaves
# that lease standing, so it is no reason to stop the session.
case "$rc" in
  0) ;;
  6) advise maintenance "$ROOT" \
    "This session already holds its lease; refreshing it failed this time and the lease stands." "$CAUSE" ;;
  75)
    [ "${KENDEX_WORKTREE_CLAIM:-}" != required ] || notice held "$ROOT" \
      "Another lease holds this worktree; use a worktree you own or ask its owner to release it before starting work." "$CAUSE"
    ;;
  *) notice unclaimed "$ROOT" \
    "worktree-session-guard could not claim this worktree (exit $rc); a lease taken before this start may still stand" "$CAUSE" ;;
esac
