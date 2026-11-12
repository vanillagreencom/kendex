#!/usr/bin/env bash
# ---
# name: reviewer-read-only
# event: PreToolUse
# matcher: Edit|MultiEdit|NotebookEdit|Write|Bash
# description: For a subagent whose agent_type starts with `reviewer-`, refuses every Edit, MultiEdit and NotebookEdit call; a Write whose path lies inside a git work tree unless it is the review artifact, `<dir>/tmp/review-*.json`; and a Bash command that runs `git commit`, `push`, `checkout`, `restore`, `stash` (all subcommands), `clean`, `reset` or `switch` (options between `git` and the verb allowed). Its delete model stops a cooperating reviewer deleting work-tree files with ordinary `rm` or `git rm` commands as Bash reads them after line joining. A relative operand is judged against the call's starting directory (payload `cwd`, or the hook's working directory on Pi); `git -C` moves it for that Git command only. Expansions (variables, command substitution, `eval`, here-docs) and other deleting programs are outside this model and remain the reviewer's read-only role and tools' responsibility. The scan is quote-blind and can also refuse quoted text. Any other agent, and a payload naming no agent_type, passes. Under Pi the pi-hooks carrier sends as agent_type the agent name a Pi subagent process is started with. Not run on codex: a write is `apply_patch` with no `tool_input.file_path`, so the review artifact cannot be told from any other write (Codex hooks reference, CLI 0.160.0). Not run on gemini: its tool-call payload is unmeasured. Not run on copilot: its preToolUse payload names no calling agent, only the caller's own session, and its subagentStart names the lead's session and no subagent id, so a reviewer's tool call cannot be joined to the reviewer (Copilot hooks reference, CLI 1.0.91). Not run on antigravity: its payload carries no agent field.
# summary: Stops a cooperating reviewer's edits, commits, pushes, Git commands that discard work, and ordinary `rm` or `git rm` deletes in a work tree; lets it write its review report.
# safety: Reads the payload and asks git whether a path is inside a work tree; writes nothing. The Git verb checks match raw command text, including quoted mentions, and refuse every stash command. The delete model covers a cooperating reviewer's ordinary `rm` and `git rm` commands after Bash line joining. It does not model expansions (variables, command substitution, `eval`, here-docs) or other deleting programs; the reviewer's read-only role and tools own those. The quote-blind scan first removes backslash-newline pairs, then drops quote marks and backslashes, then turns command separators into line boundaries, preserving the pipe in `>|` and the ampersand in a redirection such as `2>&1` or `&>`. It judges every remaining `rm` word, `/bin/rm` too, so quoted strings and bodies can also cause refusals. Each segment splits on whitespace. After `rm` or `git rm`, options and redirection operator/target words are skipped; every remaining word is judged as an operand, including words after redirections. A redirection target attached to its operator is skipped with that word; a separate target is the next word. Semicolons, command ampersands, command pipes, parentheses, backticks and newlines end the segment. A relative operand uses the call's starting directory regardless of preceding `cd`, since that `cd` can fail; `git -C` moves the base for that Git command only. An operand holding a `$` or backtick expansion names nothing before the shell runs and is not judged. A search pattern written `[r]m` and a script file run by its path are not read as an rm. Missing tools, unreadable payload or an unreadable Git path check produce one keyed warning and allow the call. A delete refusal names the clearing routes: write a search pattern as `[r]m`, put a body that runs elsewhere in a script file under a `mktemp -d` of its own and run that file, delete scratch in that `mktemp -d`, and leave a probe it made in a work tree named in its report. Every refusal opens with `reviewer-read-only: <key>=<value>`; command diagnostics follow that key.
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
        echo "a reviewer deletes nothing inside a work tree; $2 is in one, and a delete there can take its author's uncommitted work. This check reads every rm in the command, quoted or not. Write a search pattern as [r]m. Put a body that runs elsewhere, such as a mutation-stability --mutate body or a bash -c script, in a script file under a mktemp -d of your own and run that file. A control file goes under that mktemp -d too and is deleted there, named by its absolute path. A probe you made in a work tree stays: leave it and name it in your report."
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

# Join Bash continuations before dropping backslashes: otherwise the
# preserved newline separates an rm from the path Bash gives it. The
# quote-blind scan also matches quoted mentions; it does not evaluate them.
# Shell separators then become line boundaries once, so neither Git-option
# branch can carry a directory into a later command.
judge_deletes() {
  local bare call words word state base ended redirect_target redirection
  redirection='^(&|[0-9]*)(<>|>>|>\||>|<)(&?)(.*)$'
  # jq drops the quote marks: a Bash 3.2 pattern substitution over the
  # command takes time that grows with its length squared. A redirection's
  # ampersand and the pipe in >| belong to their words; other ampersands
  # and pipes end the command.
  bare=$(printf '%s' "$INPUT" | jq -er '.tool_input.command
    | split("\\\n") | join("")
    | explode | map(select(. != 34 and . != 39 and . != 92)) | implode
    | gsub("[;()`]|(?<!>)\\||(?<![<>])&(?!>)"; "\n")' 2>/dev/null) ||
    refuse payload invalid-json
  while IFS= read -r call; do
    [ -n "$call" ] || continue
    # read splits on whitespace and expands no glob. Redirections remove
    # their own operator and target, never the operands that follow them.
    read -r -a words <<<"$call"
    state=search base=$CWD ended="" redirect_target=""
    for word in ${words[@]+"${words[@]}"}; do
      if [ -n "$redirect_target" ]; then redirect_target=""; continue; fi
      if [[ $word =~ $redirection ]]; then
        [ -n "${BASH_REMATCH[4]}" ] || redirect_target=1
        continue
      fi
      case $state in
        search)
          case $word in
            git | */git) state=git; base=$CWD ;;
            rm | */rm) state=rm ;;
          esac
          continue
          ;;
        git)
          case $word in
            -C) state=dir ;;
            -c | --git-dir | --work-tree | --namespace | --exec-path) state=value ;;
            -*) ;;
            rm) state=rm ;;
            *) state=search; base=$CWD ;;
          esac
          continue
          ;;
        dir)
          state=git
          case $word in
            *[\$\`]*) base="" ;;
            /*) base=$word ;;
            *) base=$base/$word ;;
          esac
          continue
          ;;
        value) state=git; continue ;;
      esac
      judge_operand
    done
  done <<<"$bare"
}

# Refuses an rm operand inside a work tree. A relative operand lies under the
# directory the call starts in, whatever `cd` precedes it, since a failed `cd`
# leaves the shell there; `git -C` moves it for that command only.
# An operand holding an expansion
# names nothing before the shell runs and is not judged.
judge_operand() {
  local path=$word
  if [ -z "$ended" ]; then
    case $path in
      --) ended=1; return 0 ;;
      -*) return 0 ;;
    esac
  fi
  if [ -z "$base" ]; then return 0; fi
  case $path in
    '' | *[\$\`]* | \~[!/]*) return 0 ;;
    \~ | \~/*) path=$HOME${path#\~} ;;
    /*) ;;
    *) path=$base/$path ;;
  esac
  if in_work_tree "$path"; then
    refuse delete "$path"
  fi
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
    # A continuation can form an rm word only after Bash line joining.
    # Send every such command through normalization before judging it.
    case "$COMMAND" in
      *rm* | *$'\\\n'*) ;;
      *) exit 0 ;;
    esac
    CWD=$(printf '%s' "$INPUT" | jq -er '.cwd
      | if . == null then "" elif type == "string" then . else error("not a string") end' 2>/dev/null) ||
      refuse payload invalid-json
    # A harness whose payload names no cwd starts the hook where the call
    # runs: the Pi carrier spawns it in the session's directory.
    [ -n "$CWD" ] || CWD=$PWD
    judge_deletes
    exit 0
    ;;
esac

exit 0
