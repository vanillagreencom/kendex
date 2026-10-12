# shellcheck shell=bash
# The text of a shell command that the shell would run, cut into segments.
# Used by block-argv-kill, block-bare-cd, block-repo-copy, block-unsafe-rm,
# command-safety and reviewer-read-only.
# Pure Bash, no external command, and sourcing it defines functions and
# constants only.
#
# `command_segments TEXT` leaves SEGMENTS holding one segment per line. A
# segment is the text between two of `;`, `&`, `|`, `(`, `)`, `` ` `` and a
# line end, with a backslash-newline continuing it, and without the comment a
# `#` beginning a word starts. What the shell would not run as a command is
# masked out before the cut: whitespace and separators inside a quoted span
# become control bytes, so no word inside a span reaches a caller's
# pattern and no character inside one starts or ends a segment, and a heredoc
# body that a proven simple data reader consumes is dropped. Groups, control
# operators and substitutions keep input unproven and can warn or refuse on
# guarded text. Other bodies remain
# command text. A quoted program that a shell, `eval`, `source` or `.` word
# runs is appended as an independent command position,
# and a command substitution is kept wherever it stands. A quote or a
# substitution that cannot be paired leaves the whole text to be cut unmasked,
# so a command the reader could not take apart is read with its full reach.
#
# `command_text SEGMENT` leaves COMMAND_TEXTS holding, one per line, that
# segment from each selected executable word, including find actions with
# plain or whole-quoted terminators
# and a known literal shell -c program. Later positional arguments stay data.
#
# The helpers below leave their answers in BARE, UPTO, SUBS, OUTSIDE, MASKED
# DATA and COMMAND_TEXTS, so a caller does not use those names for its own state.

NL=$'\n'
MASK=$'\001'
MASK_LT=$'\002'
MASK_AMP=$'\003'
MASK_SEMI=$'\004'
MASK_PIPE=$'\005'
MASK_OPEN=$'\006'
MASK_CLOSE=$'\007'
MASK_TICK=$'\010'
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
# The selected executable decides whether a quoted span is shell program text.
# A heredoc uses its redirection owner and the pipeline's receivers, not the
# first command on its opening line. Shell basenames end in `sh` (`sh`, `bash`, `zsh`,
# `dash`, `ksh`), or the word `eval`, `source` or `.`. It also reads an English
# word ending in `sh`, such as `push`, as one; that keeps the span as command
# text rather than masking it, which is the direction a guard fails in.
# A word standing immediately after a redirection operator is a file the shell
# opens, never the command it runs, so `cat > script.sh` names no shell. The
# operator takes an optional file descriptor digit in front of it.
REDIRECT_RE='[0-9]?(>>|>|<)[[:blank:]]*[^[:space:]]+'
# The quotes come off the text first: a command word may be quoted whole, as in
# `"/bin/bash" -c ...`, and a quoted word ends in the quote character, so the
# basename would never read as a shell. The redirection targets go next, since
# a target named for a script would otherwise read as the interpreter of one.
runs_shell_text() { # TEXT -> 0 when its executable runs shell text
  local bare=${1//[\'\"]/}
  while [[ $bare =~ $REDIRECT_RE ]]; do
    bare=${bare/"${BASH_REMATCH[0]}"/ }
  done
  local saved=${COMMAND_TEXTS-}
  command_text "$bare"
  local selected=${COMMAND_TEXTS%"$NL"}
  selected=${selected##*"$NL"}
  COMMAND_TEXTS=$saved
  [[ $selected =~ ^([^[:space:]]*sh|eval|source|\.)([[:space:]]|$) ]]
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
# What a quoted span the shell does not run has masked: its whitespace, so no
# word inside it reads as a word of the command; its `<`, so a `<<` written in
# it arms no heredoc; and the separators, so a `(` or a `;` written in it
# neither opens a command position for the next span nor cuts the segment.
# Preserve each quoted separator so command_text can restore literal operands
# after selecting the executable word. Whitespace still keeps a span one word.
mask_data() { # TEXT -> DATA
  DATA=${1//[[:space:]]/$MASK}
  DATA=${DATA//</$MASK_LT}
  DATA=${DATA//&/$MASK_AMP}
  DATA=${DATA//;/$MASK_SEMI}
  DATA=${DATA//\|/$MASK_PIPE}
  DATA=${DATA//\(/$MASK_OPEN}
  DATA=${DATA//\)/$MASK_CLOSE}
  DATA=${DATA//\`/$MASK_TICK}
}
# The data masker leaves executable selection to command_text.
#
# Each quoted span keeps its quotes, since a command word may be quoted whole
# (`"/path/kendex" refresh`), while its separators and whitespace
# are masked. A span the shell does run — the argument of a shell, `eval`,
# `source` or `.` word in the same segment — is opened as its own command
# position with its whitespace intact. A quote the shell hands on as a
# literal argument is not a boundary and opens no span, which is what keeps two
# escaped quotes from pairing around a real command. MASKED holds the result; a
# quote that still does not pair is a span the reader could not read, and the
# caller is told.
mask_spans() { # TEXT -> 0 with MASKED set, 1 when a quote does not pair
  local rest=$1 head quote span before out="" programs=""
  while :; do
    upto_unescaped "$rest" "'\"" || { MASKED=$out$rest$programs; return 0; }
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
    if [ "${2:-}" = context ] || [[ $before =~ $DELIM_TAIL_RE ]] || ! runs_shell_text "$before"; then
      # A single-quoted span expands nothing, so all of it is masked; a
      # double-quoted one has its substitutions lifted out first.
      if [ "$quote" = "'" ]; then
        mask_data "$span"
        out=$out$quote$DATA$quote
      else
        lift_substitutions "$span" || return 1
        mask_data "$OUTSIDE"
        out=$out$quote$DATA$quote$SUBS
      fi
    else
      # Keep the outer command intact, including later find actions. Program
      # spans are independent command positions after ordinary data is masked.
      out=$out$quote$MASK$quote
      programs=$programs$NL$span$NL
    fi
  done
}
# The heredoc bodies. Drop a body only when the owning command and the whole
# remaining command prove simple data consumption. Groups, control operators
# and substitutions keep input unproven and can warn or refuse on guarded text.
# Retain unproven executable input
# instead of enumerating the commands that might run it. The `<<` is read off the line with its
# comment dropped and its quoted spans masked, so a `<<` only written down does
# not arm one. A body is dropped only once its terminator line is found: an
# unterminated body is text the reader could not read, and dropping it would
# take the rest of the command with it. Each segment then loses its comment.
command_segments() { # TEXT -> SEGMENTS, one segment per line
  local joined=${1//\\$NL/} line index count delim expands end term judged="" cut out=""
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
    if mask_spans "$BARE" context; then
      BARE=$MASKED
    fi
    local openings=$BARE prior="" prefix strip_tabs match before owner receiver pipeline executable_body context segment receiver_segments
    local heredoc_open='(^|[^<])<<(-?)[[:blank:]]*([^[:space:]<][^[:space:]]*)'
    while [[ $openings =~ $heredoc_open ]]; do
      match=${BASH_REMATCH[0]}
      strip_tabs=${BASH_REMATCH[2]}
      delim=${BASH_REMATCH[3]}
      prefix=${openings%%"$match"*}
      before=$prior$prefix${BASH_REMATCH[1]}
      prior=$prior$prefix$match
      openings=${openings#*"$match"}
      # Preserve this simple command's context across every redirection. The
      # context mask keeps program arguments on the opening line; its synthetic
      # newlines cannot become list boundaries. The current redirection is
      # removed, and later command words remain visible (<<EOF bash).
      owner=${before##*$SEP}" "${openings%%$SEP*}
      context=$owner
      while [[ $context =~ $heredoc_open ]]; do
        context=${context/"${BASH_REMATCH[0]}"/"${BASH_REMATCH[1]} "}
      done
      command_text "$context"
      # Only a proven data reader loses its body. Unknown executable consumers
      # retain their input, rather than using an incomplete shell-name list.
      executable_body=1
      case "$COMMAND_TEXTS" in cat[[:space:]]* | cat | echo[[:space:]]* | echo | printf[[:space:]]* | printf | tee[[:space:]]* | tee) executable_body="" ;; esac
      pipeline=$openings
      while [[ $pipeline == *"|"* ]]; do
        receiver=${pipeline#*|}
        receiver=${receiver#"${receiver%%[![:space:]]*}"}
        # A grouped receiver's prefix cannot prove its whole input is data.
        # Retain that input without interpreting the group's commands.
        case "$receiver" in
          \(* | \{*) executable_body=1 ;;
          *)
            command_segments "${receiver%%|*}"
            receiver_segments=$SEGMENTS
            while IFS= read -r segment; do
              command_text "$segment"
              [ -n "$COMMAND_TEXTS" ] || continue
              case "$COMMAND_TEXTS" in cat[[:space:]]* | cat | echo[[:space:]]* | echo | printf[[:space:]]* | printf | tee[[:space:]]* | tee) ;; *) executable_body=1 ;; esac
            done <<<"$receiver_segments"
            ;;
        esac
        pipeline=$receiver
      done
      # Only the whole remaining command can prove data consumption. Masked
      # quoted data has no operators; lifted substitutions have line breaks.
      # Any remaining control or substitution keeps the body unproven.
      case "$owner$openings" in
        *'&'* | *';'* | *'`'* | *'$('* | *'<('* | *'>('* | *"$NL"*) executable_body=1 ;;
      esac
      # Quoted delimiters stop expansion, but a shell still executes the body
      # it reads as its own input. Each delimiter consumes its body in order.
      expands=1
      case "$delim" in
        \'*\' | \"*\") delim=${delim:1:${#delim} - 2}; expands="" ;;
      esac
      end=$index
      while [ "$end" -lt "$count" ]; do
        term=${lines[$end]}
        if [ "$strip_tabs" = - ]; then
          while [[ $term == $'\t'* ]]; do term=${term#$'\t'}; done
        fi
        [ "$term" = "$delim" ] && break
        end=$((end + 1))
      done
      [ "$end" -lt "$count" ] || break
      if [ -n "$executable_body" ]; then
        while [ "$index" -lt "$end" ]; do
          judged=$judged${lines[$index]}$NL
          index=$((index + 1))
        done
      elif [ -n "$expands" ]; then
        # An expanded body is data, except for its command substitutions.
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
  done
  # A quote the reader could not pair leaves the original text to be cut
  # whole, the reach a caller's patterns had before any span was read.
  if mask_spans "$judged"; then
    cut=$MASKED
  else
    cut=$joined
  fi
  if [ "${2:-}" != lines ]; then
    # Redirection operators contain ampersands or pipes without ending a
    # command. Restore these characters only after command selection.
    cut=${cut//\&>/$MASK_AMP>}
    cut=${cut//>\&/>$MASK_AMP}
    cut=${cut//<\&/<$MASK_AMP}
    cut=${cut//>\|/>$MASK_PIPE}
    if [ "${2:-}" = pipes ]; then
      # A list fallback is not a pipeline receiver.
      cut=${cut//\|\|/$NL}
      # A tar receiver can change directory inside a subshell or brace group.
      # Keep that pipe receiver together; its caller selects the commands in
      # it with this same reader before judging a destination.
      local pipe_group='\|[[:blank:]]*(\([^)]*\)|\{[^}]*\})' group kept
      while [[ $cut =~ $pipe_group ]]; do
        group=${BASH_REMATCH[0]}
        kept=${group//;/$MASK_SEMI}
        kept=${kept//&/$MASK_AMP}
        kept=${kept//$NL/$MASK_SEMI}
        kept=${kept//\(/$MASK_OPEN}
        kept=${kept//\)/$MASK_CLOSE}
        kept=${kept//\{/$MASK_OPEN}
        kept=${kept//\}/$MASK_CLOSE}
        cut=${cut/"$group"/"$kept"}
      done
    fi
    # Reuse the escape reader: only unescaped semicolons end commands.
    # A literal semicolon stays available as a find action terminator.
    local semicolon_tail=$cut semicolon_cut="" semicolon_head
    while upto_unescaped "$semicolon_tail" ';'; do
      semicolon_head=$UPTO
      semicolon_tail=${semicolon_tail#"$semicolon_head"}
      semicolon_tail=${semicolon_tail:1}
      semicolon_cut=$semicolon_cut${semicolon_head//\\;/$MASK_SEMI}$NL
    done
    cut=$semicolon_cut${semicolon_tail//\\;/$MASK_SEMI}
    cut=${cut//&/$NL}
    if [ "${2:-}" = pipes ]; then
      cut=${cut//\|\|/$NL}
      local pipe_join='\|[[:blank:]]*'$NL
      while [[ $cut =~ $pipe_join ]]; do
        cut=${cut/"${BASH_REMATCH[0]}"/| }
      done
    else
      cut=${cut//\|/$NL}
    fi
    cut=${cut//\(/$NL}
    cut=${cut//\)/$NL}
    cut=${cut//\`/$NL}
  fi
  while IFS= read -r line; do
    uncommented "$line"
    out=$out$BARE$NL
  done <<EOF
$cut
EOF
  SEGMENTS=$out
}
# Select the executable word after control words, assignments and launchers.
# Known launcher options consume their own values; timeout consumes its duration.
# find's -exec and -execdir operands are actual command positions. Whole-quoted
# terminators close the same action boundaries as plain ones. Other find
# arguments remain data. Assembled names and unknown option arities remain
# outside this lexical reader's contract.
command_text() { # SEGMENT -> COMMAND_TEXTS
  local rest=$1 word name executable launcher="" takes_value="" duration="" find_rest
  COMMAND_TEXTS=""
  while :; do
    rest=${rest#"${rest%%[![:space:]]*}"}
    [ -n "$rest" ] || return 0
    local redirect_prefix="^$REDIRECT_RE"
    if [[ $rest =~ $redirect_prefix ]]; then rest=${rest#"${BASH_REMATCH[0]}"}; continue; fi
    case "$rest" in
      \(* | "$MASK_OPEN"*) rest=${rest:1}; continue ;;
    esac
    word=${rest%%[[:space:]]*}
    if [ -n "$takes_value" ]; then
      rest=${rest#"$word"}; takes_value=""; continue
    fi
    case "$word" in
      [[:alpha:]_]*=*)
        name=${word%%=*}
        case "$name" in *[![:alnum:]_]*) ;; *) rest=${rest#"$word"}; continue ;; esac
        ;;
    esac
    executable=$word
    case "$executable" in
      \'*\' | \"*\") executable=${executable:1:${#executable} - 2} ;;
    esac
    executable=${executable##*/}
    case "$launcher:$executable" in
      timeout:-k | timeout:--kill-after | timeout:-s | timeout:--signal | \
      nice:-n | nice:--adjustment | ionice:-c | ionice:--class | ionice:-n | ionice:--classdata | \
      sudo:-u | sudo:-g | sudo:-h | sudo:-p | sudo:-C | sudo:-T | doas:-u | doas:-C | \
      env:-u | env:--unset | env:-C | env:--chdir | exec:-a | \
      xargs:-I | xargs:-n | xargs:-L | xargs:-P | xargs:-s | xargs:-E | xargs:-a | \
      xargs:--replace | xargs:--max-args | xargs:--max-lines | xargs:--max-procs | \
      xargs:--max-chars | xargs:--eof | xargs:--arg-file | \
      stdbuf:-i | stdbuf:-o | stdbuf:-e | stdbuf:--input | stdbuf:--output | stdbuf:--error)
        rest=${rest#"$word"}; takes_value=1; continue ;;
      command:-v | command:-V)
        # These ask about a command without running it.
        COMMAND_TEXTS="command $rest$NL"
        return 0 ;;
    esac
    case "$executable" in
      -*) if [ -n "$launcher" ]; then rest=${rest#"$word"}; continue; fi ;;
    esac
    if [ -n "$duration" ]; then
      rest=${rest#"$word"}; duration=""; continue
    fi
    case "$executable" in
      fi | done | esac | '}') return 0 ;;
      if | then | else | elif | while | until | do | '{' | '!' | time | command | exec | \
      sudo | env | nohup | timeout | nice | ionice | xargs | doas | stdbuf | setsid)
        rest=${rest#"$word"}; launcher=$executable
        [ "$launcher" != timeout ] || duration=1
        continue ;;
      find)
        find_rest=${rest#"$word"}
        local actions="" action="" active="" terminator
        while [ -n "$find_rest" ]; do
          find_rest=${find_rest#"${find_rest%%[![:space:]]*}"}
          [ -n "$find_rest" ] || break
          name=${find_rest%%[[:space:]]*}
          find_rest=${find_rest#"$name"}
          terminator=$name
          case "$terminator" in
            \'*\' | \"*\") terminator=${terminator:1:${#terminator} - 2} ;;
          esac
          if [ -z "$active" ]; then
            case "$name" in -exec | -execdir) active=1 ;; esac
          elif [ "$terminator" = + ] || [ "$terminator" = '\;' ] || [ "$terminator" = ";" ] || [ "$terminator" = "$MASK_SEMI" ]; then
            command_text "$action"
            actions=$actions$COMMAND_TEXTS
            active=""; action=""
          else
            action=$action" "$name
          fi
        done
        if [ -n "$active" ]; then
          command_text "$action"
          actions=$actions$COMMAND_TEXTS
        fi
        if [ -n "$actions" ]; then COMMAND_TEXTS=$actions; return 0; fi
        ;;
    esac
    rest=$executable${rest#"$word"}
    rest=${rest//$MASK_LT/<}
    rest=${rest//$MASK_AMP/\&}
    rest=${rest//$MASK_SEMI/;}
    rest=${rest//$MASK_PIPE/|}
    rest=${rest//$MASK_OPEN/(}
    rest=${rest//$MASK_CLOSE/)}
    rest=${rest//$MASK_TICK/\`}
    COMMAND_TEXTS=$rest$NL
    # The known literal -c argument is program text. Positional arguments
    # after that one remain data; no expansion or option grammar is performed.
    local shell_c='^[^[:space:]]+[[:space:]]+-c[[:space:]]+([^[:space:]]+)' program selected_text
    if [[ $executable == *sh && $rest =~ $shell_c ]]; then
      program=${BASH_REMATCH[1]}
      case "$program" in \'* | \"*) ;; *)
        selected_text=$COMMAND_TEXTS
        command_text "$program"
        COMMAND_TEXTS=$selected_text$COMMAND_TEXTS
        ;; esac
    fi
    return 0
  done
}
