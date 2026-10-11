#!/usr/bin/env bash
# ---
# name: reviewer-read-only
# event: PreToolUse
# matcher: Edit|MultiEdit|NotebookEdit|Write|Bash
# description: For a subagent whose agent_type starts with `reviewer-`, refuses every Edit, MultiEdit and NotebookEdit call; a Write whose path lies inside a git work tree unless it is the review artifact, `<dir>/tmp/review-*.json`; and a Bash command that runs `git commit`, `push`, `checkout`, `restore`, a mutating `stash`, `clean`, `reset` or `switch` (options between `git` and the verb allowed). Any other agent, and a payload naming no agent_type, passes. Under Pi the pi-hooks carrier sends as agent_type the agent name a Pi subagent process is started with. Not run on codex: a write is `apply_patch` with no `tool_input.file_path`, so the review artifact cannot be told from any other write (Codex hooks reference, CLI 0.160.0). Not run on gemini: its tool-call payload is unmeasured. Not run on copilot: its preToolUse payload names no calling agent, only the caller's own session, and its subagentStart names the lead's session and no subagent id, so a reviewer's tool call cannot be joined to the reviewer (Copilot hooks reference, CLI 1.0.91). Not run on antigravity: its payload carries no agent field.
# summary: Keeps reviewer agents from edits, Git writes and Git discards. Git stash list and text that mentions these commands pass. Missing tools or unreadable input produce one warning and allow the call.
# safety: Advisory reader: dependency or payload failures warn once and allow the call. Executable command matches retain exit 2. The commit-guards command-position reader selects command words and masks quoted data and data-only here-document bodies. This is a lexical check; assembled command names and unknown launcher option forms are outside its contract. Every diagnostic starts with reviewer-read-only: <key>=<value>.
# timeout: 10
# harnesses: [claude, pi, opencode, cursor]
# requires-skills: [commit-guards]
# ---

set -euo pipefail
trap 'rc=$?; case $rc in 0 | 2) ;; *) refuse exit "$rc" ;; esac' EXIT

# Paths and command text are matched by byte ranges below; git's own
# messages are read in English.
export LC_ALL=C

# What the refusals name, empty until each is known: the calling subagent,
# whose type names the artifact path, the write's target, and git's own words
# on a question it could not answer.
AGENT_TYPE=""
TARGET=""
ANSWER=""
# Every line this hook writes, and the only place its text lives. The first
# line is the contract a reader parses, `reviewer-read-only: <key>=<value>`: a
# stable key for the condition and the value acted on — the missing tool, why
# the payload could not be read, the tool call refused, or the path a reviewer
# may not write. The English explanation follows it, and it never names a
# bypass.
# The keyed line stands first, at position 1. What a command this hook runs
# wrote is captured where the hook reads it and passed here as the cause, so
# it is replayed under the key rather than ahead of it.
refuse() { # KEY VALUE [CAUSE]
  {
    printf 'reviewer-read-only: %s=%s\n' "$1" "$2"
    case "$1=$2" in
      missing-tools=*)
        echo "the commands ${2//,/, } are required to read the hook payload and judge the path and are not on PATH; this check is unavailable"
        ;;
      payload=unreadable)
        echo "the hook payload could not be read from stdin"
        ;;
      payload=invalid-json)
        echo "the hook payload is not valid JSON, or a field this hook reads is not a string; this check is unavailable"
        ;;
      payload=no-file-path)
        echo "the Write payload names no file_path string; this check is unavailable"
        ;;
      refused=git-write)
        echo "a reviewer commits and pushes nothing; the orchestrator owns the branch. Report the finding in the review artifact instead."
        ;;
      refused=git-discard)
        echo "a reviewer discards, restores, stashes, resets or cleans nothing. A probe lives on a copy; an uncommitted edit belongs to its author."
        ;;
      refused=*)
        echo "a reviewer edits nothing. Findings go in the review artifact, written with the Write tool to <worktree>/tmp/review-$AGENT_TYPE-<timestamp>.json; the fix is the author's."
        ;;
      path=*)
        echo "a reviewer writes nothing into a repository but its artifact, <worktree>/tmp/review-$AGENT_TYPE-<timestamp>.json; $2 is not that path. A control file goes under a mktemp -d of your own."
        ;;
      git=unreadable)
        echo "git could not say whether $TARGET is inside a work tree, so the check is unavailable:"
        printf '%s\n' "$ANSWER"
        ;;
    esac
    # The cause a command this hook ran wrote, captured at the site and
    # replayed here: under the keyed line, never ahead of it.
    [ -z "${3:-}" ] || printf '%s\n' "$3"
  } >&2
  case "$1" in
    refused | path) exit 2 ;;
    *)
      echo "Check skipped. Repair the hook installation, tools or payload adapter; retry the command." >&2
      exit 0 ;;
  esac
}

# jq reads the payload, git checks whether a path is in a worktree, cat reads
# stdin, and dirname walks to the nearest existing directory. Check the tools
# before judging the call; the Bash arm matches with the shell's own regex.
MISSING=""
for dependency in jq git cat dirname; do
  command -v "$dependency" >/dev/null 2>&1 || MISSING="$MISSING,$dependency"
done
[ -z "$MISSING" ] || refuse missing-tools "${MISSING#,}"

# cat's words are captured, not left to precede the refusal: on failure the
# substitution holds what it wrote, and the refusal replays it under the keyed
# line. A cat that succeeds is silent, so the payload is not mixed with a
# diagnostic on the passing side.
INPUT=$(cat 2>&1) || refuse payload unreadable "$INPUT"

# One jq read for the strings the decision needs. A payload that does not
# parse, or whose agent_type or tool_name is not a string, warns and allows.
FIELDS=$(printf '%s' "$INPUT" | jq -er '
  def str($v): if $v == null then "" elif ($v | type) == "string" then $v else error("not a string") end;
  [str(.agent_type), str(.tool_name)] | @tsv' 2>/dev/null) || refuse payload invalid-json
TAB=$'\t'
AGENT_TYPE=${FIELDS%%"$TAB"*}
TOOL_NAME=${FIELDS#*"$TAB"}

case "$AGENT_TYPE" in
  reviewer-*) ;;
  *) exit 0 ;;
esac

case "$TOOL_NAME" in
  Edit | MultiEdit | NotebookEdit)
    refuse refused "$TOOL_NAME"
    ;;
  Write)
    TARGET=$(printf '%s' "$INPUT" | jq -er '.tool_input.file_path
      | if type == "string" then . else error("not a string") end' 2>/dev/null) ||
      refuse payload no-file-path
    case "$TARGET" in
      */tmp/review-*.json) exit 0 ;;
    esac
    # Inside a work tree or not is asked of the nearest directory that
    # exists, since Write creates the missing ones. "Not a git repository" is
    # the pass; any other failure is a git that could not answer.
    DIR=$(dirname -- "$TARGET" 2>&1) || refuse path-read unavailable "$DIR"
    while [ ! -d "$DIR" ] && [ "$DIR" != "/" ] && [ "$DIR" != "." ]; do
      DIR=$(dirname -- "$DIR")
    done
    if ANSWER=$(git -C "$DIR" rev-parse --is-inside-work-tree 2>&1); then
      if [ "$ANSWER" != "true" ]; then
        exit 0
      fi
      refuse path "$TARGET"
    fi
    case "$ANSWER" in
      *"not a git repository"*) exit 0 ;;
    esac
    refuse git unreadable
    ;;
  Bash)
    COMMAND=$(printf '%s' "$INPUT" | jq -er '.tool_input.command
      | if . == null then "" elif type == "string" then . else error("not a string") end' 2>/dev/null) ||
      refuse payload invalid-json
# Resolve only this hook's installed dependency, never a payload-selected path.
reader=""
for candidate in "${BASH_SOURCE[0]%/*}/../skills/commit-guards/scripts/lib/command-position.sh" \
  "${BASH_SOURCE[0]%/*}/../.agents/skills/commit-guards/scripts/lib/command-position.sh" \
  "${BASH_SOURCE[0]%/*}/../../.agents/skills/commit-guards/scripts/lib/command-position.sh" \
  "${BASH_SOURCE[0]%/*}/../../../.agents/skills/commit-guards/scripts/lib/command-position.sh" \
  "${BASH_SOURCE[0]%/*}/../../skills/commit-guards/scripts/lib/command-position.sh" \
  "${HOME:+$HOME/.agents/skills/commit-guards/scripts/lib/command-position.sh}"; do
  if [ -f "$candidate" ]; then reader=$candidate; break; fi
done
[ -n "$reader" ] || refuse reader unavailable
# shellcheck source=../skills/commit-guards/scripts/lib/command-position.sh
source "$reader" 2>/dev/null || refuse reader unreadable
    # Options may take a value. The selected Git subcommand must be its own
    # word; commit-tree and cat-file commit remain reads.
    GIT_WRITE='^git([[:space:]]+(-C|-c|--git-dir|--work-tree|--namespace|--exec-path)[[:space:]]+[^[:space:]]+|[[:space:]]+-[^[:space:]]*)*[[:space:]]+(commit|push)([[:space:]]|$|[;|)&])'
    GIT_DISCARD='^git([[:space:]]+(-C|-c|--git-dir|--work-tree|--namespace|--exec-path)[[:space:]]+[^[:space:]]+|[[:space:]]+-[^[:space:]]*)*[[:space:]]+(checkout|restore|stash|clean|reset|switch)([[:space:]]|$|[;|)&])'
    STASH_READ='^git([[:space:]]+(-C|-c|--git-dir|--work-tree|--namespace|--exec-path)[[:space:]]+[^[:space:]]+|[[:space:]]+-[^[:space:]]*)*[[:space:]]+stash[[:space:]]+list([[:space:]]|$)'
    command_segments "$COMMAND"
    while IFS= read -r segment; do
      command_text "$segment"
      selected=${COMMAND_TEXTS%"$NL"}
      [ -n "$selected" ] || continue
      [[ ! $selected =~ $STASH_READ ]] || continue
      if [[ $selected =~ $GIT_WRITE ]]; then refuse refused git-write; fi
      if [[ $selected =~ $GIT_DISCARD ]]; then refuse refused git-discard; fi
    done <<<"$SEGMENTS"
    exit 0
    ;;
esac

exit 0
