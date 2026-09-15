# shellcheck shell=bash
# The text of a shell command that the shell would run, cut into segments.
# Sourced by the catalog hooks that judge a command by what it runs rather than
# by what it spells: block-worktree-refresh and skill-load-check. Pure Bash, no
# external command, and sourcing it defines functions and constants only.
#
# `command_segments TEXT` leaves SEGMENTS holding one segment per line. A
# segment is the text between two of `;`, `&`, `|`, `(`, `)`, `` ` `` and a
# line end, with a backslash-newline continuing it, and without the comment a
# `#` beginning a word starts. What the shell would not run as a command is
# masked out before the cut: the whitespace and the `<` inside a quoted span
# become \001, so no word inside a span reaches a caller's pattern, and a
# heredoc body its command reads as data is dropped. A span or a body that a
# shell, `eval`, `source` or `.` word runs is kept as the command text it is,
# and a command substitution is kept wherever it stands. A quote or a
# substitution that cannot be paired leaves the whole text to be cut unmasked,
# so a command the reader could not take apart is read with its full reach.
#
# `command_text SEGMENT` leaves COMMAND_TEXTS holding, one per line, that
# segment from each word the shell may execute, for a caller judging what a
# command is rather than what it mentions.
#
# The helpers below leave their answers in BARE, UPTO, SUBS, OUTSIDE, MASKED
# and COMMAND_TEXTS, so a caller does not use those names for its own state.

NL=$'\n'
MASK=$'\001'
# A `#` begins a comment wherever it begins a word, which is the start of the
# line, the point after a blank, and the point after an unquoted `&`, `;`, `|`,
# a parenthesis or a backtick, since each of those ends the word before it. The
# blank and the metacharacters stand in one bracket expression so the cut lands
# on the earliest of them, not on whichever pattern a case statement reaches
# first. The result lands in BARE rather than on stdout: a command substitution
# under errexit would end the script on its own status before the caller could
# test the result.
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
# word ending in `sh`, such as `push`, as one; that keeps the span as command
# text rather than masking it, which is the direction a guard fails in.
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
# to drop. A substitution that does not close is text the reader could not
# read, and the caller is told, as it is for a quote that does not pair.
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
# a caller's patterns their whole-text reach over everything else, so there is
# no list of words that may precede a command to be incomplete.
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
# quote that still does not pair is a span the reader could not read, and the
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
# unterminated body is text the reader could not read, and dropping it would
# take the rest of the command with it. Each segment then loses its comment.
command_segments() { # TEXT -> SEGMENTS, one segment per line
  local joined=${1//\\$NL/ } line index count delim expands end term judged="" cut out=""
  local lines
  lines=()
  while IFS= read -r line; do
    lines[${#lines[@]}]=$line
  done <<EOF
$joined
EOF
  index=0
  count=${#lines[@]}
  while [ "$index" -lt "$count" ]; do
    line=${lines[$index]}
    judged=$judged$line$NL
    index=$((index + 1))
    uncommented "$line"
    if mask_spans "$BARE"; then
      BARE=$MASKED
    fi
    [[ $BARE =~ (^|[^<])\<\<-?[[:space:]]*([^[:space:]\<][^[:space:]]*) ]] || continue
    delim=${BASH_REMATCH[2]}
    # `<<'EOF'` and `<<"EOF"` name the same delimiter as `<<EOF`, but a quoted
    # delimiter stops the shell expanding the body, so nothing in that body runs.
    expands=1
    case "$delim" in
      \'*\' | \"*\") delim=${delim:1:${#delim} - 2}; expands="" ;;
    esac
    end=$index
    while [ "$end" -lt "$count" ]; do
      term=${lines[$end]}
      [ "${term#"${term%%[![:space:]]*}"}" = "$delim" ] && break
      end=$((end + 1))
    done
    [ "$end" -lt "$count" ] || continue
    if runs_shell_text "$BARE"; then
      while [ "$index" -lt "$end" ]; do
        judged=$judged${lines[$index]}$NL
        index=$((index + 1))
      done
    elif [ -n "$expands" ]; then
      # The body itself is data, but the shell expands it before the command
      # reads it, so a command substitution inside it runs. A line holding one
      # the reader cannot close is kept whole rather than dropped.
      while [ "$index" -lt "$end" ]; do
        if lift_substitutions "${lines[$index]}"; then
          judged=$judged$SUBS
        else
          judged=$judged${lines[$index]}$NL
        fi
        index=$((index + 1))
      done
    fi
    index=$((end + 1))
  done
  # A quote the reader could not pair leaves the original text to be cut
  # whole, the reach a caller's patterns had before any span was read.
  if mask_spans "$judged"; then
    cut=$MASKED
  else
    cut=$joined
  fi
  cut=${cut//;/$NL}
  cut=${cut//&/$NL}
  cut=${cut//\|/$NL}
  cut=${cut//\(/$NL}
  cut=${cut//\)/$NL}
  cut=${cut//\`/$NL}
  while IFS= read -r line; do
    uncommented "$line"
    out=$out$BARE$NL
  done <<EOF
$cut
EOF
  SEGMENTS=$out
}
# The parts of one segment the shell may execute, each from a word on to the
# segment's end. Leading `NAME=value` words are assignments the shell makes for
# the command, not the command, so each is stepped over; a quoted value was
# masked to one word by command_segments. What the executable word runs is not
# always that word: `bash` runs a script among the words after it, and a
# launcher such as `env` or `xargs` runs a word of its own. Which word depends
# on options that may take the next word as their value, and a launcher may
# launch another, so no option is read and no launcher is listed: the
# executable word starts a text, and so does every word after it. A word that
# only stands as an argument is judged as a command too, which is the direction
# a guard fails in. A quote around a word stays, as the caller's pattern may
# allow one. COMMAND_TEXTS is empty when the segment executes nothing.
command_text() { # SEGMENT -> COMMAND_TEXTS
  local rest=$1 word name
  while :; do
    rest=${rest#"${rest%%[![:space:]]*}"}
    word=${rest%%[[:space:]]*}
    case "$word" in
      [[:alpha:]_]*=*) ;;
      *) break ;;
    esac
    name=${word%%=*}
    case "$name" in
      *[![:alnum:]_]*) break ;;
    esac
    rest=${rest#"$word"}
  done
  COMMAND_TEXTS=""
  while :; do
    rest=${rest#"${rest%%[![:space:]]*}"}
    [ -n "$rest" ] || return 0
    COMMAND_TEXTS=$COMMAND_TEXTS$rest$NL
    word=${rest%%[[:space:]]*}
    rest=${rest#"$word"}
  done
}
