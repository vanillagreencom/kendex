#!/usr/bin/env bash
# ---
# name: reviewer-read-only
# event: PreToolUse
# matcher: Edit|MultiEdit|NotebookEdit|Write|Bash
# description: For a subagent whose agent_type starts with `reviewer-`, refuses every Edit, MultiEdit and NotebookEdit call; a Write whose path lies inside a git work tree unless it is the review artifact, `<dir>/tmp/review-*.json`; and a Bash command that runs `git commit`, `push`, `checkout`, `restore`, `stash` (all subcommands), `clean`, `reset` or `switch` (options between `git` and the verb allowed), or `rm` (`git rm` too) on a path inside a git work tree: every `rm` word written without quote marks is judged wherever the call holds it, outside inert text, its operands the words after it to the end of its command, a relative operand judged against the directory the call starts in (the payload's `cwd`, or on Pi, whose payload carries none, the hook's own working directory; `git -C` moves it), whatever `cd` precedes it, since a failed `cd` leaves the shell there. Any other agent, and a payload naming no agent_type, passes. Under Pi the pi-hooks carrier sends as agent_type the agent name a Pi subagent process is started with. Not run on codex: a write is `apply_patch` with no `tool_input.file_path`, so the review artifact cannot be told from any other write (Codex hooks reference, CLI 0.160.0). Not run on gemini: its tool-call payload is unmeasured. Not run on copilot: its preToolUse payload names no calling agent, only the caller's own session, and its subagentStart names the lead's session and no subagent id, so a reviewer's tool call cannot be joined to the reviewer (Copilot hooks reference, CLI 1.0.91). Not run on antigravity: its payload carries no agent field.
# summary: Keeps a reviewer agent read-only: no edits, no commits, no pushes, no Git commands that discard work, no `rm` inside a work tree, only its review report.
# safety: Reads the payload and asks git whether a path is inside a work tree; writes nothing. The Git verb checks match raw command text, including quoted mentions, and refuse every stash command. The delete check reads the command once, in time linear in its length, with no size limit. It judges every `rm` word with no quote marks, `\rm` and `/bin/rm` included, as a command, an argument of a launcher such as `sudo`, `env`, `xargs`, `timeout` or `find -exec`, or inside a `$(...)`, backtick or `<(...)` substitution, which runs wherever it stands, double quotes and an unquoted heredoc body included. Each word after it to the end of its command is an operand; an operand holding a `$` or backtick expansion names nothing before the shell runs and is not judged, and a non-path operand such as find's `{}` is judged as a path in the directory the call starts in. Inert text is not judged: a single-quoted or `$'...'` string, the body of `bash -c '...'` alike, double-quoted text outside a substitution, a heredoc body under a quoted delimiter, a comment, and the arguments of `grep`, `egrep`, `fgrep`, `rg`, `cat`, `echo`, `printf`, `git log`, `git grep` and `git show`. Not judged: `find -delete`, `mv`, an `rm` whose operands come from input, as `xargs rm`, and a delete inside a script. Missing tools, unreadable payload or an unreadable Git path check produce one keyed warning and allow the call. The refusal names the artifact path a reviewer may write, or for a delete the routes that clear it: quote an `rm` that is text, delete scratch in a `mktemp -d` of its own, and leave a probe it made in a work tree, named in its report; it never suggests bypassing. Every refusal opens with `reviewer-read-only: <key>=<value>`; what a command this hook runs writes is captured at the site and replayed under that line, so nothing precedes the key.
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
        echo "a reviewer deletes nothing inside a work tree; $2 is in one, and a delete there can take its author's uncommitted work. Quote an rm that is a search pattern or text, as 'rm'. A control file goes under a mktemp -d of your own and is deleted there, named by its absolute path. A probe you made in a work tree stays: leave it and name it in your report."
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

# The delete check. It reads the command once, from the stream on fd 3, a
# byte at a time and a quoted span, a comment or a quoted-delimiter heredoc
# line in one read, so its time grows with the command's length alone.
# Every rm word written without quote marks is judged wherever it stands: a
# command, a launcher's or find's argument, inside a substitution alike. The
# words after it to the end of its command are its operands. Inert text runs
# nothing and is passed over: a single-quoted or $'...' string, double-quoted
# text, a quoted-delimiter heredoc body, a comment and the arguments of a
# text reader. A $(...), backtick or <(...) substitution runs wherever it
# appears, double quotes and an unquoted heredoc body included.
#
# The mode is where the next byte falls: u unquoted, d in double quotes, h an
# unquoted heredoc body, a arithmetic, p a ${...} expansion. A substitution,
# subshell or arithmetic opens a frame that holds what its closing returns
# to: the mode, the command and the word around it.
judge_deletes() {
  local c n back="" mode=u depth=0
  local word="" piece="" plen=0 kind=w have=0 quoted=0 literal=0
  local pos=0 git=0 inert=0 rm=0 ended=0 skip=0 await=0 tab=0 base=$CWD
  local docs=() lits=() tabs=() at=0 hl="" hlen=0 hbad=0 hlead=1
  local f_close=() f_mode=() f_state=() f_base=() f_word=()
  while :; do
    if [ -n "$back" ]; then
      c=$back back=""
    elif ! IFS= read -r -n 1 -d '' -u 3 c; then
      break
    fi
    # A plain byte of a word, the most common byte, is added here rather than
    # through add's call; the same 256-byte pieces.
    case $mode$c in
      [ud][A-Za-z0-9_./,:+=@%~-])
        piece=$piece$c have=1 plen=$((plen + 1))
        [ "$plen" -lt 256 ] || word=$word$piece piece="" plen=0
        ;;
      u?) lex_unquoted ;;
      d?) lex_double ;;
      h?) lex_heredoc ;;
      a?) lex_arithmetic ;;
      p?) lex_expansion ;;
    esac
  done
  word_end
}

# The next byte into n, consumed (getc) or left for the loop (peek).
getc() {
  if [ -n "$back" ]; then
    n=$back back=""
  elif ! IFS= read -r -n 1 -d '' -u 3 n; then
    n=""
  fi
}
peek() {
  getc
  back=$n
}

# A byte of the word being read. Pieces of 256 bytes join the word, so a long
# word costs its length and not its length squared.
add() {
  piece=$piece$1 have=1 plen=$((plen + 1))
  if [ "$plen" -ge 256 ]; then
    word=$word$piece piece="" plen=0
  fi
}

command_start() {
  pos=0 git=0 inert=0 rm=0 ended=0 skip=0 await=0 base=$CWD
}

separator() {
  word_end
  command_start
}

# Opens a frame: CLOSE is what ends it, MODE how its inside is read, as a
# fresh command.
push() { # CLOSE MODE
  f_close[depth]=$1 f_mode[depth]=$mode f_base[depth]=$base f_word[depth]=$word$piece
  f_state[depth]="$pos $git $inert $rm $ended $skip $await $tab $kind $have $quoted $literal"
  depth=$((depth + 1)) mode=$2
  word="" piece="" plen=0 kind=w have=0 quoted=0 literal=0
  command_start
}

pop() {
  word_end
  depth=$((depth - 1))
  mode=${f_mode[depth]} base=${f_base[depth]} word=${f_word[depth]} piece="" plen=0
  # shellcheck disable=SC2086 # the state is one word per field
  set -- ${f_state[depth]}
  pos=$1 git=$2 inert=$3 rm=$4 ended=$5 skip=$6 await=$7 tab=$8 kind=$9 have=${10} quoted=${11} literal=${12}
}

# After a `$`: a command substitution, arithmetic, `${`, a $'...' string, or
# a `$` of the word.
dollar() {
  peek
  case $n in
    '(')
      back=""
      in_word
      peek
      if [ "$n" = '(' ]; then
        back=""
        push '))' a
      else
        push ')' u
      fi
      ;;
    '{') back=""; in_word; push '}' p ;;
    "'")
      if [ "$mode" = u ]; then
        back="" quoted=1 have=1
        read_quoted ansi
      else
        word_dollar
      fi
      ;;
    *) word_dollar ;;
  esac
}

# An expansion makes the word it stands in name nothing before the shell
# runs. Only a word of the command is marked: in a heredoc body, arithmetic
# or `${...}` the `$` belongs to no word.
in_word() {
  case $mode in
    u | d) kind=x have=1 ;;
  esac
}
word_dollar() {
  case $mode in
    u | d) kind=x; add '$' ;;
  esac
}

# A single-quoted or $'...' string, read to its closing quote in one read. In
# $'...' a backslash escapes the quote after it, unless it is escaped itself.
read_quoted() { # plain | ansi
  local s t odd
  while :; do
    s=""
    if ! IFS= read -r -d "'" -u 3 s; then
      word=$word$piece$s piece="" plen=0
      return 0
    fi
    word=$word$piece$s piece="" plen=0
    [ "$1" = ansi ] || return 0
    t=$s odd=0
    while [[ $t == *\\ ]]; do
      t=${t%\\} odd=$((1 - odd))
    done
    [ "$odd" = 1 ] || return 0
    word=$word\'
  done
}

lex_unquoted() {
  case $c in
    ' ' | $'\t') word_end ;;
    $'\n') newline ;;
    ';') separator ;;
    '&')
      peek
      case $n in
        '>') back="" c='>'; redirect ;;
        '&') back=""; separator ;;
        *) separator ;;
      esac
      ;;
    '|')
      peek
      case $n in '|' | '&') back="" ;; esac
      separator
      ;;
    '(')
      word_end
      peek
      if [ "$n" = '(' ]; then
        back=""
        push '))' a
      else
        push ')' u
      fi
      ;;
    ')')
      if [ "$depth" -gt 0 ] && [ "${f_close[depth - 1]}" = ')' ]; then
        pop
      else
        separator
      fi
      ;;
    '`')
      if [ "$depth" -gt 0 ] && [ "${f_close[depth - 1]}" = '`' ]; then
        pop
      else
        kind=x have=1
        push '`' u
      fi
      ;;
    '<' | '>') redirect ;;
    "'") quoted=1 have=1; read_quoted plain ;;
    '"') quoted=1 have=1 mode=d ;;
    \\)
      getc
      if [ -n "$n" ] && [ "$n" != $'\n' ]; then
        literal=1
        add "$n"
      fi
      ;;
    '#')
      if [ "$have" = 1 ]; then
        add '#'
      else
        IFS= read -r -u 3 n || :
        newline
      fi
      ;;
    '$') dollar ;;
    *) add "$c" ;;
  esac
}

newline() {
  separator
  [ "$at" -ge "${#docs[@]}" ] || start_docs
}

# A redirection: its target is the next word and not an operand. A file
# descriptor number written against the operator is not a word. `<(` and
# `>(` run a command; `<<` awaits a heredoc delimiter.
redirect() {
  if [ "$have$quoted$literal$kind" = 100w ]; then
    case $word$piece in
      *[!0-9]*) ;;
      *) word="" piece="" plen=0 have=0 ;;
    esac
  fi
  word_end
  peek
  if [ "$n" = '(' ]; then
    back="" kind=x have=1
    push ')' u
    return 0
  fi
  if [ "$c$n" = '<<' ]; then
    back=""
    peek
    if [ "$n" = '<' ]; then
      back="" skip=1
      return 0
    fi
    tab=0
    if [ "$n" = - ]; then back="" tab=1; fi
    await=1
    return 0
  fi
  while :; do
    case $n in
      '<' | '>' | '&' | '|') back=""; peek ;;
      *) break ;;
    esac
  done
  skip=1
}

lex_double() {
  case $c in
    '"') mode=u ;;
    \\)
      getc
      [ "$n" = $'\n' ] || add "$n"
      ;;
    '$') dollar ;;
    '`') kind=x; push '`' u ;;
    *) add "$c" ;;
  esac
}

lex_arithmetic() {
  case $c in
    '(') push ')' a ;;
    ')')
      if [ "${f_close[depth - 1]}" = ')' ]; then
        pop
      else
        peek
        if [ "$n" = ')' ]; then
          back=""
          pop
        fi
      fi
      ;;
    '$') dollar ;;
    '`') push '`' u ;;
  esac
}

lex_expansion() {
  case $c in
    '}') pop ;;
    \\) getc ;;
    '$') dollar ;;
    '`') push '`' u ;;
  esac
}

# An unquoted heredoc body: inert but for its substitutions, each line held
# only as far as it could still be the delimiter.
lex_heredoc() {
  case $c in
    $'\n')
      if [ "$hbad" = 0 ] && [ "$hl" = "${docs[at]}" ]; then
        at=$((at + 1))
        start_docs
      else
        hl="" hlen=0 hbad=0 hlead=1
      fi
      ;;
    \\) getc; hbad=1 ;;
    '$' | '`')
      hbad=1
      if [ "$c" = '`' ]; then push '`' u; else dollar; fi
      ;;
    *)
      if [ "$hlead" = 1 ] && [ "$c" = $'\t' ] && [ "${tabs[at]}" = 1 ]; then
        return 0
      fi
      hlead=0
      if [ "$hbad" = 0 ]; then
        hl=$hl$c hlen=$((hlen + 1))
        [ "$hlen" -le "${#docs[at]}" ] || hbad=1
      fi
      ;;
  esac
}

# The heredocs opened on the line just ended, in order. A body under a quoted
# delimiter is read a line at a time and passed over; an unquoted one is read
# in mode h.
start_docs() {
  local line
  while [ "$at" -lt "${#docs[@]}" ]; do
    if [ "${lits[at]}" = 0 ]; then
      mode=h hl="" hlen=0 hbad=0 hlead=1
      return 0
    fi
    while IFS= read -r -u 3 line; do
      [ "${tabs[at]}" = 0 ] || line=${line#"${line%%[!$'\t']*}"}
      [ "$line" != "${docs[at]}" ] || break
    done
    at=$((at + 1))
  done
  docs=() lits=() tabs=() at=0 mode=u
}

# Ends the word being read and gives it its role in the command: a heredoc
# delimiter, a redirection target, an rm operand, the command word, a git
# option or verb, or an rm.
word_end() {
  if [ "$have" = 1 ]; then
    word=$word$piece
    if [ "$await" = 1 ]; then
      docs+=("$word") lits+=("$((quoted | literal))") tabs+=("$tab")
      await=0
    elif [ "$skip" = 1 ]; then
      skip=0
    elif [ "$rm" = 1 ]; then
      judge_operand
    elif [ "$pos" = 0 ]; then
      if ! [[ $word =~ ^[A-Za-z_][A-Za-z0-9_]*\+?= ]]; then
        pos=1
        case $word in
          grep | egrep | fgrep | rg | cat | echo | printf) inert=1 ;;
          git) git=1 ;;
          *) is_rm ;;
        esac
      fi
    elif [ "$inert" = 0 ]; then
      case $git in
        1)
          case $word in
            -C) git=2 ;;
            -c | --git-dir | --work-tree | --namespace | --exec-path) git=3 ;;
            -*) ;;
            log | grep | show) git=0 inert=1 ;;
            *) git=0; is_rm ;;
          esac
          ;;
        2)
          git=1
          case "$kind:$word" in
            x:*) base="" ;;
            w:/*) base=$word ;;
            *) base=$base/$word ;;
          esac
          ;;
        3) git=1 ;;
        *) is_rm ;;
      esac
    fi
  fi
  word="" piece="" plen=0 kind=w have=0 quoted=0 literal=0
}

# Whether the word just ended is an rm with no quote marks, named by any path.
is_rm() {
  if [ "$kind$quoted" = w0 ]; then
    case $word in
      rm | */rm) rm=1 ;;
    esac
  fi
}

# Refuses an rm operand inside a work tree. A relative operand lies under the
# directory the call starts in, whatever `cd` precedes it, since a failed `cd`
# leaves the shell there; `git -C` moves it. An operand holding an expansion
# names nothing before the shell runs and is not judged.
judge_operand() {
  local path=$word
  if [ "$ended" = 0 ]; then
    case $path in
      --) ended=1; return 0 ;;
      -*) return 0 ;;
    esac
  fi
  if [ "$kind" != w ] || [ -z "$base" ]; then return 0; fi
  case $path in
    '' | \~[!/]*) return 0 ;;
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
    # A delete inside a work tree can take uncommitted work with it. Only a
    # command that names rm can run one, so any other passes unsplit.
    case "$COMMAND" in
      *rm*) ;;
      *) exit 0 ;;
    esac
    CWD=$(printf '%s' "$INPUT" | jq -er '.cwd
      | if . == null then "" elif type == "string" then . else error("not a string") end' 2>/dev/null) ||
      refuse payload invalid-json
    # A harness whose payload names no cwd starts the hook where the call
    # runs: the Pi carrier spawns it in the session's directory.
    [ -n "$CWD" ] || CWD=$PWD
    # A refusal inside the pipeline exits it with 2, which errexit carries
    # out of the hook; the EXIT trap passes 2 through.
    printf '%s\n' "$COMMAND" | judge_deletes 3<&0 </dev/null
    exit 0
    ;;
esac

exit 0
