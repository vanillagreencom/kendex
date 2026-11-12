#!/usr/bin/env bash
# ---
# name: reviewer-read-only
# event: PreToolUse
# matcher: Edit|MultiEdit|NotebookEdit|Write|Bash
# description: For a subagent whose agent_type starts with `reviewer-`, refuses every Edit, MultiEdit and NotebookEdit call; a Write whose path lies inside a git work tree unless it is the review artifact, `<dir>/tmp/review-*.json`; and a Bash command that runs `git commit`, `push`, `checkout`, `restore`, `stash` (all subcommands), `clean`, `reset` or `switch` (options between `git` and the verb allowed), or `rm` (`git rm` too) on a path inside a git work tree, a relative operand judged against the payload's `cwd`, where the call starts, whatever `cd` precedes it, since a failed `cd` leaves the shell there. Any other agent, and a payload naming no agent_type, passes. Under Pi the pi-hooks carrier sends as agent_type the agent name a Pi subagent process is started with. Not run on codex: a write is `apply_patch` with no `tool_input.file_path`, so the review artifact cannot be told from any other write (Codex hooks reference, CLI 0.160.0). Not run on gemini: its tool-call payload is unmeasured. Not run on copilot: its preToolUse payload names no calling agent, only the caller's own session, and its subagentStart names the lead's session and no subagent id, so a reviewer's tool call cannot be joined to the reviewer (Copilot hooks reference, CLI 1.0.91). Not run on antigravity: its payload carries no agent field.
# summary: Keeps a reviewer agent read-only: no edits, no commits, no pushes, no Git commands that discard work, only its review report.
# safety: Reads the payload and asks git whether a path is inside a work tree; writes nothing. The Bash arm matches raw command text, including quoted mentions, and refuses every stash command. The delete check takes the words after each `rm` up to a control operator, strips their quotes and asks git where each lies. A word holding a `$` or backtick expansion names nothing before the shell runs and is not judged, and a word that opens or closes a quote ends the words judged, so an `rm` inside a quoted string, a grep pattern or a `bash -c` body alike, and an operand holding spaces are not judged past it. Missing tools, unreadable payload or an unreadable Git path check produce one keyed warning and allow the call. The refusal names the artifact path a reviewer may write, or the `mktemp -d` scratch a reviewer may delete in, and never suggests bypassing. Every refusal opens with `reviewer-read-only: <key>=<value>`; what a command this hook runs writes is captured at the site and replayed under that line, so nothing precedes the key.
# timeout: 10
# harnesses: [claude, pi, opencode, cursor]
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
      delete=*)
        echo "a reviewer deletes nothing inside a work tree; $2 is in one, and a delete there can take its author's uncommitted work. A control file goes under a mktemp -d of your own and is deleted there, named by its absolute path."
        ;;
      grep=unreadable)
        echo "grep could not read the command text, so its deletes could not be judged"
        ;;
      git=unreadable)
        echo "git could not say whether $TARGET is inside a work tree, so the call could not be judged:"
        printf '%s\n' "$ANSWER"
        ;;
    esac
    # The cause a command this hook ran wrote, captured at the site and
    # replayed here: under the keyed line, never ahead of it.
    [ -z "${3:-}" ] || printf '%s\n' "$3"
  } >&2
  case "$1" in
    refused | path | delete) exit 2 ;;
    *)
      echo "Check skipped. Repair the hook installation, tools or payload adapter; retry the command." >&2
      exit 0 ;;
  esac
}

# Whether PATH lies inside a git work tree, asked of the nearest directory
# that exists, since a Write creates the missing ones and a delete may name a
# glob. A symlink is judged by the directory holding it, where the entry a
# delete removes lies. "Not a git repository" is the no; any other failure is
# a git that could not answer, and warns.
in_work_tree() { # PATH -> 0 inside, 1 outside
  local dir="$1"
  TARGET=$1
  if [ -L "$dir" ] || [ ! -d "$dir" ]; then
    dir=$(dirname -- "$dir" 2>&1) || refuse path-read unavailable "$dir"
  fi
  while [ ! -d "$dir" ] && [ "$dir" != "/" ] && [ "$dir" != "." ]; do
    dir=$(dirname -- "$dir" 2>&1) || refuse path-read unavailable "$dir"
  done
  if ANSWER=$(git -C "$dir" rev-parse --is-inside-work-tree 2>&1); then
    [ "$ANSWER" = "true" ]
    return
  fi
  case "$ANSWER" in
    *"not a git repository"*) return 1 ;;
  esac
  refuse git unreadable
}

# Every external command this hook runs. jq reads the payload and git answers
# whether a path is inside a work tree; cat hands the payload over, grep decides
# the Bash arm, and dirname walks up to the nearest existing directory. An
# unchecked absence is not a stall but a pass: a missing grep makes the
# git-write test a no-match, and a missing dirname aborts the Write arm on a
# status the harness runs past. So the whole set is checked before anything is
# judged, and the value names every one of them the PATH is missing, in the
# order checked.
MISSING=""
for dependency in jq git cat grep dirname; do
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
    if in_work_tree "$TARGET"; then
      refuse path "$TARGET"
    fi
    exit 0
    ;;
  Bash)
    COMMAND=$(printf '%s' "$INPUT" | jq -er '.tool_input.command
      | if . == null then "" elif type == "string" then . else error("not a string") end' 2>/dev/null) ||
      refuse payload invalid-json
    # `git`, then any run of options (a value-taking one with its value),
    # then the verb as its own word. `git cat-file commit` and `git
    # commit-tree` are reads and do not match.
    GIT_WRITE='(^|[^[:alnum:]_.-])git([[:space:]]+(-C|-c|--git-dir|--work-tree|--namespace|--exec-path)[[:space:]]+[^[:space:]]+|[[:space:]]+-[^[:space:]]*)*[[:space:]]+(commit|push)([[:space:]]|$|[;|)&])'
    GIT_DISCARD='(^|[^[:alnum:]_.-])git([[:space:]]+(-C|-c|--git-dir|--work-tree|--namespace|--exec-path)[[:space:]]+[^[:space:]]+|[[:space:]]+-[^[:space:]]*)*[[:space:]]+(checkout|restore|stash|clean|reset|switch)([[:space:]]|$|[;|)&])'
    # Never `grep -q` here: an early exit turns the producer's SIGPIPE into
    # status 141 under pipefail, read as no match.
    if printf '%s\n' "$COMMAND" | grep -E -- "$GIT_WRITE" >/dev/null; then
      # grep decides, so the verb it matched is not in hand; the value names
      # the pair the pattern stands for.
      refuse refused git-write
    fi
    if printf '%s\n' "$COMMAND" | grep -E -- "$GIT_DISCARD" >/dev/null; then
      refuse refused git-discard
    fi
    # A delete inside a work tree can take uncommitted work with it. `rm` as
    # its own word (`git rm` too), its words up to a control operator, and a
    # redirection that ends them. A relative operand is judged against the
    # payload's cwd, where the call starts: a `cd` before it may have failed
    # and left the shell there.
    RM_CALL='(^|[^[:alnum:]_.-])rm([[:space:]]+[^[:space:]&;|()<>]+)*[<>]?'
    RM_CALLS=$(printf '%s\n' "$COMMAND" | grep -oE -- "$RM_CALL") || [ $? -eq 1 ] || refuse grep unreadable
    [ -n "$RM_CALLS" ] || exit 0
    CWD=$(printf '%s' "$INPUT" | jq -er '.cwd
      | if . == null then "" elif type == "string" then . else error("not a string") end' 2>/dev/null) ||
      refuse payload invalid-json
    # A harness whose payload names no cwd starts the hook where the call runs.
    [ -n "$CWD" ] || CWD=$PWD
    while IFS= read -r CALL; do
      WORDS=${CALL#*rm}
      # A redirection's file descriptor number is not an operand.
      case "$WORDS" in
        *[\<\>])
          WORDS=${WORDS%?}
          if [[ $WORDS =~ ^(.*[[:space:]])[0-9]+$ ]]; then WORDS=${BASH_REMATCH[1]}; fi
          ;;
      esac
      # read splits on whitespace and expands no glob.
      read -r -a ARGS <<<"$WORDS"
      ENDED=""
      for WORD in ${ARGS[@]+"${ARGS[@]}"}; do
        # A word that opens or closes a quote ends the call: the `rm` sat in
        # a quoted string, such as a grep pattern, or an operand holds spaces.
        DQ=${WORD//[!\"]/}
        SQ=${WORD//[!\']/}
        if [ $((${#DQ} % 2 + ${#SQ} % 2)) -ne 0 ]; then break; fi
        if [ -z "$ENDED" ]; then
          case "$WORD" in
            --) ENDED=1; continue ;;
            -*) continue ;;
          esac
        fi
        WORD=${WORD//[\"\'\\]/}
        # An expansion names nothing until the shell runs it.
        case "$WORD" in
          '' | *[\$\`]* | \~[!/]*) continue ;;
          \~ | \~/*) WORD=$HOME${WORD#\~} ;;
          /*) ;;
          *) WORD=$CWD/$WORD ;;
        esac
        if in_work_tree "$WORD"; then
          refuse delete "$WORD"
        fi
      done
    done <<<"$RM_CALLS"
    exit 0
    ;;
esac

exit 0
