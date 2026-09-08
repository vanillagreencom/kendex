#!/usr/bin/env bash
# ---
# name: block-worktree-refresh
# event: PreToolUse
# matcher: Bash
# description: Refuse a `kendex` command that writes the project scope (`refresh`, `apply`, `add`, `remove`, `update-pi`, `updates --apply`, `pin`, `fork`, `adopt`, `drift-hook`, `source add|remove|enable|disable`, `marketplace subscribe|unsubscribe`) when the working directory is a linked git worktree and the command does not name the global scope, and whenever a `cd` or `pushd` stands before the verb in the same command, since the directory the write lands in cannot then be read from the command. A project's kendex install is registered to the main checkout, so a project-scope write from a linked worktree renders into that checkout and removes what it does not expect there. Names the two forms that are right: the same command from the main checkout, or the verb's global form (`--global` for add, `--scope global` for update-pi, either for the rest).
# safety: Reads the command text and asks git whether the working directory's git dir differs from its common dir, which is what makes a worktree linked; writes nothing. A git that cannot answer refuses. The verb is read as a word after a `kendex` word, wherever in the command it stands, so a command that merely spells the pair in prose is refused, and that is the accepted cost; the bare `kendex <source>` shorthand for add is not read, since matching it would match every read too. `kendex verify`, `check`, `list`, `report` and every other verb pass; a command carrying `-g`, `--global` or `--scope global` in the verb's own segment, with no `--scope project` or `--scope all` beside it, passes because it names the scope this hook does not guard. A payload that cannot be read, an empty one included, is refused, never skipped. Refusals carry the line `block-worktree-refresh: <key>=<value>`; a reader matches that prefix, not line 1, because a command this hook runs may write its own diagnostic first.
# timeout: 10
# ---

set -euo pipefail

# What the refusals name, empty until each is known: the kendex verb, the
# working directory judged, the global form of that verb, the .git entry git
# could not read, and git's own words on a question it could not answer.
VERB=""
CWD=""
GLOBAL_FORM=""
AT=""
REASON=""
# Every line this hook writes, and the only place its text lives. The first
# line is the contract a reader parses, `block-worktree-refresh: <key>=<value>`:
# a stable key for the condition and the value acted on — the missing tool, why
# the payload could not be read, the verb refused, or git's exit status. The
# English explanation and the two forms that are right follow on later lines.
# A reader matches `^block-worktree-refresh: `, not line 1: a command this hook
# runs may write its own diagnostic to the same stream first, and that line
# names a cause the keyed one does not carry.
refuse() { # KEY VALUE
  printf 'block-worktree-refresh: %s=%s\n' "$1" "$2" >&2
  case "$1=$2" in
    missing-tools=*)
      echo "the commands ${2//,/, } are required to read the hook payload and the worktree and are not on PATH; refusing rather than skipping the guard" >&2
      ;;
    payload=unreadable)
      echo "the hook payload could not be read from stdin; refusing rather than skipping the guard" >&2
      ;;
    payload=empty)
      echo "the hook payload is empty, which would read as an absent command; refusing rather than skipping the guard" >&2
      ;;
    payload=invalid-json)
      echo "the hook payload is not valid JSON, or names a command that is not a string; refusing rather than skipping the guard" >&2
      ;;
    payload=invalid-cwd)
      echo "the payload's cwd is not a string; refusing rather than skipping the guard" >&2
      ;;
    moved=*)
      echo "refusing 'kendex $VERB' at project scope after a cd or pushd in the same command: the directory the write lands in cannot be established from the command's words." >&2
      echo "  Run kendex from the main checkout as its own command (the first line of 'git worktree list' names it), or pass $GLOBAL_FORM for a global change." >&2
      ;;
    refused=*)
      echo "refusing 'kendex $VERB' at project scope from the linked worktree $CWD." >&2
      echo "  The project install is registered to the main checkout (the first line of 'git worktree list'); a project-scope write from here renders into that checkout and removes what it does not expect there." >&2
      echo "  Run the same command from the main checkout, or pass $GLOBAL_FORM for a global change. Reads (kendex verify, check, list) are not refused." >&2
      ;;
    git=unreadable)
      echo "$AT/.git exists but git could not read a repository there, so whether $CWD is a linked worktree is unknown and the write is refused" >&2
      ;;
    git=unresolvable)
      echo "the git directories git named under $CWD could not be entered, so the write is refused" >&2
      ;;
    git=*)
      echo "git could not say whether $CWD is a linked worktree, so the write is refused:" >&2
      printf '%s\n' "$REASON" >&2
      ;;
  esac
  exit 2
}

# jq reads the payload and git answers the one question. Without either the
# command cannot be judged, and an unjudged command is refused. The value names
# every one of them the PATH is missing, in the order checked.
MISSING=""
for dependency in jq git cat; do
  command -v "$dependency" >/dev/null 2>&1 || MISSING="$MISSING,$dependency"
done
[ -z "$MISSING" ] || refuse missing-tools "${MISSING#,}"

# cat keeps its own words: they say which failure it was — a directory on
# stdin, a closed descriptor, a read error — and `payload=unreadable` carries
# the verdict, not the cause.
INPUT=$(cat) || refuse payload unreadable
# An empty payload is no payload: jq reads nothing from it and says nothing,
# which would pass as an absent command.
case "$INPUT" in
  *[![:space:]]*) ;;
  *) refuse payload empty ;;
esac

# A payload that does not parse, or that names a command which is not a
# string, is refused rather than skipped. An absent command is the empty
# string and passes. The command is read where each harness carries it:
# `tool_input.command` (Claude Code, Codex, Gemini CLI and the Pi carrier), a
# bare `command`, or Copilot's `toolArgs.command`, whose `toolArgs` arrives as
# an object or as one JSON-encoded string. The null tests are spelled out
# because jq's `//` reads `false` as absent, and `false` is not a command
# either.
COMMAND=$(printf '%s' "$INPUT" \
  | jq -r 'def copilot: .toolArgs
             | if . == null then null elif type == "string" then fromjson else . end
             | if . == null then null elif type == "object" then .command else error end;
           if .tool_input.command != null then .tool_input.command
           elif .command != null then .command
           elif copilot != null then copilot
           else "" end
           | if type == "string" then . else error end' 2>/dev/null) ||
  refuse payload invalid-json

# The verb as a word after a `kendex` word, judged one segment at a time: a
# segment is the text between two of `;`, `&`, `|`, `(`, `)` and a line end,
# with a backslash-newline continuing it, and it ends at a `#` that begins a
# word, since the shell drops the comment behind it. The global scope is not
# this hook's, and `-g`, `--global` or `--scope global` exempts a write only
# when it stands in the verb's own segment and no `--scope project` or
# `--scope all` stands there too, because kendex gives `--scope` precedence
# over `--global`; read across the whole command the word would let
# `kendex refresh -g && kendex refresh` through on the first command's word.
# `kendex updates` is a write only with `--apply`, which delegates to refresh.
# The bare `kendex <source>` shorthand for add is not read: matching it means
# matching every `kendex <word>`, reads included, and that is the whole CLI.
NL=$'\n'
SEGMENTS=${COMMAND//\\$NL/ }
SEGMENTS=${SEGMENTS//;/$NL}
SEGMENTS=${SEGMENTS//&/$NL}
SEGMENTS=${SEGMENTS//\|/$NL}
SEGMENTS=${SEGMENTS//\(/$NL}
SEGMENTS=${SEGMENTS//\)/$NL}
# A quote may close the command word or wrap the verb, as in
# `"/path/kendex" refresh` and `kendex 'refresh'`, and any words may stand
# between them, as in `kendex --global refresh` or `kendex --harness claude
# refresh`. Those root options and their values are dropped by the CLI once a
# subcommand follows, so only the words AFTER the verb are read for the scope;
# a `--global` before it exempts nothing.
# The verbs are every shipped command that writes a scope: the item verbs,
# `updates --apply`, `pin`, `fork`, `adopt`, `drift-hook`, and the writing
# subcommands of `source` and `marketplace`.
WRITE_RE='(^|[^[:alnum:]_.-])kendex["'"'"']?([[:space:]]+[^[:space:]]+)*[[:space:]]+["'"'"']?(refresh|apply|add|remove|update-pi|updates|pin|fork|adopt|drift-hook|source[[:space:]]+(add|remove|enable|disable)|marketplace[[:space:]]+(subscribe|unsubscribe))["'"'"']?([[:space:]]|$)'
GLOBAL_RE='(^|[[:space:]])(-g|--global|--scope([[:space:]]+|=)global)([[:space:]]|$)'
# Any `--scope` after the verb that is not the plain word `global` names the
# project scope or one this hook cannot read (a quoted value included), and
# kendex gives `--scope` precedence over `--global`, so it is the project write.
SCOPE_RE='(^|[[:space:]])--scope([[:space:]]+|=)'
SCOPE_GLOBAL_RE='(^|[[:space:]])--scope([[:space:]]+|=)global([[:space:]]|$)'
APPLY_RE='(^|[[:space:]])--apply([[:space:]]|$)'
CHECK_RE='(^|[[:space:]])(--check|-c)([[:space:]]|$)'
# A `cd` or `pushd` word in the verb's segment or an earlier one moves the
# shell before kendex runs, so the directory git is asked about below is not
# the one the write lands in; such a command is refused whatever that
# directory says, since the effective one cannot be established from words.
MOVE_RE='(^|[^[:alnum:]_.-])(cd|pushd)([[:space:]]|$)'
MOVED=""
while IFS= read -r SEGMENT; do
  case "$SEGMENT" in
    \#*) continue ;;
    *[[:blank:]]\#*) SEGMENT=${SEGMENT%%[[:blank:]]\#*} ;;
  esac
  [[ $SEGMENT =~ $MOVE_RE ]] && MOVED=1
  [[ $SEGMENT =~ $WRITE_RE ]] || continue
  # The verb and the words after it are taken before the option tests, which
  # reset BASH_REMATCH. The tail keeps a leading space so a word at its start
  # still has an edge.
  FOUND=${BASH_REMATCH[3]}
  TAIL=" ${SEGMENT#*"${BASH_REMATCH[0]}"}"
  if [ "$FOUND" = updates ] && ! [[ $TAIL =~ $APPLY_RE ]]; then
    continue
  fi
  # `update-pi --check` previews and writes nothing.
  if [ "$FOUND" = update-pi ] && [[ $TAIL =~ $CHECK_RE ]]; then
    continue
  fi
  if [[ $TAIL =~ $SCOPE_RE ]] && ! [[ $TAIL =~ $SCOPE_GLOBAL_RE ]]; then
    VERB=$FOUND
    break
  fi
  if [[ $TAIL =~ $GLOBAL_RE ]]; then
    continue
  fi
  VERB=$FOUND
  break
done <<EOF
$SEGMENTS
EOF
if [ -z "$VERB" ]; then
  exit 0
fi
# `add` takes the global scope as `--global` alone; `update-pi` as `--scope
# global` alone; the other verbs take either.
case "$VERB" in
  add) GLOBAL_FORM='--global' ;;
  update-pi) GLOBAL_FORM='--scope global' ;;
  *) GLOBAL_FORM='--scope global (or --global)' ;;
esac
if [ -n "$MOVED" ]; then
  refuse moved "$VERB"
fi

# The working directory is the payload's cwd where the harness sends one
# (Claude Code, Codex, Gemini CLI and Copilot), else the directory the hook
# runs in (the Pi carrier).
# The assignment stands inside the condition: bare, its own status would end
# the script under errexit and the empty-cwd test below would never run.
if ! CWD=$(printf '%s' "$INPUT" \
  | jq -r 'if .cwd == null then "" elif (.cwd | type) == "string" then .cwd else error end' 2>/dev/null); then
  refuse payload invalid-cwd
fi
[ -n "$CWD" ] || CWD=$PWD

# Git answers for the directory itself: the redirect variables that would make
# it answer for another repository are dropped, as kendex drops them, and its
# messages are read in English.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_CEILING_DIRECTORIES
export LC_ALL=C
# Outside a repository there is no worktree to protect and kendex answers for
# itself. Git names that case with a parenthetical on the parents it searched
# (the parent directories, or the parents up to a mount point); a `.git` file
# that points nowhere gets the same words without it, and that is a repository
# git could not read, not the absence of one. Any other failure is a git that
# could not answer, and an unanswered question refuses. The answer is read
# from stdout alone; the reason for a failure is read from stderr only once
# there is one, so tracing git cannot turn an answer into a refusal.
if ! DIRS=$(git -C "$CWD" rev-parse --git-dir --git-common-dir 2>/dev/null); then
  REASON_STATUS=0
  REASON=$(git -C "$CWD" rev-parse --git-dir --git-common-dir 2>&1 >/dev/null) || REASON_STATUS=$?
  case "$REASON" in
    *"not a git repository (or any"*)
      # Git says the same words above a `.git` entry it could not read as
      # above none at all. A `.git` on the way up is a repository that could
      # not be read, and the write is refused; none is the absence.
      AT=$(cd -- "$CWD" 2>/dev/null && pwd -P) || AT=$CWD
      while :; do
        if [ -e "$AT/.git" ] || [ -L "$AT/.git" ]; then
          refuse git unreadable
        fi
        [ "$AT" != / ] || exit 0
        AT=${AT%/*}
        [ -n "$AT" ] || AT=/
      done
      ;;
  esac
  # The status git left is the value: it is what separates a repository git
  # refused to read from a directory it could not reach.
  refuse git "$REASON_STATUS"
fi
GIT_DIR_LINE=${DIRS%%$'\n'*}
COMMON_DIR_LINE=${DIRS#*$'\n'}
# Both answers are relative to CWD when git prints them short; resolving each
# to a physical path is what lets the comparison hold across symlinked roots.
resolve() { # PATH -> physical path on stdout, relative to CWD when relative
  case "$1" in
    /*) (cd -- "$1" && pwd -P) ;;
    *) (cd -- "$CWD/$1" && pwd -P) ;;
  esac
}
if ! GIT_DIR=$(resolve "$GIT_DIR_LINE") || ! COMMON_DIR=$(resolve "$COMMON_DIR_LINE"); then
  refuse git unresolvable
fi
if [ "$GIT_DIR" = "$COMMON_DIR" ]; then
  exit 0
fi

# The main checkout is not derived from the common dir, which a repository
# made with --separate-git-dir keeps outside its checkout; `git worktree list`
# names the checkout first.
refuse refused "$VERB"
