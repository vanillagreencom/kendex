#!/usr/bin/env bash
# ---
# name: block-worktree-refresh
# event: PreToolUse
# matcher: Bash
# description: Refuse a `kendex` command that writes the project scope (`refresh`, `apply`, `add`, `remove`, `update-pi`, `updates --apply`, `pin`, `fork`, `adopt`, `drift-hook`, `source add|remove|enable|disable`, `marketplace subscribe|unsubscribe`) when the working directory is a linked git worktree and the command does not name the global scope, and whenever a `cd` or `pushd` stands before the verb in the same command, since the directory the write lands in cannot then be read from the command. A project's kendex install is registered to the main checkout, so a project-scope write from a linked worktree renders into that checkout and removes what it does not expect there. Names the two forms that are right: the same command from the main checkout, or the verb's global form (`--global` for add, `--scope global` for update-pi, either for the rest).
# summary: Stops a kendex command that writes a project from inside a linked git worktree, where the write would land somewhere the command does not name.
# safety: Reads the command text and asks git whether the working directory's git dir differs from its common dir, which is what makes a worktree linked; writes nothing. A git that cannot answer refuses. The verb is read as a word after a `kendex` word, anywhere in the command except the text the shell would not run: the words inside a quoted span, a heredoc body its command reads as data, and a comment are masked out before the command is read, so prose spelling the pair is not refused, while a span or a heredoc body that a shell, `eval`, `source` or `.` word runs is read as the command it is; a quote that cannot be paired leaves the whole text to be read, so a command this hook could not take apart is refused rather than passed. The bare `kendex <source>` shorthand for add is not read, since matching it would match every read too. `kendex verify`, `check`, `list`, `report` and every other verb pass; a command carrying `-g`, `--global` or `--scope global` in the verb's own segment, with no `--scope project` or `--scope all` beside it, passes because it names the scope this hook does not guard. A payload that cannot be read, an empty one included, is refused, never skipped. Every refusal opens with `block-worktree-refresh: <key>=<value>`; what a command this hook runs writes is captured at the site and replayed under that line, so nothing precedes the key.
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
# The keyed line stands first, at position 1. What a command this hook runs
# wrote is captured where the hook reads it and passed here as the cause, so
# it is replayed under the key rather than ahead of it.
refuse() { # KEY VALUE [CAUSE]
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

# The verb as a word after a `kendex` word, judged one segment at a time: a
# segment is the text between two of `;`, `&`, `|`, `(`, `)`, `` ` `` and a
# line end, with a backslash-newline continuing it, and it ends at a `#` that
# begins a word, since the shell drops the comment behind it. What the shell
# would not run as a command is masked out of the text before the segments are
# cut, and the patterns then read everything left. The global scope is not
# this hook's, and `-g`, `--global` or `--scope global` exempts a write only
# when it stands in the verb's own segment and no `--scope project` or
# `--scope all` stands there too, because kendex gives `--scope` precedence
# over `--global`; read across the whole command the word would let
# `kendex refresh -g && kendex refresh` through on the first command's word.
# `kendex updates` is a write only with `--apply`, which delegates to refresh.
# The bare `kendex <source>` shorthand for add is not read: matching it means
# matching every `kendex <word>`, reads included, and that is the whole CLI.
NL=$'\n'
MASK=$'\001'
JOINED=${COMMAND//\\$NL/ }
# A `#` that begins a word ends the line, since the shell drops the comment
# behind it. The heredoc pass and the segment loop below read a line through
# this, so the comment is dropped once and in one place. The result lands in
# BARE rather than on stdout: a command substitution under errexit would end
# the script on its own status before the caller could test the result.
# A `#` begins a comment wherever it begins a word, which is the start of the
# line, the point after a blank, and the point after an unquoted `&`, `;`, `|`,
# a parenthesis or a backtick, since each of those ends the word before it. The
# blank and the metacharacters stand in one bracket expression so the cut lands
# on the earliest of them, not on whichever pattern a case statement reaches
# first.
uncommented() { # LINE -> BARE, the line without its comment
  case "$1" in
    \#*) BARE="" ;;
    *[[:blank:]\&\;\|\(\)\`]\#*) BARE=${1%%[[:blank:]\&\;\|\(\)\`]\#*} ;;
    *) BARE=$1 ;;
  esac
}
# The one test of whether text the shell reads out of a quoted span or out of a
# heredoc body is a command: a word before it in the same segment runs shell
# text. That is a word whose basename ends in `sh` (`sh`, `bash`, `zsh`,
# `dash`, `ksh`), or the word `eval`, `source` or `.`. It also reads an English
# word ending in `sh`, such as `push`, as one; that refuses a command rather
# than passing it, which is the direction this hook fails in.
SHELL_RE='(^|[[:space:]])([^[:space:]]*/)?([^[:space:]/]*sh|eval|source|\.)([[:space:]]|$)'
# A word standing immediately after a redirection operator is a file the shell
# opens, never the command it runs, so `cat > script.sh` names no shell. The
# operator takes an optional file descriptor digit in front of it.
REDIRECT_RE='[0-9]?(>>|>|<)[[:blank:]]*[^[:space:]]+'
# The quotes come off the text first: a command word may be quoted whole, as in
# `"/bin/bash" -c ...`, and a quoted word ends in the quote character, so the
# basename would never read as a shell. The redirection targets go next, since
# a target named for a script would otherwise read as the interpreter of one.
runs_shell_text() { # TEXT -> 0 when a word in it runs shell text
  local bare=${1//[\'\"]/}
  while [[ $bare =~ $REDIRECT_RE ]]; do
    bare=${bare/"${BASH_REMATCH[0]}"/ }
  done
  [[ $bare =~ $SHELL_RE ]]
}
# A `<<` or `<<-` with only blanks after it takes the next span as its heredoc
# delimiter, a word the shell does not run. `<<<` is a here-string, and the
# word after it is one the shell does run.
DELIM_TAIL_RE='(^|[^<])<<-?[[:space:]]*$'
# The first character of CHARS that the shell reads as a boundary rather than
# as itself: one carrying an odd number of backslashes in front of it is a
# literal character the shell hands on as an argument, so it opens and closes
# nothing. Two of those pairing with each other is what would hide the command
# between them. UPTO holds the text before the boundary; a status of 1 says the
# text holds no boundary at all.
upto_unescaped() { # TEXT CHARS -> 0 with UPTO set, 1 when every one is escaped
  local rest=$1 chars=$2 piece slashes
  UPTO=""
  while :; do
    case "$rest" in
      *[$chars]*) ;;
      *) return 1 ;;
    esac
    piece=${rest%%[$chars]*}
    rest=${rest#"$piece"}
    slashes=${piece##*[!\\]}
    if [ $((${#slashes} % 2)) -eq 0 ]; then
      UPTO=$UPTO$piece
      return 0
    fi
    UPTO=$UPTO$piece${rest:0:1}
    rest=${rest:1}
  done
}
# A command substitution is command text wherever it stands: the shell expands
# and runs it before the command around it reads anything, so one inside a
# double-quoted argument or inside a heredoc body the shell expands runs just
# the same. SUBS holds each one's text, opened as its own command position with
# its whitespace intact; OUTSIDE holds what is left for the caller to mask or
# to drop. A substitution that does not close is text the judge could not read,
# and the caller is told, as it is for a quote that does not pair.
lift_substitutions() { # TEXT -> 0 with SUBS and OUTSIDE set, 1 when one does not close
  local rest=$1 head open body depth piece
  SUBS=""
  OUTSIDE=""
  while :; do
    upto_unescaped "$rest" '$`' || { OUTSIDE=$OUTSIDE$rest; return 0; }
    head=$UPTO
    rest=${rest#"$head"}
    open=${rest:0:1}
    OUTSIDE=$OUTSIDE$head
    # A `$` that no `(` follows names a parameter, which the shell expands
    # without running anything.
    if [ "$open" = '$' ] && [ "${rest:1:1}" != '(' ]; then
      OUTSIDE=$OUTSIDE$open
      rest=${rest:1}
      continue
    fi
    if [ "$open" = '`' ]; then
      rest=${rest:1}
      upto_unescaped "$rest" '`' || return 1
      body=$UPTO
      rest=${rest#"$body"}
      rest=${rest:1}
    else
      # The parentheses are counted, so a substitution holding another one
      # closes where it really closes.
      rest=${rest:2}
      depth=1
      body=""
      while :; do
        upto_unescaped "$rest" '()' || return 1
        piece=$UPTO
        rest=${rest#"$piece"}
        if [ "${rest:0:1}" = ')' ]; then
          depth=$((depth - 1))
          if [ "$depth" -eq 0 ]; then
            body=$body$piece
            rest=${rest:1}
            break
          fi
        else
          depth=$((depth + 1))
        fi
        body=$body$piece${rest:0:1}
        rest=${rest:1}
      done
    fi
    SUBS=$SUBS$NL$body$NL
  done
}
# The separator characters. A bracket expression's members carry no order, and
# the ampersand stands before the semicolon here so the two do not spell the
# Bash 4 case terminator that tools/bash32-lint reads.
SEP='[&;|()`'$NL']'
# The one judge of what the shell would not run, masking only that and leaving
# the patterns their whole-text reach over everything else, so there is no list
# of words that may precede a command to be incomplete.
#
# Each quoted span keeps its quotes, since a command word may be quoted whole
# (`"/path/kendex" refresh`), while the whitespace and the `<` inside it are
# masked: that is what keeps the span from reading as a command, keeps a word
# inside it from reaching a verb, and keeps a `<<` written inside it from
# arming a heredoc. A span the shell does run — the argument of a shell,
# `eval`, `source` or `.` word in the same segment — is opened as its own
# command position with its whitespace intact. A quote the shell hands on as a
# literal argument is not a boundary and opens no span, which is what keeps two
# escaped quotes from pairing around a real command. MASKED holds the result; a
# quote that still does not pair is a span the judge could not read, and the
# caller is told.
mask_spans() { # TEXT -> 0 with MASKED set, 1 when a quote does not pair
  local rest=$1 head quote span before out=""
  while :; do
    upto_unescaped "$rest" "'\"" || { MASKED=$out$rest; return 0; }
    head=$UPTO
    rest=${rest#"$head"}
    quote=${rest:0:1}
    rest=${rest:1}
    # A backslash inside a single-quoted span is a plain character, so only a
    # double-quoted span's closing quote can be escaped.
    if [ "$quote" = "'" ]; then
      case "$rest" in
        *\'*) span=${rest%%\'*} ;;
        *) return 1 ;;
      esac
    else
      upto_unescaped "$rest" '"' || return 1
      span=$UPTO
    fi
    rest=${rest#"$span$quote"}
    out=$out$head
    before=${out##*$SEP}
    if [[ $before =~ $DELIM_TAIL_RE ]] || ! runs_shell_text "$before"; then
      # A single-quoted span expands nothing, so all of it is masked; a
      # double-quoted one has its substitutions lifted out first.
      if [ "$quote" = "'" ]; then
        out=$out$quote${span//[[:space:]<]/$MASK}$quote
      else
        lift_substitutions "$span" || return 1
        out=$out$quote${OUTSIDE//[[:space:]<]/$MASK}$quote$SUBS
      fi
    else
      out=$out$NL$span$NL
    fi
  done
}
# The heredoc bodies. The shell feeds a body to a command rather than running
# it, so the body goes, unless that command is one that runs shell text and the
# body is the command text it runs. The `<<` is read off the line with its
# comment dropped and its quoted spans masked, so a `<<` only written down does
# not arm one. A body is dropped only once its terminator line is found: an
# unterminated body is text the judge could not read, and dropping it would
# take the rest of the command with it.
LINES=()
while IFS= read -r LINE; do
  LINES[${#LINES[@]}]=$LINE
done <<EOF
$JOINED
EOF
JUDGED=""
INDEX=0
COUNT=${#LINES[@]}
while [ "$INDEX" -lt "$COUNT" ]; do
  LINE=${LINES[$INDEX]}
  JUDGED=$JUDGED$LINE$NL
  INDEX=$((INDEX + 1))
  uncommented "$LINE"
  if mask_spans "$BARE"; then
    BARE=$MASKED
  fi
  [[ $BARE =~ (^|[^<])\<\<-?[[:space:]]*([^[:space:]\<][^[:space:]]*) ]] || continue
  DELIM=${BASH_REMATCH[2]}
  # `<<'EOF'` and `<<"EOF"` name the same delimiter as `<<EOF`, but a quoted
  # delimiter stops the shell expanding the body, so nothing in that body runs.
  EXPANDS=1
  case "$DELIM" in
    \'*\' | \"*\") DELIM=${DELIM:1:${#DELIM} - 2}; EXPANDS="" ;;
  esac
  END=$INDEX
  while [ "$END" -lt "$COUNT" ]; do
    TERM=${LINES[$END]}
    [ "${TERM#"${TERM%%[![:space:]]*}"}" = "$DELIM" ] && break
    END=$((END + 1))
  done
  [ "$END" -lt "$COUNT" ] || continue
  if runs_shell_text "$BARE"; then
    while [ "$INDEX" -lt "$END" ]; do
      JUDGED=$JUDGED${LINES[$INDEX]}$NL
      INDEX=$((INDEX + 1))
    done
  elif [ -n "$EXPANDS" ]; then
    # The body itself is data, but the shell expands it before the command
    # reads it, so a command substitution inside it runs. A line holding one
    # the judge cannot close is kept whole rather than dropped.
    while [ "$INDEX" -lt "$END" ]; do
      if lift_substitutions "${LINES[$INDEX]}"; then
        JUDGED=$JUDGED$SUBS
      else
        JUDGED=$JUDGED${LINES[$INDEX]}$NL
      fi
      INDEX=$((INDEX + 1))
    done
  fi
  INDEX=$((END + 1))
done
# A quote the judge could not pair leaves the original text to be judged whole,
# the reach the patterns had before any span was read: a command that could not
# be read is refused, never passed.
if mask_spans "$JUDGED"; then
  SEGMENTS=$MASKED
else
  SEGMENTS=$JOINED
fi
SEGMENTS=${SEGMENTS//;/$NL}
SEGMENTS=${SEGMENTS//&/$NL}
SEGMENTS=${SEGMENTS//\|/$NL}
SEGMENTS=${SEGMENTS//\(/$NL}
SEGMENTS=${SEGMENTS//\)/$NL}
SEGMENTS=${SEGMENTS//\`/$NL}
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
  uncommented "$SEGMENT"
  SEGMENT=$BARE
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

# The main checkout is not derived from the common dir, which a repository
# made with --separate-git-dir keeps outside its checkout; `git worktree list`
# names the checkout first.
refuse refused "$VERB"
