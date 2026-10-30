#!/usr/bin/env bash
# ---
# name: command-safety
# event: PreToolUse
# matcher: Bash
# description: On harnesses that execute hooks, refuse cat reads of the known ~/.fleet/env spellings. Refuse a recognized whole-environment read where the shell runs it, unless a proven direct pipe filters named variables: at a command head, among the forwarded operands of a shell or source script, a shell or env -S command string, exec or builtin, in selected shell, eval or env -S source, in literal input a shell, exec or builtin gets, and in heredoc bodies an unknown receiver gets. Words elsewhere are data. This fixed check runs outside Git and before project policy. Nested dumps can refuse conservatively. It reads submitted text, not unseen programs, aliases or runtime-built commands. COMMAND_SAFETY_DENY_PATTERN replaces only the default systemd-run memory-cap pattern; `^$` disables only that project-pattern check.
# summary: Refuses cat reads of the known private environment file and offers the named non-secret settings reader. Refuses whole-environment reads where the shell would run them and gives a filter that names a variable; the same words as an argument, or in one quoted `<<` cat heredoc whose output goes to the terminal or a file, pass. Also applies the project deny pattern or the default systemd-run memory-cap rule. Unreadable payloads warn and allow the call; unreadable policy support affects only the pattern check.
# safety: Classify literal command producers at executable positions, with one producer grammar: command heads, each forwarded operand of a shell or source script, a shell or env -S command string, exec or builtin, selected shell, eval and env -S source, each literal body a shell, exec or builtin gets, and each heredoc body an unknown receiver gets, judged alone as shell source. Known interpreters at a stage's own head use language-specific whole-environment evidence, which also judges input to exec, builtin and syntax-only stages, piped input included; literal cat bodies retain their data contract. Text a waiter launcher forwards keeps a conservative word test. Unquoted body expansions are checked independently. Known private-file cat reads cannot be filtered into permission. Only proven direct named-variable filters grant environment-producer dump permission; project-pattern matching remains independent and reads the submitted text. Not reached: unseen programs and runtime-built names; an unknown launcher or non-producer reader inside reserved-word syntax, such as if true; then timeout 5 env; fi; the same command as a quoted forwarded argument when the launcher stage redirects its output; the same command inside a body an unknown receiver gets; here-string input to any stage other than a shell, eval or source and an exec, builtin or syntax-only stage, an unknown program and a Python, Node, Ruby or Perl head alike, such as ssh host <<< env or python3 <<< os.environ; and an interpreter body that is forwarded or nested in shell source, such as bash wrapper.sh python3 <<'EOF'. An undecoded ANSI-C escape refuses with reason=undecoded-ansi-escape under the keyed line. Unreadable payloads or policy support warn and allow their affected check. Every diagnostic starts with command-safety: <key>=<value>.
# timeout: 10
# requires-skills: [commit-guards]
# ---

set -euo pipefail

# The reported private file is checked as text, without opening it or
# evaluating submitted expansions. Filtering cannot make that read safe.
environment_private_path() {
  local path
  for path in "$@"; do
    case "$path" in '~/.fleet/env' | '$HOME/.fleet/env' | '${HOME}/.fleet/env') return 0 ;; esac
    if [ -n "${HOME:-}" ] && [ "$path" = "$HOME/.fleet/env" ]; then return 0; fi
  done
  return 1
}

# This rule belongs to this hook, not the replaceable project pattern. No
# harness output-rewrite interface can remove secrets before the transcript.
# A harness permission rule cannot hold it either: such a rule matches command
# text by prefix or pattern and knows no filter, launcher or quoting, so it
# can neither admit a named grep of a dump nor find a dump a launcher runs.
# Only a proven direct pipe grants permission. Nested syntax is detection
# evidence, never proof of routing; unseen program semantics are not judged.
# The one producer judges a stage head and every forwarded operand alike.
environment_producer() { # command kind
    # Other is unresolved. An existing arm's proof must establish clean.
    mode=other
    # Only these literal forwarding forms are part of the input contract.
    # Unsupported executable-string arguments get conservative detection.
    while [ "$program" != opaque ] && [ "$pos" -lt "${#args[@]}" ]; do
      # ANSI-C escapes in a head have no decoder in this input contract.
      # Refuse rather than permit an encoded environment producer.
      [ "${arg_kinds[$pos]}" != ansi-escaped ] || { mode=dump-unknown; dump_reason=undecoded-ansi-escape; return; }
      [ "${arg_kinds[$pos]}" != dollar-literal ] || arg_kinds[pos]=literal
      [ "${arg_kinds[$pos]}" = literal ] || break
      program_pos=$pos; program=${args[$pos]##*/}; pos=$((pos + 1))
      case "$program" in
        exec | builtin)
          if [ "$1" = shell ] && [ "${args[$((pos - 1))]}" = "$program" ]; then
            program=opaque; compound=1
          fi
          break ;;
        command)
          case "${args[$pos]:-}" in -v | -V) pos=${#args[@]}; break ;; -p) pos=$((pos + 1)) ;; esac
          [ "${args[$pos]:-}" != -- ] || pos=$((pos + 1))
          continue ;;
        sudo)
          while [ "$pos" -lt "${#args[@]}" ]; do
            case "${args[$pos]}" in
              -u | -g | --user | --group) pos=$((pos + 2)) ;;
              --user=* | --group=* | -n | -E | -H) pos=$((pos + 1)) ;;
              --) pos=$((pos + 1)); break ;;
              *) break ;;
            esac
          done
          continue ;;
        env)
          options_ended=""; null_output=""
          while [ "$pos" -lt "${#args[@]}" ]; do
            value=${args[$pos]}
            case "${arg_kinds[$pos]}" in dollar-literal | ansi-escaped) break ;; esac
            # -- ends options, not the following assignment operands.
            if [[ $value =~ $name_re ]] && [[ $value == *=* ]]; then pos=$((pos + 1)); continue; fi
            [ -z "$options_ended" ] || break
            case "$value" in
              -i | --ignore-environment) pos=$((pos + 1)) ;;
              -0 | --null) null_output=1; pos=$((pos + 1)) ;;
              -u | --unset | -C | --chdir)
                # A non-literal operand such as "$@" can expand to no word,
                # and env then takes the next word as that operand.
                [ "${arg_kinds[$((pos + 1))]:-}" = literal ] || { mode=dump-unknown; return; }
                pos=$((pos + 2)) ;;
              --unset=* | --chdir=*) pos=$((pos + 1)) ;;
              --help | --version) pos=${#args[@]}; program=""; break ;;
              --) options_ended=1; pos=$((pos + 1)); continue ;;
              -S | --split-string | --split-string=*) program=opaque; break ;;
              -*) mode=dump-unknown; break ;;
              *) break ;;
            esac
          done
          if [ "$program" = env ] && [ "$pos" -ge "${#args[@]}" ]; then
            mode=dump-lines; [ -z "$null_output" ] || mode=dump-nul
          fi
          if [ "$program" = env ] && [ "${arg_kinds[$pos]:-literal}" != literal ]; then
            mode=dump-unknown; [ "${arg_kinds[$pos]}" != ansi-escaped ] || dump_reason=undecoded-ansi-escape
          fi
          [ "$program" = env ] && [ "$mode" = other ] || break
          continue ;;
        *) break ;;
      esac
    done
    producer_end=$pos
    # Bash expands ANSI-C escapes after the harness submits command text.
    # These producer operands cannot prove a safe name, flag or input path.
    case "${program:-}" in
      printenv | export | declare | typeset | set | systemctl | cat | tr | strings | xargs)
        for ((j=pos; j<${#args[@]}; j++)); do
          [ "${arg_kinds[$j]}" != ansi-escaped ] || { mode=dump-unknown; dump_reason=undecoded-ansi-escape; return; }
        done ;;
    esac
    case "${program:-}" in
      cat | tr | strings | xargs) [ -z "$input_escaped" ] || { mode=dump-unknown; dump_reason=undecoded-ansi-escape; return; } ;;
    esac
    case "${program:-}" in
      printenv)
        named=""; options_ended=""; null_output=""; mode=dump-lines
        for ((j=pos; j<${#args[@]}; j++)); do
          value=${args[$j]}
          [ "${arg_kinds[$j]}" = literal ] || mode=dump-unknown
          if [ -z "$options_ended" ]; then
            case "$value" in
              --help | --version) named=1; continue ;;
              -0 | --null) null_output=1; continue ;;
              --) options_ended=1; continue ;;
              -*) mode=dump-unknown; continue ;;
            esac
          fi
          [ "${arg_kinds[$j]}" != literal ] || [[ ! $value =~ $name_re ]] || named=1
        done
        if [ "$mode" != dump-unknown ]; then
          if [ -n "$named" ]; then mode=clean; elif [ -n "$null_output" ]; then mode=dump-nul; fi
        fi ;;
      export | declare | typeset)
        # Only a word that starts with a literal name, alone or before = or
        # +=, names a variable. Any other expanding word, such as "$x", can
        # be an option or no word at all; beside listing flags alone, it
        # keeps the listing judgment.
        named=""; flags=""; listing=1
        for ((j=pos; j<${#args[@]}; j++)); do
          value=${args[$j]}
          case "${arg_kinds[$j]}:$value" in
            literal:-* | dollar-literal:-*)
              flags=$flags$value; [[ $value =~ ^(--|-[gI]+)$ ]] || listing="" ;;
            literal:* | dollar-literal:*)
              if [[ $value =~ $declared_re ]]; then named=1; else listing=""; fi ;;
            *) [[ ! $value =~ $declared_re ]] || named=1 ;;
          esac
        done
        if [ -z "$named" ]; then
          # With no name, declare and typeset print every variable: bare,
          # after --, with only the g and I scope flags, or with only those
          # flags and expanding words that name none.
          case "$program:$flags" in export:* | *:*p* | *:*x*) mode=dump-lines ;; esac
          [ -z "$listing" ] || mode=dump-lines
          if [ "$mode" = dump-lines ]; then
            for ((j=pos; j<${#args[@]}; j++)); do
              value=${args[$j]}
              case "$value" in --) ;; -*) [[ $value =~ ^-[px]+$ ]] || mode=dump-unknown ;; *) mode=dump-unknown ;; esac
            done
          fi
        else
          mode=clean
        fi ;;
      set)
        named=""
        for ((j=pos; j<${#args[@]}; j++)); do [ "${arg_kinds[$j]}" != literal ] || named=1; done
        if [ -z "$named" ]; then
          if [ "$pos" -lt "${#args[@]}" ]; then mode=dump-unknown; else mode=dump-lines; fi
        fi
        [ -z "$named" ] || [ "$mode" != other ] || mode=clean ;;
      systemctl)
        for ((j=pos; j<${#args[@]}; j++)); do [ "${args[$j]}" != show-environment ] || mode=dump-lines; done
        if [ "$mode" = dump-lines ]; then
          for ((j=pos; j<${#args[@]}; j++)); do
            case "${args[$j]}" in --user | --system | -- | show-environment) ;; *) mode=dump-unknown ;; esac
          done
        fi ;;
      cat | tr | strings | xargs)
        for ((j=pos; j<${#args[@]}; j++)); do [[ ${args[$j]} != /proc/*/environ ]] || proc=1; done
        if [ -n "$proc" ]; then
          case "$program" in
            cat | strings)
              mode=dump-nul; [ "$program" != strings ] || mode=dump-lines
              for ((j=pos; j<${#args[@]}; j++)); do
                [ "${args[$j]}" != -- ] || continue
                [ "${arg_kinds[$j]}" = literal ] || mode=dump-unknown
                [[ ${args[$j]} == /proc/*/environ ]] || mode=dump-unknown
              done ;;
            tr | xargs) mode=dump-unknown ;;
          esac
        fi
        # Only this literal conversion proves separate newline records.
        # Unknown transformations and flattened xargs output stay unknown.
        if [ "$program" = tr ] && [ -z "$output" ] && [ "$((${#args[@]} - pos))" -eq 2 ] &&
          [ "${arg_kinds[$pos]}:${arg_kinds[$((pos + 1))]}" = literal:literal ]; then
          case "${args[$pos]}:${args[$((pos + 1))]}" in
            '\0:\n' | '\000:\n')
              if [ -n "$proc" ]; then mode=dump-lines; elif [ -z "$input_redirect" ]; then mode=convert; fi ;;
          esac
        fi
        if [ "$program" = cat ] && environment_private_path ${private_inputs[@]+"${private_inputs[@]}"} "${args[@]:pos}"; then mode=dump-unknown; fi ;;
      grep)
        filter_ok=1; pattern_count=0; pattern=""
        for ((j=pos; j<${#args[@]}; j++)); do
          value=${args[$j]}
          [ "${arg_kinds[$j]}" = literal ] || filter_ok=""
          case "$value" in
            --) pos=$((j + 1)); break ;;
            -e) j=$((j + 1)); value=${args[$j]:-}; [ "${arg_kinds[$j]:-}" = literal ] || filter_ok="" ;;
            -*) [[ $value =~ ^-[EFq]+$ ]] || filter_ok=""; continue ;;
          esac
          pattern_count=$((pattern_count + 1)); pattern=$value
        done
        if [ "${value:-}" = -- ]; then
          for ((j=pos; j<${#args[@]}; j++)); do
            pattern_count=$((pattern_count + 1)); pattern=${args[$j]}; [ "${arg_kinds[$j]}" = literal ] || filter_ok=""
          done
        fi
        if [ -n "$filter_ok" ] && [ "$pattern_count" -eq 1 ] && [[ $pattern =~ $filter_re ]] && [ -z "$input_redirect" ]; then mode=filter; fi ;;
    esac
    # No unresolved arm can discharge the forwarded classification check.
    if [ "$mode" = other ] && [ -n "${forwarded_argument:-}" ]; then mode=unclassified-forwarded; fi
}

# Reserved-word syntax and assignment prefixes come before the executable
# head; a quoted or pathname word is never syntax.
environment_head() { # command kind; updates pos, syntax_head and head_start
  local cursor state=head value
  pos=${#args[@]}; syntax_head=""; head_start=0
  if [ "$1" = argv ]; then pos=0; return; fi
  while [ "$head_start" -lt "${#args[@]}" ] && [[ ${args[$head_start]} =~ $name_re ]] && [[ ${args[$head_start]} == *=* ]]; do head_start=$((head_start + 1)); done
  for ((cursor=0; cursor<${#args[@]}; cursor++)); do
    value=${args[$cursor]}
    case "$state" in
      name) state=body; continue ;;
      body | loop | conditional)
        if [ "${arg_kinds[$cursor]}" = literal ] && [ -n "${arg_unquoted[$cursor]}" ]; then
          case "$value:$state" in '{:body' | do:loop) state=head ;; esac
        fi
        continue ;;
      time)
        case "$value" in -*) continue ;; esac
        state=head ;;
    esac
    if [[ $value =~ $name_re ]] && [[ $value == *=* ]]; then continue; fi
    if [ "${arg_kinds[$cursor]}" = literal ] && [ -n "${arg_unquoted[$cursor]}" ]; then
      case "$value" in
        if | then | elif | else | while | until | do | '{' | '!')
          syntax_head=1; continue ;;
        time) syntax_head=1; state=time; continue ;;
        function) syntax_head=1; state=name; continue ;;
        for | select) syntax_head=1; state=loop; continue ;;
        case | '[[') syntax_head=1; state=conditional; continue ;;
        'coproc')
          syntax_head=1
          if [ "${args[$((cursor + 2))]:-}" = '{' ]; then state=name; fi
          continue ;;
        fi | done | 'esac' | '}' | ']]' | in)
          syntax_head=1; continue ;;
      esac
    fi
    pos=$cursor
    return
  done
}

# A word test for text a waiter launcher forwards, which it later runs
# through bash -c: an unclassified stage, and a forwarded body that holds
# heredocs. It runs nowhere else and grants no permission.
environment_main_evidence() {
  local value evidence continuation=$'\\\n'
  local opaque_re='(^|[^A-Za-z0-9_.-])(env|printenv|export|declare|typeset|show-environment)([^A-Za-z0-9_.-]|$)|(^|[^A-Za-z0-9_-])set([^A-Za-z0-9_-]|$)|/proc/[^[:space:]]*/environ'
  for value in "$@"; do
    evidence=${value//"$continuation"/}
    evidence=${evidence//[\'\"\\]/}
    [[ ! $evidence =~ $opaque_re ]] || return 0
  done
  return 1
}

# Receiving language is a local classification, not an exemption from the
# independent shell expansion and unsupported forwarding checks.
environment_receiver() { # language
  receiver=unknown; receiver_pattern=""; receiver_option=""; receiver_named=""
  case "$1" in
    cat) receiver=data ;;
    bash | sh | dash | zsh | ksh | eval | source | .) receiver=shell ;;
    python | python3)
      receiver=interpreter; receiver_option='^-c$'
      receiver_pattern='(^|[^A-Za-z0-9_])os[[:space:]]*\.[[:space:]]*environ'
      receiver_named='^[[:blank:]]*(\[|\.[[:blank:]]*(get|pop|setdefault|__getitem__|__contains__)[[:blank:]]*\()' ;;
    node)
      receiver=interpreter; receiver_option='^(-e|--eval)$'
      receiver_pattern='(^|[^A-Za-z0-9_])process[[:space:]]*\.[[:space:]]*env'
      receiver_named='^[[:blank:]]*(\[|\.)' ;;
    ruby)
      receiver=interpreter; receiver_option='^-e$'
      receiver_pattern='(^|[^A-Za-z0-9_])ENV[[:space:]]*\.[[:space:]]*(to_h|each)([^A-Za-z0-9_]|$)' ;;
    perl)
      receiver=interpreter; receiver_option='^-e$'
      receiver_pattern='%ENV([^A-Za-z0-9_]|$)' ;;
  esac
}

environment_receiver_evidence() { # language text
  local remaining=$2 matched receiver receiver_pattern receiver_option receiver_named
  environment_receiver "$1"
  case "$1" in
    python | python3)
      local source=$2 executable="" span quote c i=0 end found uncertain=""
      local dynamic_re='(^|[^A-Za-z0-9_])(exec|eval|compile)([^A-Za-z0-9_]|$)'
      local span_re="^[^\"'#]+"
      local unsafe_re='(^|[^A-Za-z0-9_])(os|__import__|importlib|getattr|globals|vars|exec|eval|compile)([^A-Za-z0-9_]|$)|(^|[^A-Za-z0-9_])sys[[:space:]]*\.[[:space:]]*modules([^A-Za-z0-9_]|$)'
      local import_re='(^|[^A-Za-z0-9_])(from|import)([^A-Za-z0-9_]|$)' imports import_kind
      local module_re='^[[:blank:]]+(pathlib|re|json|textwrap)([[:blank:]]+as[[:blank:]]+[A-Za-z_][A-Za-z0-9_]*)?[[:blank:]]*(,[[:blank:]]*(pathlib|re|json|textwrap)([[:blank:]]+as[[:blank:]]+[A-Za-z_][A-Za-z0-9_]*)?[[:blank:]]*)*$'
      local from_re='^[[:blank:]]+(pathlib|re|json|textwrap)[[:blank:]]+import[[:blank:]]+'
      # Source-edit literals are data only with these non-executing imports.
      # Other imports, dynamic access and uncertain syntax keep raw evidence:
      # child interpreters can execute a quoted environment read.
      if [[ ! $source =~ $dynamic_re ]]; then
        while [ "$i" -lt "${#source}" ]; do
          c=${source:i:1}
          case "$c" in
            '#')
              span=${source:i}; span=${span%%$'\n'*}
              executable=$executable$span; i=$((i + ${#span})) ;;
            "'" | '"')
              if [ "$i" -gt 0 ]; then
                case "${source:i-1:1}" in [A-Za-z0-9_] | \\) uncertain=1; break ;; esac
              fi
              quote=$c
              [ "${source:i:3}" != "$c$c$c" ] || quote=$c$c$c
              end=$((i + ${#quote})); found=""
              while [ "$end" -lt "${#source}" ]; do
                if [ "${source:end:1}" = '\' ]; then end=$((end + 2)); continue; fi
                if [ "${source:end:${#quote}}" = "$quote" ]; then
                  end=$((end + ${#quote})); found=1; break
                fi
                if [ "${#quote}" -eq 1 ] && [ "${source:end:1}" = $'\n' ]; then break; fi
                span=${source:end}
                span=${span%%"$c"*}; span=${span%%\\*}
                [ "${#quote}" -ne 1 ] || span=${span%%$'\n'*}
                if [ -n "$span" ]; then end=$((end + ${#span})); else end=$((end + 1)); fi
              done
              [ -n "$found" ] || { uncertain=1; break; }
              span=${source:i:end-i}
              executable=$executable${span//[!$'\n']/ }; i=$end ;;
            *)
              [[ ${source:i} =~ $span_re ]] || { uncertain=1; break; }
              span=${BASH_REMATCH[0]}
              executable=$executable$span; i=$((i + ${#span})) ;;
          esac
        done
        if [[ $executable =~ $unsafe_re ]]; then uncertain=1; fi
        imports=$executable
        while [ -z "$uncertain" ] && [[ $imports =~ $import_re ]]; do
          matched=${BASH_REMATCH[0]}; import_kind=${BASH_REMATCH[2]}
          span=${BASH_REMATCH[3]}
          imports=$span${imports#*"$matched"}
          span=${imports%%$'\n'*}; span=${span%%;*}; span=${span%%#*}
          if [ "$import_kind" = from ]; then
            [[ $span =~ $from_re ]] || uncertain=1
          else
            [[ $span =~ $module_re ]] || uncertain=1
          fi
          imports=${imports#"$span"}
        done
        if [ -z "$uncertain" ]; then remaining=$executable; fi
      fi ;;
  esac
  while [[ $remaining =~ $receiver_pattern ]]; do
    matched=${BASH_REMATCH[0]}
    remaining=${remaining#*"$matched"}
    [ -n "$receiver_named" ] || return 0
    # Identifier suffixes are not this object. A newline ends the reference;
    # only same-line key selection proves a named value instead of a mapping.
    if [[ $remaining =~ ^[A-Za-z0-9_]+ ]]; then
      matched=${BASH_REMATCH[0]}
      remaining=${remaining#"$matched"}
      continue
    fi
    [[ $remaining =~ $receiver_named ]] || return 0
  done
  return 1
}

# Selected shell, eval and env -S source runs later as shell text; queue it
# for recursive parsing in the context its stage holds.
environment_queue() { # source text
  local code=${#executable_texts[@]} context=conservative
  [ -z "${forwarded_argument:-}" ] || context=forwarded
  executable_texts[code]=$1; executable_stages[code]=$stage; executable_contexts[code]=$context
}

# Shell invocation options precede the executable operand, including options
# after -c. Known literal input stays conservative for every shell invocation;
# script operands and redirects do not prove that the body is unused.
environment_program_text() {
  local cursor=$pos source="" options_ended="" wants_string="" value text="" source_end input later
  stdin_program=""; source_pos=""; script_operand=""
  environment_receiver "$program"
  if [ "$receiver" = interpreter ]; then
    for ((cursor=pos; cursor<${#args[@]}; cursor++)); do
      if [[ ${args[$cursor]} =~ $receiver_option ]]; then
        cursor=$((cursor + 1))
        if [ "${arg_kinds[$cursor]:-}" = literal ] &&
           environment_receiver_evidence "$program" "${args[$cursor]:-}"; then mode=dump-unknown; fi
        break
      fi
      case "${args[$cursor]}" in - | --) break ;; -*) ;; *) break ;; esac
    done
    return
  fi
  case "$program" in
    bash | sh | dash | zsh | ksh)
      stdin_program=1
      while [ "$cursor" -lt "${#args[@]}" ]; do
        value=${args[$cursor]}
        # Only a literal word is a known option; an expanding one such as
        # -"$FLAGS" takes the non-literal option-word check below.
        if [ -z "$options_ended" ] && [ "${arg_kinds[$cursor]}" = literal ]; then
          case "$value" in
            --) options_ended=1; cursor=$((cursor + 1)); continue ;;
            --rcfile | --init-file) cursor=$((cursor + 2)); continue ;;
            -[^-]* | +*)
              # A short-option word can combine command-string selection and
              # an option with an operand. Consume the entire invocation word.
              [[ $value != -*c* ]] || wants_string=1
              case "${value:1}" in
                *[oO]*[oO]*)
                  # Grouped option operands cannot be counted, so any later
                  # word can be the command string.
                  for ((cursor=cursor+1; cursor<${#args[@]}; cursor++)); do environment_queue "${args[$cursor]}"; done
                  return ;;
                *o* | *O*) cursor=$((cursor + 2)) ;;
                *) cursor=$((cursor + 1)) ;;
              esac
              continue ;;
            -*) cursor=$((cursor + 1)); continue ;;
          esac
        fi
        # Words after the command string reach it as $0 and "$@", which it
        # can run, so they are forwarded operands like a script's.
        script_operand=$cursor
        if [ -n "$wants_string" ]; then source=$value; source_pos=$cursor
        # A non-literal option word such as "$MODE" can expand to -c, and
        # the next word is then the command string.
        elif [ -z "$options_ended" ] && [ "${arg_kinds[$cursor]}" != literal ] &&
             [ "$((cursor + 1))" -lt "${#args[@]}" ]; then
          environment_queue "${args[$((cursor + 1))]}"
        fi
        break
      done ;;
    eval)
      stdin_program=1
      # Bash's eval takes one leading -- before joining its source.
      cursor=$pos
      [ "${args[$cursor]:-}:${arg_kinds[$cursor]:-}" != --:literal ] || cursor=$((cursor + 1))
      source_pos=$cursor
      for ((; cursor<${#args[@]}; cursor++)); do
        source=$source$text${args[$cursor]}; text=' '
      done ;;
    source | .)
      stdin_program=1
      # The script runs its operands as "$@", like a shell script's.
      [ "$pos" -ge "${#args[@]}" ] || script_operand=$pos ;;
    opaque)
      # Literal input to exec, builtin or a syntax-only stage runs as shell
      # text; environment_dump also judges it with the interpreter patterns.
      [ -z "$data_source" ] || stdin_program=1
      case "${args[$pos]:-}" in
        -S | --split-string) source_pos=$((pos + 1)); source=${args[$source_pos]:-} ;;
        --split-string=*) source_pos=$pos; source=${args[$pos]#*=} ;;
      esac
      # The split string's program gets the later words, which it can run.
      script_operand=$source_pos ;;
  esac
  [ -n "$source_pos" ] || return 0
  # An encoded source has no decoder in this input contract.
  source_end=$((source_pos + 1)); [ "$program" != eval ] || source_end=${#args[@]}
  for ((cursor=source_pos; cursor<source_end; cursor++)); do
    [ "${arg_kinds[$cursor]:-}" != ansi-escaped ] || { mode=dump-unknown; dump_reason=undecoded-ansi-escape; return; }
  done
  environment_queue "$source"
  [ "$program" = eval ] || return 0
  # A non-literal eval word can expand to nothing, so the literal words after
  # it can form the whole source.
  for ((cursor=source_pos; cursor<${#args[@]}; cursor++)); do
    [ "${arg_kinds[$cursor]}" != literal ] || continue
    source=""; text=""
    for ((later=cursor+1; later<${#args[@]}; later++)); do
      [ "${arg_kinds[$later]}" = literal ] || continue
      # eval then takes a leading -- as its own separator.
      [ -n "$source" ] || [ "${args[$later]}" != -- ] || continue
      source=$source$text${args[$later]}; text=' '
    done
    [ -z "$source" ] || environment_queue "$source"
  done
  return 0
}

environment_dump() { # command kind; arguments are already decoded data
  local LC_ALL=C i=0 c next quote="" word="" active="" kind=literal compound="" bare=1 quoted=""
  local j start=0 end n fd redirection_kind target proc output input_redirect input_escaped pos program value named flags
  local mode pattern_count pattern filter_ok stage=0 text text_length span span_re comment_span options_ended null_output syntax_head program_pos stdin_program source_pos script_operand data_source piped_source="" fallback_sources listing language
  local receiver receiver_pattern receiver_option receiver_named
  local candidate limit producer_end code incoming_sources="" file_output file_body head_start script_pos script_string forwarded_argument=""
  local heredoc_op="" heredoc_origin delimiter line remaining doc body found math_depth=0 needs_target=""
  local name_re='^[A-Za-z_][A-Za-z0-9_]*(=.*)?$' declared_re='^[A-Za-z_][A-Za-z0-9_]*(\+?=.*)?$'
  local filter_re='^([A-Za-z_][A-Za-z0-9_]*=?|\^[A-Za-z_][A-Za-z0-9_]*=|\^\([A-Za-z_][A-Za-z0-9_]*(\|[A-Za-z_][A-Za-z0-9_]*)+\)=)$'
  local ordinary_span_re=$'^[^\'"\\\\$`# \t\r\n;|()<>&]+'
  local single_span_re="^[^']+" ansi_span_re="^[^'\\\\]+" double_span_re='^[^"\\$`]+' comment_span_re=$'^[^\n]+'
  local tokens=() kinds=() unquoted_words=() saved_quotes=() closers=() args=() arg_kinds=() arg_unquoted=() stage_args=() stage_kinds=() stage_unquoted=() heredocs=() heredoc_tabs=() heredoc_expand=() heredoc_bodies=() body_ids=() stage_sources=() stage_stdin=() stage_fallback=() executable_texts=() executable_stages=()
  local private_inputs=()
  local starts=() ends=() separators=() decisions=() literal_inputs=() input_bodies=() executable_contexts=()
  if [ "${2:-}" = forwarded ]; then
    forwarded_argument=1
    set -- "$1" conservative "${@:3}"
  fi
  [ "${2:-}" != conservative ] || compound=1
  if [ "$1" = argv ]; then
    tokens=(${command_argv[@]+"${command_argv[@]}"})
    for ((i=0; i<${#tokens[@]}; i++)); do kinds[i]=literal; unquoted_words[i]=""; done
  else
    [ "$1" != expansions ] || quote='"'
    text=$command_text
    text_length=${#text}
    while [ "$i" -lt "$text_length" ]; do
      [ "$1" != expansions ] || [ "${#closers[@]}" -ne 0 ] || kind=heredoc-data
      case "$quote" in
        "'") span_re=$single_span_re ;;
        ansi) span_re=$ansi_span_re ;;
        '"') span_re=$double_span_re ;;
        *) span_re=$ordinary_span_re ;;
      esac
      # Copy literal spans once. Marker handlers keep the quote and routing
      # decisions; growing a word byte by byte exceeds the hook budget.
      if [[ ${text:$i} =~ $span_re ]]; then
        span=${BASH_REMATCH[0]}; word=$word$span; active=1
        i=$((i + ${#span}))
        continue
      fi
      c=${text:$i:1}; i=$((i + 1)); next=${text:$i:1}
      if [ "$quote" = ansi ]; then
        case "$c" in
          "'") quote="" ;;
          '\') kind=ansi-escaped; word=$word$c$next; i=$((i + 1)) ;;
          *) word=$word$c ;;
        esac
        continue
      fi
      if [ "$quote" = "'" ]; then
        if [ "$c" = "'" ]; then quote=""; else word=$word$c; fi
        continue
      fi
      if [ "$c" = '\' ]; then
        if [ "$i" -ge "$text_length" ]; then kind=unknown; break; fi
        i=$((i + 1))
        [ "$next" = $'\n' ] || { bare=""; quoted=1; }
        if [ "$quote" = '"' ]; then
          case "$next" in '"' | '\' | '$' | '`' | $'\n') ;; *) word=$word$c ;; esac
        fi
        [ "$next" = $'\n' ] || { word=$word$next; active=1; }
        continue
      fi
      # A substitution's known producer must remain visible inside double
      # quotes. Saving only the enclosing quote grants no inner permission.
      if { [ "$c" = '$' ] && [ "$next" = '(' ]; } || [ "$c" = '`' ]; then
        if [ -n "$active" ]; then unquoted_words[${#tokens[@]}]=$bare; tokens[${#tokens[@]}]=$word; kinds[${#kinds[@]}]=$kind; fi
        word=""; active=""; kind=literal; bare=1; quoted=""; compound=1; needs_target=""
        n=${#closers[@]}
        if [ "$c" = '`' ] && [ "$n" -gt 0 ] && [ "${closers[$((n - 1))]}" = '`' ]; then
          quote=${saved_quotes[$((n - 1))]}; unset 'closers[n-1]' 'saved_quotes[n-1]'
        else
          saved_quotes[n]=$quote; quote=""
          if [ "$c" = '$' ]; then
            [ "${text:$((i + 1)):1}" != '(' ] || math_depth=$((n + 1))
            closers[n]=')'; i=$((i + 1))
          else closers[n]='`'; fi
        fi
        [ -z "$quote" ] || bare=""
        unquoted_words[${#tokens[@]}]=""
        tokens[${#tokens[@]}]=';'; kinds[${#kinds[@]}]=operator
        continue
      fi
      if [ "$quote" = '"' ]; then
        if [ "$c" = '"' ] && { [ "$1" != expansions ] || [ "${#closers[@]}" -ne 0 ]; }; then quote=""; else word=$word$c; [ "$c" != '$' ] || [ "$kind" = ansi-escaped ] || kind=unknown; fi
        continue
      fi
      case "$c" in
        "'" | '"') quote=$c; active=1; bare=""; quoted=1; continue ;;
        '$')
          case "$next" in
            "'" | '"')
              quoted=1; quote=$next; [ "$next" != "'" ] || quote=ansi
              # Dollar arguments keep their conservative kind. Only the
              # existing command-head selector can use the literal word.
              [ "$kind" != literal ] || kind=dollar-literal
              i=$((i + 1)) ;;
            *) [ "$kind" = ansi-escaped ] || kind=unknown; word=$word$c ;;
          esac
          active=1; bare=""; continue ;;
        '#')
          if [ -z "$active" ]; then
            if [[ ${text:$i} =~ $comment_span_re ]]; then
              comment_span=${BASH_REMATCH[0]}; i=$((i + ${#comment_span}))
            fi
            continue
          fi ;;
      esac
      case "$c" in
        ' ' | $'\t' | $'\r' | $'\n' | ';' | '&' | '|' | '(' | ')' | '<' | '>')
          redirection_kind=operator
          if [ -n "$heredoc_op" ] && [ -n "$active" ]; then
            [ "$kind" != ansi-escaped ] || { dump_reason=undecoded-ansi-escape; return 0; }
            doc=${#heredocs[@]}
            heredocs[doc]=$word; heredoc_tabs[doc]=$heredoc_op
            heredoc_expand[doc]=""; [ -n "$quoted" ] || heredoc_expand[doc]=1
            body_ids[$heredoc_origin]=$doc
            heredoc_op=""
          # A numeric target remains operand data before a compact redirect.
          # Only a bare word outside that target can establish a descriptor.
          elif [ -z "$needs_target" ] && { [ "$c" = '<' ] || [ "$c" = '>' ]; } && [ -n "$active" ] &&
               [ -n "$bare" ] && [ "$kind" = literal ] && [[ $word =~ ^[0-9]+$ ]]; then
            redirection_kind=operator-explicit-other
            [ "$word" != 2 ] || redirection_kind=operator-stderr
            active=""
          fi
          if [ -n "$active" ]; then
            unquoted_words[${#tokens[@]}]=$bare; tokens[${#tokens[@]}]=$word; kinds[${#kinds[@]}]=$kind
            needs_target=""
          fi
          word=""; active=""; kind=literal; bare=1; quoted=""
          case "$c" in ' ' | $'\t' | $'\r') continue ;; esac
          case "$c" in
            '(') compound=1; n=${#closers[@]}; saved_quotes[n]=""; closers[n]=')'; c=';' ;;
            ')')
              compound=1; n=${#closers[@]}
              if [ "$n" -gt 0 ]; then quote=${saved_quotes[$((n - 1))]}; unset 'closers[n-1]' 'saved_quotes[n-1]'; fi
              [ "${#closers[@]}" -ge "$math_depth" ] || math_depth=0
              [ -z "$quote" ] || bare=""
              c=';' ;;
            $'\n')
              c=';'
              # Keep every declared body in order. Quoting controls outer
              # expansion; the receiving program decides execution later.
              for ((doc=0; doc<${#heredocs[@]}; doc++)); do
                [ -z "${heredoc_bodies[$doc]+present}" ] || continue
                delimiter=${heredocs[$doc]}; body=""; found=""
                while [ "$i" -lt "$text_length" ]; do
                  remaining=${text:$i}; line=${remaining%%$'\n'*}
                  i=$((i + ${#line})); [ "$i" -ge "$text_length" ] || i=$((i + 1))
                  if [ "${heredoc_tabs[$doc]}" = '<<-' ]; then
                    while [[ $line == $'\t'* ]]; do line=${line:1}; done
                  fi
                  if [ "$line" = "$delimiter" ]; then found=1; break; fi
                  body=$body$line$'\n'
                done
                [ -n "$found" ] || return 0
                heredoc_bodies[doc]=$body
              done ;;
            *)
              case "$c$next" in
                '&&' | '||' | '>>' | '>&' | '<&' | '<>' | '&>' | '<<') c=$c$next; i=$((i + 1)) ;;
                # A pipe followed by & also sends stderr down that pipe.
                \|\&) i=$((i + 1)) ;;
              esac
              if [ "$c" = '&>' ] && [ "${text:$i:1}" = '>' ]; then c=$c'>'; i=$((i + 1)); fi
              if [ "$c" = '<<' ] && [ "${text:$i:1}" = '<' ]; then c='<<<'; i=$((i + 1)); fi
              if [ "$c" = '<<' ] && [ "$math_depth" -eq 0 ]; then
                compound=1
                if [ "${text:$i:1}" = - ]; then c='<<-'; i=$((i + 1)); fi
                heredoc_op=$c; heredoc_origin=${#tokens[@]}
              fi ;;
          esac
          unquoted_words[${#tokens[@]}]=""; tokens[${#tokens[@]}]=$c
          if [ "$c" = '<<' ] && [ "$math_depth" -ne 0 ]; then kinds[${#kinds[@]}]=arithmetic
          else
            kinds[${#kinds[@]}]=$redirection_kind
            case "$c" in '<'* | '>'* | '&>'*) needs_target=1 ;; *) needs_target="" ;; esac
          fi ;;
        *) word=$word$c; active=1 ;;
      esac
    done
    [ -z "$quote" ] && [ "${#closers[@]}" -eq 0 ] || compound=1
    if [ -n "$active" ]; then unquoted_words[${#tokens[@]}]=$bare; tokens[${#tokens[@]}]=$word; kinds[${#kinds[@]}]=$kind; fi
  fi
  # A shell can end a submission before a registered body is read. Evidence
  # must exist before its identifier reaches either expansion or input checks.
  [ -z "$heredoc_op" ] || return 0
  # A forwarded local body cannot gain permission from a later receiver.
  # Check its complete source before expansion or input interpretation.
  if [ -n "$forwarded_argument" ] && [ "${#heredocs[@]}" -gt 0 ] &&
     environment_main_evidence "$text" "${@:3}"; then return 0; fi
  for ((doc=0; doc<${#heredocs[@]}; doc++)); do
    [ -n "${heredoc_bodies[$doc]+present}" ] || return 0
    [ -z "${heredoc_expand[$doc]}" ] || {
      local command_text=${heredoc_bodies[$doc]:-}
      if [ "$#" -ge 3 ]; then
        if environment_dump expansions conservative "${@:3}"; then return 0; fi
      else
        if environment_dump expansions conservative; then return 0; fi
      fi
    }
  done
  literal_inputs=(${heredoc_bodies[@]+"${heredoc_bodies[@]}"})
  for ((doc=3; doc<=$#; doc++)); do
    n=${#literal_inputs[@]}; literal_inputs[n]=${!doc}
    incoming_sources="$incoming_sources $n"
  done
  n=${#tokens[@]}
  for ((i=0; i<=n; i++)); do
    if [ "$i" -lt "$n" ]; then
      [ "${kinds[$i]}" = operator ] || continue
      case "${tokens[$i]}" in '|' | ';' | '&&' | '||' | '&') ;; *) continue ;; esac
    fi
    starts[stage]=$start; ends[stage]=$i
    separators[stage]=${tokens[$i]:-end}; stage=$((stage + 1)); start=$((i + 1))
  done
  for ((stage=0; stage<${#starts[@]}; stage++)); do
    start=${starts[$stage]}; end=${ends[$stage]}; args=(); arg_kinds=(); arg_unquoted=()
    private_inputs=(); proc=""; output=""; input_redirect=""; input_escaped=""; mode=other; program=""; program_pos=""; data_source=""; fallback_sources=""; file_output=""; file_body=""
    for ((j=start; j<end; j++)); do
      case "${kinds[$j]}" in operator | operator-stderr | operator-explicit-other)
        fd=${kinds[$j]}
        j=$((j + 1)); target=${tokens[$j]:-}
        case "${tokens[$((j - 1))]}" in
          '<' | '<>')
            input_redirect=1
            private_inputs[${#private_inputs[@]}]=$target
            [ "${kinds[$j]:-}" != ansi-escaped ] || input_escaped=1
            [[ $target != /proc/*/environ ]] || proc=1
            [ "${tokens[$((j - 1))]}" != '<>' ] || output=1 ;;
          '<&') input_redirect=1 ;;
          '<<' | '<<-')
            input_redirect=1
            doc=${body_ids[$((j - 1))]:-}
            [ -n "$doc" ] || return 0
            if [ "$fd" = operator ] && [ "${tokens[$((j - 1))]}" = '<<' ] &&
               [ "${kinds[$j]:-}" = literal ]; then
              file_body=1; [ -z "${heredoc_expand[$doc]}" ] || file_body=expanding
            fi
            data_source="$data_source $doc" ;;
          '<<<')
            input_redirect=1; doc=${#literal_inputs[@]}; literal_inputs[doc]=$target
            data_source="$data_source $doc" ;;
          '>')
            [ "$fd" = operator-stderr ] || output=1
            if [ "$fd" = operator ] && [ "${kinds[$j]:-}" = literal ]; then file_output=1; fi ;;
          '>>')
            [ "$fd" = operator-stderr ] || output=1
            if [ "$fd" = operator ] && [ "${kinds[$j]:-}" = literal ]; then file_output=append; fi ;;
          '>&') [ "$fd" = operator-stderr ] || output=1 ;;
          '&>' | '&>''>') output=1 ;;
        esac
        continue ;;
      esac
      n=${#args[@]}
      args[n]=${tokens[$j]}; arg_kinds[n]=${kinds[$j]}; arg_unquoted[n]=${unquoted_words[$j]}
    done
    environment_head "$1"
    [ -z "$syntax_head" ] || compound=1
    if [ "$pos" -ge "${#args[@]}" ]; then
      program=opaque
    fi
    environment_producer "$1"
    # A /proc environ input only these readers' arms can classify. Any other
    # program, such as a shell reading its descriptors, can print it.
    case "$program" in cat | strings | tr | xargs) ;; *) [ -z "$proc" ] || mode=dump-unknown ;; esac
    environment_program_text
    # Supported shell source keeps this classification check in its queue.
    # Other unclassified forwarded argv retains the complete read evidence.
    if [ "$mode" = unclassified-forwarded ]; then
      mode=other
      if [ -z "$stdin_program" ] && environment_main_evidence "${args[@]}"; then mode=dump-unknown; fi
    fi
    # Forwarded operands: a shell's script operand, or the word after exec or
    # builtin, which take no option grammar here. A command string, unlike a
    # script file, can run its first forwarded word, $0, as shell text.
    script_pos=$script_operand; script_string=$source_pos
    if [ "$program" = opaque ] && [ -n "$program_pos" ]; then
      case "${args[$program_pos]}" in exec | builtin) script_pos=$program_pos; script_string="" ;; esac
    fi
    # Keep pipe input before the body checks: an opaque receiver can execute it.
    if [ "$stage" -gt 0 ] && [ "${separators[$((stage - 1))]}" = '|' ]; then
      data_source="$data_source$piped_source"
    fi
    # The approved data and file-writing classes are data. Every other
    # heredoc body an unknown receiver gets is judged alone as shell source
    # below. A here-string is judged only here, for an opaque stage, and as
    # a shell's input.
    for doc in $data_source; do
      # Input to exec, builtin or a syntax-only stage, piped input included,
      # can reach an interpreter as well as run as shell text.
      if [ "$program" = opaque ]; then
        for language in python node ruby perl; do
          if environment_receiver_evidence "$language" "${literal_inputs[$doc]}"; then return 0; fi
        done
      fi
      [ "$doc" -lt "${#heredocs[@]}" ] || continue
      if [ -z "${2:-}$incoming_sources" ] && [ "$1" = shell ] &&
         [ "$receiver" = data ] && [ "$mode" = other ] && [ "${#args[@]}" -eq 1 ] &&
         [ "$file_output" = 1 ] && [ "$file_body" = 1 ] &&
         [ "$program_pos" = 0 ] && [ "$head_start" -eq 0 ] && [ "${arg_kinds[0]}" = literal ] &&
         [ "$data_source" = " $doc" ]; then continue; fi
      if [ "$1" = shell ] && [ -z "${2:-}$incoming_sources" ] &&
         [ "$mode" = other ] && [ -z "$stdin_program" ]; then
        case "$receiver" in
          interpreter)
            if environment_receiver_evidence "$program" "${literal_inputs[$doc]}"; then return 0; fi
            continue ;;
          data)
            if [ "${#heredocs[@]}" -eq 1 ] && [ "$data_source" = " 0" ] &&
               [ "$program_pos" = 0 ] && [ "$head_start" -eq 0 ] && [ "${arg_kinds[0]}" = literal ] &&
               { [ "$file_body" = 1 ] || { [ -z "$input_redirect" ] && [ -n "$piped_source" ] &&
                 [ -z "${heredoc_expand[$doc]}" ] && [ "${heredoc_tabs[$doc]}" = '<<' ]; }; }; then continue; fi ;;
        esac
      fi
      [ -n "$stdin_program" ] || fallback_sources="$fallback_sources $doc"
    done
    stage_stdin[stage]=$stdin_program; stage_sources[stage]=$data_source; stage_fallback[stage]=$fallback_sources
    if [ -n "$script_pos" ]; then
      case "$mode" in dump-*) return 0 ;; esac
      stage_args=(${args[@]+"${args[@]}"}); stage_kinds=(${arg_kinds[@]+"${arg_kinds[@]}"})
      stage_unquoted=(${arg_unquoted[@]+"${arg_unquoted[@]}"})
      for ((candidate=script_pos+1; candidate<${#stage_args[@]}; candidate++)); do
        # The approved ordinary quoted-data class has the same recorded
        # receiver, head and argument bounds. It recognizes no inner words.
        if [ "$1" = shell ] && [ -z "${2:-}$compound" ] && [ "$program" = bash ] && [ -z "$source_pos" ] && [ -z "$syntax_head" ] &&
           [ "${#stage_args[@]}" -eq 3 ] && [ "$candidate" -eq 2 ] && [ "${#starts[@]}" -eq 1 ] &&
           [ "$start" -eq 0 ] && [ "$end" -eq 3 ] && [ "${stage_kinds[1]}" = literal ] &&
           [ "$program_pos" = 0 ] && [ "${stage_kinds[$candidate]}" = literal ] &&
           [ -z "${stage_unquoted[$candidate]}" ] && [ -z "$input_redirect$output" ]; then continue; fi
        # Waiter launchers execute forwarded argv, so each operand is judged
        # as a possible head by the one producer, beside its own operands.
        limit=${#stage_args[@]}
        args=("${stage_args[@]:candidate:limit-candidate}")
        arg_kinds=("${stage_kinds[@]:candidate:limit-candidate}")
        arg_unquoted=("${stage_unquoted[@]:candidate:limit-candidate}")
        program=""; pos=0; mode=other; producer_end=0; program_pos=""
        environment_producer shell
        environment_program_text
        [ -z "$stdin_program" ] || stage_stdin[stage]=1
        case "$mode" in dump-*) return 0 ;; esac
        # A quoted operand past the program can be a whole command string,
        # and so can an expanding one, whose producer selection stops at 0;
        # after a command string, every quoted operand can be, $0 included.
        # A legitimate forwarded launcher form refused twice after landing is
        # a design question for this forwarded-form rule, not a case patch
        # (Jarvis ruling, KEN-4728).
        if { [ -n "$script_string" ] || [ "$candidate" -gt "$((script_pos + 1))" ]; } && [ -z "$output" ] &&
           [ -z "${stage_unquoted[$candidate]}" ] && [ "$producer_end" -le 1 ]; then
          code=${#executable_texts[@]}
          executable_texts[code]=${stage_args[$candidate]}; executable_stages[code]=$stage
          executable_contexts[code]=forwarded
        fi
        [ "$producer_end" -le 1 ] || candidate=$((candidate + producer_end - 2))
      done
      mode=opaque-clean
    fi
    case "$mode" in dump-*) [ -z "$output" ] || mode=unrouted ;; esac
    decisions[stage]=$mode
    piped_source=$data_source
  done
  for ((stage=0; stage<${#decisions[@]}; stage++)); do
    data_source=${stage_sources[$stage]}
    data_source="$data_source $incoming_sources"
    input_bodies=()
    for doc in $data_source; do input_bodies[${#input_bodies[@]}]=${literal_inputs[$doc]}; done
    # A command string can start a shell that reads the same stdin.
    for ((code=0; code<${#executable_texts[@]}; code++)); do
      [ "${executable_stages[$code]}" -eq "$stage" ] || continue
      local command_text=${executable_texts[$code]}
      if environment_dump shell "${executable_contexts[$code]:-conservative}" ${input_bodies[@]+"${input_bodies[@]}"}; then return 0; fi
    done
    # A stdin shell runs every body; an unknown receiver may run the ones
    # no data class admitted. These identifiers come only from the proved
    # registry. Keep bodies independent: quotes in one program cannot hide
    # another program.
    [ -n "${stage_stdin[$stage]}" ] || data_source=${stage_fallback[$stage]}
    for doc in $data_source; do
      local command_text=${literal_inputs[$doc]}
      if environment_dump shell conservative; then return 0; fi
    done
  done
  for ((stage=0; stage<${#decisions[@]}; stage++)); do
    case "${decisions[$stage]}" in
      unrouted | dump-unknown) return 0 ;;
      dump-lines | dump-nul)
        [ -z "$compound" ] || return 0
        j=$stage
        if [ "${decisions[$stage]}" = dump-nul ]; then
          if [ "${separators[$j]}" != '|' ] || [ "${decisions[$((j + 1))]:-}" != convert ]; then return 0; fi
          j=$((j + 1))
        fi
        if [ "${separators[$j]}" != '|' ] || [ "${decisions[$((j + 1))]:-}" != filter ]; then return 0; fi ;;
    esac
  done
  return 1
}

# Every line this hook writes, and the only place its text lives. The first
# line is the contract a reader parses, `command-safety: <key>=<value>`: a
# stable key for the condition and the value acted on — the missing tool, why
# the payload could not be read, the state of the project policy, or the exit
# status of a check that did not complete. The English explanation follows it.
# The keyed line stands first, at position 1. What a command this hook runs
# wrote is captured where the hook reads it and passed here as the cause, so
# it is replayed under the key rather than ahead of it.
# The EXIT trap below calls this, so the whole message is one group that
# cannot carry a failure out: a write that fails there would leave with the
# writer's status rather than the refusal's, which the harness runs past.
refuse() { # KEY VALUE [CAUSE]
  loading=""
  {
    printf 'command-safety: %s=%s\n' "$1" "$2"
    case "$1=$2" in
      missing-tools=*) echo "the commands ${2//,/, } are required and are not on PATH" ;;
      payload=unreadable) echo "the hook input could not be read" ;;
    cwd=*) echo "the working directory $2 could not be entered" ;;
      payload=invalid-json) echo "the hook input is not valid JSON, or names no command this hook can read" ;;
      payload=invalid-cwd) echo "the payload's working directory is not a string" ;;
        git=unreadable) echo "the Git working directory could not be resolved" ;;
      hook=unlocatable) echo "this hook's own directory could not be read, so its installed dependencies cannot be found" ;;
      settings=no-loader) echo "the command-safety bundle requires the installed commit-guards settings loader" ;;
      support=unreadable) echo "the installed commit-guards support could not be loaded; repair that installation; its diagnostic follows" ;;
      settings=unreadable) echo "the project settings could not be read, so COMMAND_SAFETY_DENY_PATTERN is unknown; the loader's line below names what to fix" ;;
      settings=empty) echo "COMMAND_SAFETY_DENY_PATTERN must be configured" ;;
      settings=invalid-pattern) echo "COMMAND_SAFETY_DENY_PATTERN is not a readable POSIX ERE" ;;
      refused=policy) echo "the command text matches this project's COMMAND_SAFETY_DENY_PATTERN" ;;
      refused=environment-dump)
        # An undecoded escape is refused as unknown, not as a recognized read,
        # so it gets its own reason and remedy.
        if [ -n "${dump_reason:-}" ]; then
          printf 'command-safety: reason=%s\n' "$dump_reason"
          echo "the shell runs a word holding an ANSI-C escape, a backslash inside \$'...', and this check does not decode those escapes"
          echo "decode the escape in the command text, or pass the value as a literal argument"
        else
          echo "the command contains a recognized private-file read or a whole-environment read without a proven direct named-variable filter"
          echo "for named non-secret settings, use orch-env NAME DEFAULT; do not read or filter the private file"
          echo "for actual environment producers, read named variables, for example: systemctl --user show-environment | grep '^NAME='"
          echo "nested or unsupported environment routing can refuse conservatively; use the direct filtered form for environment producers"
        fi ;;
      refused=default-policy)
        echo "the command text sets a systemd-run MemoryMax= or MemoryHigh= cap in kilobytes or megabytes, which the hook's default COMMAND_SAFETY_DENY_PATTERN refuses: a cgroup starved by a cap that small can fail a kernel allocation and leave the host's root volume read-only"
        echo "run it with no memory cap, or with a cap in gigabytes; text that only mentions such a cap goes in a file, because matching reads the command text"
        echo "a project that wants another pattern sets COMMAND_SAFETY_DENY_PATTERN in kendex.settings.toml [env] to replace the default, and the value \"^\$\" turns only project-pattern matching off; the fixed environment-dump refusal remains active" ;;
      exit=*) echo "the command safety check could not complete" ;;
    esac
    # The cause a command this hook ran wrote, captured at the site and
    # replayed here: under the keyed line, never ahead of it.
    [ -z "${3:-}" ] || printf '%s\n' "$3"
  } >&2 || :
  case "$1" in
    refused | path) exit 2 ;;
    *)
      echo "Check skipped. Repair the hook installation, tools or payload adapter; retry the command." >&2
      exit 0 ;;
  esac
}
# An exit that is neither a verdict (0) nor a refusal (2) is a check that did
# not complete, and it leaves with a warning. The EXIT trap is what reaches every
# such exit on Bash 3.2 too: an ERR trap inherited through `set -E` fires there
# inside a command substitution even when the substitution stands on the left
# of `||`, which reads the settings loader's guarded probes as failures.
# Support can explicitly exit with a guard's verdict status. While sourcing,
# that status is a support failure, not an executable-command refusal.
loading=""
trap '
  rc=$?
  if [ -n "$loading" ]; then
    cause=$loading
    while IFS= read -r detail <&5 || [ -n "$detail" ]; do
      cause="$cause
  $detail"
    done
    refuse support unreadable "$cause" 2>&3
  fi
  case $rc in 0 | 2) ;; *) refuse exit "$rc" ;; esac
' EXIT
MISSING=""
for dependency in jq git grep cat dirname mktemp rm; do
  command -v "$dependency" >/dev/null 2>&1 || MISSING="$MISSING,$dependency"
done
if ! command -v jq >/dev/null 2>&1 || ! command -v cat >/dev/null 2>&1; then
  refuse missing-tools "${MISSING#,}"
fi
input="$(cat 2>&1)" || refuse payload unreadable "$input"
fields="$(jq -er '
  def command_arg:
    if type == "object" then (.command // .cmd)
    elif type == "string" then
      (try fromjson catch null)
      | if type == "object" then (.command // .cmd) else null end
    else null end;
  . as $payload
  | [.tool_input.command, .tool_input.cmd, (.toolArgs | command_arg), .command, .cmd]
  | map(select(. != null))
  | if length == 0 then error("missing command") else .[0] end
  | . as $submitted
  | if type == "string" then .
    elif type == "array" and all(.[]; type == "string") then join(" ")
    else error("invalid command") end
  | sub("\n+$"; "") as $command
  | (if $payload.cwd != null and ($payload.cwd | type) != "string" then "invalid-cwd" else "valid-cwd" end) as $cwd_state
  | [(if $cwd_state == "invalid-cwd" then "" else ($payload.cwd // "" | sub("\n+$"; "")) end),
     $command, $cwd_state,
     (if ($submitted | type) == "array" then "argv" else "shell" end),
     (if ($submitted | type) == "array" then ($submitted | length), $submitted[] else 0 end)] | @tsv
' <<<"$input" 2>/dev/null)" || refuse payload invalid-json
[ -n "$fields" ] || exit 0
# TSV escapes tabs, newlines and backslashes, so only the field boundary is
# a literal tab. Read each field once instead of repeatedly copying and
# matching the remaining line. printf decodes data without shell evaluation.
# Bash 3.2 can unset the target of an empty %b assignment. Keep empty fields
# as ordinary assignments and decode only nonempty text.
{
  IFS= read -r -d $'\t' cwd || refuse payload invalid-json
  IFS= read -r -d $'\t' command_text || refuse payload invalid-json
  [ -n "$command_text" ] || exit 0
  [ -z "$cwd" ] || printf -v cwd '%b' "$cwd"
  printf -v command_text '%b' "$command_text"
  IFS= read -r -d $'\t' cwd_state || refuse payload invalid-json
  IFS= read -r -d $'\t' command_kind || refuse payload invalid-json
  IFS= read -r -d $'\t' argument_count || refuse payload invalid-json
  command_argv=()
  for ((argument_index=0; argument_index<argument_count; argument_index++)); do
    IFS= read -r -d $'\t' argument || refuse payload invalid-json
    [ -z "$argument" ] || printf -v argument '%b' "$argument"
    command_argv[argument_index]=$argument
  done
} <<<"$fields"$'\t'
# Set by the escape arms, which refuse what they cannot decode.
dump_reason=""
if environment_dump "$command_kind"; then
  refuse refused environment-dump
fi
[ "$cwd_state" != invalid-cwd ] || refuse payload invalid-cwd
[ -z "$MISSING" ] || refuse missing-tools "${MISSING#,}"
[ -n "$cwd" ] || cwd="$PWD"
# The requested path is kept: the substitution below holds cd's own words when
# the directory cannot be entered, and the physical path when it can, so the
# refusal names the path it was asked for and replays the cause under it.
requested_cwd="$cwd"
cwd="$(cd -- "$cwd" 2>&1 && pwd -P)" || refuse cwd "$requested_cwd" "$cwd"
# git's words come back in place of the path when it cannot answer, so the
# refusal below has the cause to replay: which .git entry it could not read.
root_status=0
root="$(git -C "$cwd" rev-parse --show-toplevel 2>&1)" || root_status=$?
if [ "$root_status" -ne 0 ]; then
  at="$cwd"
  while [ "$at" != / ]; do
    if [ -e "$at/.git" ] || [ -L "$at/.git" ]; then
      refuse git unreadable "$root"
    fi
    at="${at%/*}"
    [ -n "$at" ] || at=/
  done
  exit 0
fi

lib=
hook_dir="$(cd -- "${BASH_SOURCE[0]%/*}" && pwd)" || refuse hook unlocatable
at="$hook_dir"
levels=0
# Registered hook layouts keep the scope's skills one or two directories
# above hooks. A wider walk can reach executable files outside the install.
while [ "$levels" -lt 3 ] && [ "$at" != "$root" ] && [ "$at" != / ]; do
  candidate="$at/skills/commit-guards/scripts/lib"
  if [ -f "$candidate/common.sh" ] && [ -f "$candidate/settings.sh" ]; then
    lib="$candidate"
    break
  fi
  at="${at%/*}"
  [ -n "$at" ] || at=/
  levels=$((levels + 1))
done
if [ -z "$lib" ]; then
  # Choose the shared scope once. A global hook can use HOME's installed
  # dependency, but cannot source a project selected by the payload.
  case "$hook_dir" in
    "$root"/*) lib="$root/.agents/skills/commit-guards/scripts/lib" ;;
    *) lib="${HOME:+$HOME/.agents/skills/commit-guards/scripts/lib}" ;;
  esac
fi
[ -f "$lib/common.sh" ] && [ -f "$lib/settings.sh" ] || refuse settings no-loader
GG_CHECK=command-safety
# Keep nested support reads under errexit. A source on the left of || would
# continue past a failed nested import. EXIT owns the advisory outcome, and
# its saved stderr survives the source command's diagnostic redirection.
exec 3>&2
# Capture installed support's stderr in an owned file. Open separate write and
# read descriptions before unlinking it; EXIT can read from the beginning even
# while source's stderr redirection remains active. Process exit owns teardown.
support_capture=$(mktemp 2>&1) || refuse support unreadable "$support_capture"
exec 4>"$support_capture" 5<"$support_capture"
capture_err=$(rm -- "$support_capture" 2>&1) || refuse support unreadable "$capture_err"
loading="$lib/common.sh"
# shellcheck source=../skills/commit-guards/scripts/lib/common.sh
source "$lib/common.sh" 2>&4
loading="$lib/settings.sh"
# shellcheck source=../skills/commit-guards/scripts/lib/settings.sh
source "$lib/settings.sh" 2>&4
loading=""
exec 3>&- 4>&- 5<&-
# cd runs twice on purpose: a substitution cannot move this shell, so the
# probe is what carries the cause into the refusal and the second one is the
# move. The second failure is unreachable in practice — the probe just
# succeeded — and refuses without a cause rather than not at all.
if ! ROOT_ERR=$( (cd -- "$root") 2>&1 ); then
  refuse cwd "$root" "$ROOT_ERR"
fi
cd -- "$root" || refuse cwd "$root"
# The loader's diagnostic is captured, not left to precede the refusal: on
# failure the substitution holds the loader's keyed line — for a value in
# another shape, the file, the line and the key — and a successful read is
# silent, so the pattern is not mixed with a diagnostic.
# A failed whole-table settings read warns; the shell call remains available
# so the operator can repair that file.
# The default is the host-safety rule every install gets: a systemd-run memory
# cap in K or M starved a build's cgroup into a kernel allocation failure that
# left a host's root volume read-only. skills/commit-guards'
# kendex.settings.toml.example declares the same value.
default_pattern='(^|[^[:alnum:]_-])systemd-run[[:space:]][^&;|]*Memory(Max|High)=[[:punct:]]?[0-9]+[KkMm]([^[:alnum:]]|$)'
pattern="$(gg_setting COMMAND_SAFETY_DENY_PATTERN "$default_pattern" 2>&1)" || refuse settings unreadable "$pattern"
[ -n "$pattern" ] || refuse settings empty
[ "$pattern" != '^$' ] || exit 0
status=0
# Shell line continuations can split a denied command or token. Keep the raw
# text too: single quotes preserve backslash-newline pairs as literal text.
# Bash 3.2 needs ANSI-C quoting expanded before the replacement pattern.
continuation=$'\\\n'
joined_command_text="${command_text//"$continuation"/}"
# grep's words on a pattern it cannot read are captured: stderr becomes the
# substitution's stdout and grep's own stdout is discarded, so the status still
# decides and the cause reaches the refusal below its keyed line.
GREP_ERR=$(printf '%s\n' "$command_text" "$joined_command_text" | LC_ALL=C grep -E -- "$pattern" 2>&1 >/dev/null) || status=$?
case "$status" in
  0)
    # The default's reason and remedy are known here; a project pattern's are
    # its own. A project that sets the default's own value refuses for the
    # default's reason, so it gets the default's text.
    if [ "$pattern" = "$default_pattern" ]; then
      refuse refused default-policy
    fi
    refuse refused policy
    ;;
  1) exit 0 ;;
  *) refuse settings invalid-pattern "$GREP_ERR" ;;
esac
