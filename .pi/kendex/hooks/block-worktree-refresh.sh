#!/usr/bin/env bash
# ---
# name: block-worktree-refresh
# event: PreToolUse
# matcher: Bash
# description: Refuse a `kendex` command that writes the project scope (`refresh`, `apply`, `add`, `remove`, `update-pi`, `updates --apply`, `pin`, `fork`, `adopt`, `drift-hook`, `source add|remove|enable|disable`, `marketplace subscribe|unsubscribe`) when the working directory is a linked git worktree and the command does not name the global scope, and whenever a `cd` or `pushd` stands before the verb in the same command, since the directory the write lands in cannot then be read from the command. A linked worktree whose root carries no kendex.toml of its own checks out the main checkout's project, so a project-scope write from it renders into that checkout and removes what it does not expect there. One whose root carries its own kendex.toml is a project in its own right, and the verbs that write one project by being typed inside it (`add`, `remove`, `fork`, `pin`, `adopt`, `drift-hook` and the writing `source` and `marketplace` subcommands) pass there. `refresh`, `apply` and `updates --apply` pass in any worktree once they name their target with `--project-path PATH`: the directory the write lands in is then the command's own word, which is the one thing this guard is missing; `update-pi` is refused in both. Names the forms that are right: `--project-path PATH` where the verb takes it, the same command from the main checkout, or the verb's global form where its parser has one (`--global` for add, `--scope global` for update-pi, none for the `source` subcommands, either for the rest).
# summary: Stops a kendex command that writes a project from inside a linked git worktree, where the write would land somewhere the command does not name.
# safety: Reads the command text and asks git whether the tool call's working directory has a git dir that differs from its common dir, which is what makes a worktree linked, and for a linked worktree its root, where it tests whether a kendex.toml exists without reading it; writes nothing. A git that cannot answer refuses. The verb is the first word naming one after a `kendex` word, anywhere in the command except the text the shell would not run: the words inside a quoted span, a heredoc body its command reads as data, and a comment are masked out before the command is read, so prose spelling the pair is not refused, while a span or a heredoc body that a shell, `eval`, `source` or `.` word runs is read as the command it is; a quote that cannot be paired leaves the whole text to be read, so a command this hook could not take apart is refused rather than passed. The command is read by the commit-guards skill's command-position library, found in the install beside the hook; without it every call is refused. The bare `kendex <source>` shorthand for add is not read, since matching it would match every read too. A matched verb with `--help` or `--plan` as an argument and no `<`, `>`, backslash, single quote or double quote in its tail, `kendex updates` without `--apply`, `kendex verify`, `list`, `report`, `check` — whose one write, the scope's install record for copies it proves against their source, renders nothing into any checkout — and every other verb pass. The scope, target and apply options are read from the words Bash passes kendex after the verb in its own segment: a redirection operator and the file it opens are not arguments, a standalone `--` ends the options, and a word the shell settles only when it runs (an expansion, a glob, a brace, or a backslash) grants no exemption and counts as `--apply`. A command carrying `-g`, `--global` or `--scope global` there, with no other `--scope` beside it, passes because it names the scope this hook does not guard, and a `refresh`, `apply` or `updates` carrying `--project-path` there passes because it names the project it writes, the value itself being read by kendex, which refuses the flag without one. A payload that cannot be read, an empty one included, is refused, never skipped. Every refusal opens with `block-worktree-refresh: <key>=<value>`; what a command this hook runs writes is captured at the site and replayed under that line, so nothing precedes the key.
# timeout: 10
# ---

set -euo pipefail

# What the refusals name, empty until each is known: the kendex verb, the
# working directory judged, the linked worktree's root and whose project it
# is (`worktree` where the root carries its own kendex.toml, `main` where
# it carries none), the .git entry git could not read, and git's own words
# on a question it could not answer.
VERB=""
CWD=""
TOP=""
OWNER=""
AT=""
REASON=""
# The forms of VERB that are right, set by `forms` for the refusal naming
# them: its global form where its parser takes one, empty for the `source`
# subcommands, which have none, and its named-target form where it has one.
GLOBAL_FORM=""
TARGET_FORM=""
forms() { # VERB -> GLOBAL_FORM, TARGET_FORM
  case "$1" in
    add) GLOBAL_FORM='--global' ;;
    update-pi) GLOBAL_FORM='--scope global' ;;
    "source "*) GLOBAL_FORM="" ;;
    *) GLOBAL_FORM='--scope global (or --global)' ;;
  esac
  # Three verbs write a whole scope and take `--project-path PATH`; the rest
  # have no such flag, so offering it to them would name a command kendex
  # itself refuses.
  case "$1" in
    refresh | apply | updates) TARGET_FORM="--project-path PATH" ;;
    *) TARGET_FORM="--project-path PATH on refresh, apply or updates --apply; $1 has no such form" ;;
  esac
}
# Every line this hook writes, and the only place its text lives. The first
# line is the contract a reader parses, `block-worktree-refresh: <key>=<value>`:
# a stable key for the condition and the value acted on — the missing tool, why
# the payload could not be read, the verb refused, or git's exit status. The
# English explanation and the two forms that are right follow on later lines.
# The keyed line stands first, at position 1. What a command this hook runs
# wrote is captured where the hook reads it and passed here as the cause, so
# it is replayed under the key rather than ahead of it.
refuse() { # KEY VALUE [CAUSE]
  printf 'block-worktree-refresh: %s=%s\n' "$1" "$2" >&2
  case "$1=$2" in
    missing-tools=*)
      echo "the commands ${2//,/, } are required to read the hook payload and the worktree and are not on PATH; refusing rather than skipping the guard" >&2
      ;;
    missing-library=*)
      echo "the commit-guards skill's $2 is not installed beside this hook, and it is what reads the command; install the commit-guards skill in this scope. Refusing rather than skipping the guard" >&2
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
      forms "$VERB"
      echo "refusing 'kendex $VERB' at project scope after a cd or pushd in the same command: the directory the write lands in cannot be established from the command's words." >&2
      echo "  Name the project in the command instead: $TARGET_FORM. Or run kendex as its own command from the project it writes${GLOBAL_FORM:+, or pass $GLOBAL_FORM for a global change}." >&2
      ;;
    refused=*)
      forms "$VERB"
      echo "refusing 'kendex $VERB' at project scope from the linked worktree $CWD." >&2
      case "$OWNER:$VERB" in
        worktree:update-pi)
          echo "  update-pi writes the Pi package roots directly and has no --project-path form, so it is not run from a linked worktree, whose own kendex.toml at $TOP does not decide where it writes." >&2
          echo "  Run it from the main checkout (the first line of 'git worktree list'), or pass $GLOBAL_FORM for a global change." >&2
          ;;
        worktree:*)
          echo "  This worktree is its own project, with its own kendex.toml at $TOP, and 'kendex $VERB' writes a whole project scope only where the command names it." >&2
          echo "  Name it in the command: kendex $VERB --project-path $TOP, quoted as the shell needs, or pass $GLOBAL_FORM for a global change." >&2
          ;;
        main:*)
          echo "  This worktree has no kendex.toml at $TOP, so its project is the main checkout's (the first line of 'git worktree list'); a project-scope write from here renders into that checkout and removes what it does not expect there." >&2
          echo "  Name the project in the command instead: $TARGET_FORM. Or run the same command from the main checkout${GLOBAL_FORM:+, or pass $GLOBAL_FORM for a global change}. Reads (kendex verify, check, list) are not refused." >&2
          ;;
      esac
      ;;
    git=unreadable)
      echo "$AT/.git exists but git could not read a repository there, so whether $CWD is a linked worktree is unknown and the write is refused" >&2
      ;;
    git=unresolvable)
      echo "the git directories git named under $CWD could not be entered, so the write is refused" >&2
      ;;
    git=*)
      echo "git could not say whether $CWD is a linked worktree, or which worktree it is, so the write is refused:" >&2
      printf '%s\n' "$REASON" >&2
      ;;
  esac
  # The cause a command this hook ran wrote, captured at the site and replayed
  # here: under the keyed line, never ahead of it.
  [ -z "${3:-}" ] || printf '%s\n' "$3" >&2
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

# The command reader is commit-guards' command-position library. A catalog hook
# ships as one file, so the library comes from this hook's own install, never
# from whichever repository the session has open, by the walk
# hooks/lane-mail-check.sh owns for its reader: from the hook's physical
# directory up five levels, stopping at the open repository's root and after
# the home directory, where Pi's global hook sits four levels down, each
# level's `skills/` and shared `.agents/skills/` tree; then the home's shared
# tree, for a harness root CODEX_HOME, PI_CODING_AGENT_DIR or COPILOT_HOME moved
# out of the home; then the repository's own copy, only where this hook is
# installed in that repository. Without it no command can be read, and the
# call is refused.
LIBRARY=commit-guards/scripts/lib/command-position.sh
HOOK_DIR=${BASH_SOURCE[0]%/*}
[ "$HOOK_DIR" != "${BASH_SOURCE[0]}" ] || HOOK_DIR=.
HOOK_DIR=$(cd -P -- "$HOOK_DIR" 2>/dev/null && pwd -P) || HOOK_DIR=""
HOME_DIR=$(cd -P -- "${HOME:-/}" 2>/dev/null && pwd -P) || HOME_DIR=""
ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || ROOT=""
FOUND_LIBRARY=""
AT=$HOOK_DIR
LEVELS=0
while [ -n "$AT" ] && [ "$LEVELS" -lt 5 ] && [ "$AT" != "$ROOT" ] && [ "$AT" != / ]; do
  for candidate in "$AT/skills/$LIBRARY" "$AT/.agents/skills/$LIBRARY"; do
    if [ -f "$candidate" ]; then
      FOUND_LIBRARY=$candidate
      break
    fi
  done
  { [ -z "$FOUND_LIBRARY" ] && [ "$AT" != "$HOME_DIR" ]; } || break
  AT=${AT%/*}
  [ -n "$AT" ] || AT=/
  LEVELS=$((LEVELS + 1))
done
if [ -z "$FOUND_LIBRARY" ] && [ -n "$HOME_DIR" ] && [ "$HOME_DIR" != "$ROOT" ] \
  && [ -f "$HOME_DIR/.agents/skills/$LIBRARY" ]; then
  FOUND_LIBRARY="$HOME_DIR/.agents/skills/$LIBRARY"
fi
if [ -z "$FOUND_LIBRARY" ] && [ -n "$ROOT" ] && [ -f "$ROOT/.agents/skills/$LIBRARY" ]; then
  case "$HOOK_DIR" in
    "$ROOT"/*) FOUND_LIBRARY="$ROOT/.agents/skills/$LIBRARY" ;;
  esac
fi
[ -n "$FOUND_LIBRARY" ] || refuse missing-library "$LIBRARY"
# shellcheck source=../skills/commit-guards/scripts/lib/command-position.sh
source "$FOUND_LIBRARY"

# cat's words are captured, not left to precede the refusal: on failure the
# substitution holds what it wrote, and the refusal replays it under the keyed
# line. A cat that succeeds is silent, so the payload is not mixed with a
# diagnostic on the passing side.
INPUT=$(cat 2>&1) || refuse payload unreadable "$INPUT"
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

# The verb as a word after a `kendex` word, judged one segment at a time over
# the text the shell would run: `command_segments` cuts the command into
# segments and masks what the shell would not run. A read-only option exempts
# the write only when its tail has no `<`, `>`, backslash, single quote or
# double quote. This keeps the whitespace pattern from reading inside an
# escaped or quoted word. The global scope is not this hook's, and `-g`,
# `--global` or `--scope global` exempts a write only when it reaches kendex
# as an argument of the verb's own segment and no `--scope project` or
# `--scope all` does too, because kendex gives `--scope` precedence over
# `--global`; read across the whole command the word would let
# `kendex refresh -g && kendex refresh` through on the first command's word.
# `kendex updates` is a write only with `--apply`, which delegates to refresh.
# The bare `kendex <source>` shorthand for add is not read: matching it means
# matching every `kendex <word>`, reads included, and that is the whole CLI.
command_segments "$COMMAND"
READ_ONLY_RE='(^|[[:space:]])(--help|--plan)([[:space:]]|$)'
CHECK_RE='(^|[[:space:]])(--check|-c)([[:space:]]|$)'
# A `cd` or `pushd` word in the verb's segment or an earlier one moves the
# shell before kendex runs, so the directory git is asked about below is not
# the one the write lands in; such a command is refused whatever that
# directory says, since the effective one cannot be established from words.
MOVE_RE='(^|[^[:alnum:]_.-])(cd|pushd)([[:space:]]|$)'
KENDEX_RE='(^|[^[:alnum:]_.-])kendex["'"'"']?([[:space:]]|$)'

# The writing verb of one segment, and the text after it. A quote may close
# the command word or wrap the verb, as in `"/path/kendex" refresh` and
# `kendex 'refresh'`, and any words may stand between them, as in
# `kendex --global refresh` or `kendex --harness claude refresh`. Those root
# options and their values are dropped by the CLI once a subcommand follows,
# so only the words AFTER the verb are read for its options. The verb is the
# first word that names one, and `source` and `marketplace` name one only
# with their writing subcommand as the next word: a later word is an
# argument, such as a skill named `refresh` in `kendex add x --skill refresh`.
# The verbs are every shipped command that writes a scope: the item verbs,
# `updates --apply`, `pin`, `fork`, `adopt`, `drift-hook`, and the writing
# subcommands of `source` and `marketplace`. FOUND is empty where the segment
# names none; TAIL keeps a leading space so a word at its start has an edge.
writing_verb() { # SEGMENT -> FOUND, TAIL
  local rest word group=""
  FOUND=""
  TAIL=""
  [[ $1 =~ $KENDEX_RE ]] || return 0
  rest=${1#*"${BASH_REMATCH[0]}"}
  while :; do
    rest=${rest#"${rest%%[![:space:]]*}"}
    [ -n "$rest" ] || return 0
    word=${rest%%[[:space:]]*}
    rest=${rest#"$word"}
    word=${word#[\"\']}
    word=${word%[\"\']}
    case "$group:$word" in
      :refresh | :apply | :add | :remove | :update-pi | :updates | :pin | :fork | :adopt | :drift-hook)
        FOUND=$word
        ;;
      source:add | source:remove | source:enable | source:disable | marketplace:subscribe | marketplace:unsubscribe)
        FOUND="$group $word"
        ;;
      *:source | *:marketplace)
        group=$word
        continue
        ;;
      *)
        group=""
        continue
        ;;
    esac
    TAIL=" $rest"
    return 0
  done
}

# The options kendex reads after the verb, taken from the words Bash passes
# it rather than from the text. A redirection operator and the file it opens
# are the shell's, never an argument, whether the file is glued to the
# operator (`>--global`), quoted (`> "--global"`) or its own word, and a real
# option stays one on either side of a redirection. A standalone `--` ends
# the options, so no word after it is one. Each word is read in order,
# because the one before it decides whether it is the value of `--scope` or
# `--project-path`.
#
# A word whose value the shell settles only when it runs — an expansion, a
# glob, a brace, or a backslash, which can also join it to the next word —
# may be any word at all, `--` and `--scope=project` included, so it grants
# nothing: the scope is then the project scope, `--apply` counts as present,
# and a `--project-path` after it is not read as a target, since the word
# before could have ended the options. A quote is removed as the shell
# removes it.
#
# ARG_SCOPE is `unnamed`, `global` or `project`: kendex gives `--scope`
# precedence over `-g` and `--global`, so a `--scope` whose value is not the
# plain word `global` is the project scope whatever stands beside it.
# ARG_TARGET and ARG_APPLY are 1 where a real `--project-path` or `--apply`
# reaches kendex. The value `--project-path` names is not read: kendex
# refuses the flag without one.
read_options() { # TAIL -> ARG_SCOPE, ARG_TARGET, ARG_APPLY
  local rest=$1 word next head value="" operand="" unsure=""
  ARG_SCOPE=unnamed
  ARG_TARGET=""
  ARG_APPLY=""
  while :; do
    rest=${rest#"${rest%%[![:space:]]*}"}
    [ -n "$rest" ] || break
    word=${rest%%[[:space:]]*}
    rest=${rest#"$word"}
    # A backslash before a blank makes the blank part of the word.
    while [[ $word == *\\ ]] && [ -n "$rest" ]; do
      word=$word${rest:0:1}
      rest=${rest:1}
      next=${rest%%[[:space:]]*}
      word=$word$next
      rest=${rest#"$next"}
    done
    if [ -n "$operand" ]; then
      operand=""
      continue
    fi
    # A `<` or `>` outside a quote starts a redirection: `<` inside a quoted
    # span was masked by the command reader, and a `>` behind a quote in
    # the word may be inside one, which leaves the word unsure. What stands
    # before the operator is an argument unless it is empty or the digits
    # of a file descriptor; the file follows the operator in the same word
    # or, where the word ends there, is the next word.
    case "$word" in
      *[\<\>]*)
        head=${word%%[<>]*}
        next=${word#"$head"}
        next=${next#"${next%%[!<>]*}"}
        [ -n "$next" ] || operand=1
        case "$head" in
          *[\"\']*)
            unsure=1
            continue
            ;;
          "") continue ;;
          *[!0-9]*) word=$head ;;
          *) continue ;;
        esac
        ;;
    esac
    case "$word" in
      *[\$\\*?[{}]*)
        unsure=1
        value=""
        continue
        ;;
    esac
    word=${word//[\"\']/}
    case "$value:$word" in
      scope:global) [ "$ARG_SCOPE" = project ] || ARG_SCOPE=global ;;
      scope:*) ARG_SCOPE=project ;;
      target:*) ;;
      :--) break ;;
      :-g | :--global) [ "$ARG_SCOPE" = project ] || ARG_SCOPE=global ;;
      :--scope) value=scope; continue ;;
      :--scope=global) [ "$ARG_SCOPE" = project ] || ARG_SCOPE=global ;;
      :--scope=*) ARG_SCOPE=project ;;
      :--project-path | :--project-path=*)
        [ -n "$unsure" ] || ARG_TARGET=1
        [ "$word" != --project-path ] || { value=target; continue; }
        ;;
      :--apply) ARG_APPLY=1 ;;
    esac
    value=""
  done
  # A `--scope` whose value the segment does not hold is one whose value is
  # not known here: the command reader cuts a quoted span after a word ending
  # in `sh`, `refresh` among them, into a segment of its own.
  if [ -n "$unsure" ] || [ "$value" = scope ]; then
    ARG_SCOPE=project
    ARG_APPLY=1
  fi
}

# Every project-scope write the command makes, one verb per line, in order.
# A write after a `cd` or `pushd` is refused here, before git is asked
# anything.
WRITES=""
MOVED=""
while IFS= read -r SEGMENT; do
  [[ $SEGMENT =~ $MOVE_RE ]] && MOVED=1
  writing_verb "$SEGMENT"
  [ -n "$FOUND" ] || continue
  if [[ $TAIL != *'<'* && $TAIL != *'>'* && $TAIL != *\\* && $TAIL != *"'"* && $TAIL != *'"'* && $TAIL =~ $READ_ONLY_RE ]]; then
    continue
  fi
  # `update-pi --check` previews and writes nothing.
  if [ "$FOUND" = update-pi ] && [[ $TAIL =~ $CHECK_RE ]]; then
    continue
  fi
  read_options "$TAIL"
  if [ "$FOUND" = updates ] && [ -z "$ARG_APPLY" ]; then
    continue
  fi
  # `--project-path PATH` names the checkout the write lands in. This guard
  # exists because that directory could not be read from the command; named
  # there, it can, and the write goes to the project the words carry however
  # the shell moved. Only `refresh`, `apply` and `updates --apply` take the
  # flag; every other writing verb has no such form and stays refused.
  case "$FOUND" in
    refresh | apply | updates)
      [ -z "$ARG_TARGET" ] || continue
      ;;
  esac
  [ "$ARG_SCOPE" != global ] || continue
  if [ -n "$MOVED" ]; then
    VERB=$FOUND
    refuse moved "$VERB"
  fi
  WRITES=$WRITES$FOUND$NL
done <<EOF
$SEGMENTS
EOF
if [ -z "$WRITES" ]; then
  exit 0
fi

# The tool call's directory wins over the session directory: Codex sends
# `tool_input.workdir`, other harnesses can send `tool_input.cwd`, and the
# payload `cwd` remains the fallback. A carrier with none uses the directory
# where the hook runs.
# The assignment stands inside the condition: bare, its own status would end
# the script under errexit and the empty-cwd test below would never run.
if ! CWD=$(printf '%s' "$INPUT" \
  | jq -r 'if .tool_input.workdir != null then .tool_input.workdir
           elif .tool_input.cwd != null then .tool_input.cwd
           elif .cwd != null then .cwd
           else "" end
           | if type == "string" then . else error end' 2>/dev/null); then
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
# cd's own words come back in place of the path when it cannot enter one, so
# the caller has the cause to replay under its keyed line rather than leaving
# cd to write ahead of it.
resolve() { # PATH -> physical path, or cd's words on failure
  case "$1" in
    /*) (cd -- "$1" 2>&1 && pwd -P) ;;
    *) (cd -- "$CWD/$1" 2>&1 && pwd -P) ;;
  esac
}
if ! GIT_DIR=$(resolve "$GIT_DIR_LINE"); then
  refuse git unresolvable "$GIT_DIR"
elif ! COMMON_DIR=$(resolve "$COMMON_DIR_LINE"); then
  refuse git unresolvable "$COMMON_DIR"
fi
if [ "$GIT_DIR" = "$COMMON_DIR" ]; then
  exit 0
fi

# Whose project a bare verb typed here writes. A worktree whose root carries
# a kendex.toml of its own is a project in its own right, and the CLI
# resolves the current project from the directory it runs in, so the verbs
# that write one project by being typed inside it write this worktree's.
# The file is not read: one that will not parse is still this worktree's,
# and kendex reports it before it writes. A worktree with none checks out
# the main checkout's declarations, which the refusal points at. The main
# checkout is not derived from the common dir, which a repository made with
# --separate-git-dir keeps outside its checkout; `git worktree list` names
# the checkout first.
if ! TOP=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null); then
  TOP_STATUS=0
  REASON=$(git -C "$CWD" rev-parse --show-toplevel 2>&1 >/dev/null) || TOP_STATUS=$?
  refuse git "$TOP_STATUS"
fi
if [ -e "$TOP/kendex.toml" ] || [ -L "$TOP/kendex.toml" ]; then
  OWNER=worktree
else
  OWNER=main
fi
# `refresh`, `apply` and `updates --apply` write a whole scope and keep to
# the named target in every worktree; `update-pi` writes the Pi package
# roots directly and is not judged by the worktree's manifest.
while IFS= read -r VERB; do
  case "$OWNER:$VERB" in
    worktree:add | worktree:remove | worktree:fork | worktree:pin | worktree:adopt | worktree:drift-hook) ;;
    "worktree:source "* | "worktree:marketplace "*) ;;
    *:?*) refuse refused "$VERB" ;;
    *:) ;;
  esac
done <<EOF
$WRITES
EOF
