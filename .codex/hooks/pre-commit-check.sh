#!/usr/bin/env bash
# ---
# name: pre-commit-check
# event: PreToolUse
# matcher: Bash
# description: Defers commits to executable, marked pre-commit and commit-msg hooks in the working repository. Refuses a literal bypass option or core.hooksPath override on a direct git commit call. Also refuses the commit's own literal bypass flag after a core.hooksPath write or unset in the same command, and names the separate-command remedy. Reads quoted words, comments, command boundaries and option values without executing shell text. Messages, path operands and other programs' arguments are not options. Unarmed repositories get a consent notice; linked worktrees get a main-owner setup route. Unavailable tools, unreadable payloads and commands this reader cannot resolve get a notice as harness context and allow the command. This hook never runs repository setup or check scripts.
# summary: Stops options that skip armed commit checks and bypass commits after a hook-path change in the same command. Missing setup or an unavailable reader produces a notice with the responsible owner.
# safety: Reads JSON, literal shell words and Git hook files. Executes no command from the payload and no repository script. Quoted message and file expansions are kept as single argument values without execution. Unresolved argument boundaries and unclosed quotes are reported and allowed; indirect launches are outside the literal direct-call check. Git's installed hooks enforce checks when the hook cannot read a command. The working repository alone is judged; repository-moving commits get a notice when the working directory has no readable Git hook directory. Every diagnostic starts with pre-commit-check: key=value.
# timeout: 60
# ---

set -euo pipefail

MARKER="# kendex-guards-hook"
NOTICE=""
trap notice_output EXIT

message_text() { # KEY VALUE [CAUSE]
  printf 'pre-commit-check: %s=%s\n' "$1" "$2"
  case "$1" in
    missing-tools)
      echo "The hook reader is unavailable. The machine operator must provide ${2//,/, }. This command is allowed; no hook verdict is available." ;;
    payload)
      echo "The hook cannot read the tool payload. This command is allowed. Report a repeated payload failure to the hook author; the machine operator must repair an unavailable reader." ;;
    command)
      echo "The hook cannot resolve this shell form without execution. This command is allowed; Git's installed hooks remain responsible for commit checks." ;;
    bypass)
      if [ -n "${SAME_COMMAND:-}" ]; then
        echo "Run the configuration change and the commit as separate commands. This command changes core.hooksPath before a commit that skips checks."
      else
        echo "This option skips the repository's armed commit checks. Remove the option and commit with the installed hooks."
      fi ;;
    unarmed)
      echo "Commit checks are not armed in $2. This command is allowed. Repository setup requires a person's consent before repository scripts run." ;;
    setup)
      if [ "$2" = consent ]; then
        echo "Ask the repository owner for consent. After consent, use the tracked commit-guards installer from the repository root, or kendex guard install. Use kendex guard check to inspect setup."
      else
        echo "Ask the owner of the main checkout at $2 to set up commit checks after consent. An item lane must not change shared hook setup."
      fi ;;
    judged)
      echo "The command moves repositories. Only $2 was inspected. The target repository's own hooks must check its commits." ;;
  esac
  [ -z "${3:-}" ] || printf '%s\n' "$3"
}

# Successful stderr is hidden from the model. Match the installed hook's
# context channel, as block-worktree-refresh::library_gap does. Builtins own
# serialization here because this notice also reports missing or broken jq.
message() { # KEY VALUE [CAUSE]
  local text
  text=$(message_text "$@")
  printf '%s\n' "$text" >&2
  [ "$1" != bypass ] || return 0
  NOTICE="${NOTICE:+$NOTICE$'\n'}$text"
}

notice_output() {
  local encoded bs=\\ q='"' octal char escaped
  [ -n "$NOTICE" ] || return 0
  local text=$NOTICE
  encoded=${text//"$bs"/"$bs$bs"}
  encoded=${encoded//"$q"/"$bs$q"}
  for octal in 001 002 003 004 005 006 007 010 011 012 013 014 015 016 017 \
      020 021 022 023 024 025 026 027 030 031 032 033 034 035 036 037; do
    printf -v char '%b' "\\0$octal"
    printf -v escaped '\\u%04x' "0$octal"
    encoded=${encoded//"$char"/$escaped}
  done
  case "${BASH_SOURCE[0]}" in
    */.github/hooks/*) printf '{"additionalContext":"%s"}\n' "$encoded" ;;
    *)
      if [ -f "${BASH_SOURCE[0]%.sh}.json" ]; then
        printf '{"additionalContext":"%s"}\n' "$encoded"
      else
        printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"%s"}}\n' "$encoded"
      fi ;;
  esac
}

MISSING=""
for dependency in jq cat grep; do
  command -v "$dependency" >/dev/null 2>&1 || MISSING="$MISSING,$dependency"
done
[ -z "$MISSING" ] || { message missing-tools "${MISSING#,}"; exit 0; }
INPUT=$(cat 2>&1) || { message payload read-failed "$INPUT"; exit 0; }
COMMAND=$(printf '%s' "$INPUT" | jq -r '
  def copilot: .toolArgs
    | if . == null then null elif type == "string" then fromjson else . end
    | if . == null then null elif type == "object" then .command else error end;
  if .tool_input.command != null then .tool_input.command
  elif .command != null then .command
  elif copilot != null then copilot else "" end
  | if type == "string" then . else error end' 2>/dev/null) ||
  { message payload invalid-json; exit 0; }


# A literal executable name may join quoted and escaped pieces. Removing
# that syntax only selects candidates; the argument reader still decides
# command positions and options. Calls with no git spelling avoid its loop.
CANDIDATE=${COMMAND//\\$'\n'/}
CANDIDATE=${CANDIDATE//\\/}
CANDIDATE=${CANDIDATE//\'/}
CANDIDATE=${CANDIDATE//\"/}
case "$CANDIDATE" in *git*) ;; *) exit 0 ;; esac

# Claude's quoted cat/heredoc message and ordinary quoted substitutions keep
# one argument. Their body is data for this direct-call reader. Quoting and
# heredoc terminators must close before a following Git option can be read.
quoted_expansion() {
  local start=$((i - 1)) depth=1 inner="" c="" closed="" tail delimiter line offset
  case "$char${COMMAND:$i:1}" in
    '$(') i=$((i + 1)) ;;
    '$'*)
      tail=${COMMAND:$i}
      if [[ $tail =~ ^[A-Za-z_][A-Za-z0-9_]* ]]; then
        i=$((i + ${#BASH_REMATCH[0]}))
      elif [[ $tail =~ ^\{[A-Za-z_][A-Za-z0-9_]*\} ]]; then
        i=$((i + ${#BASH_REMATCH[0]}))
      else
        case "${COMMAND:$i:1}" in '@' | '*' | '{') return 1 ;; esac
      fi
      raw="$raw${COMMAND:$start:$((i - start))}"; [ "$kind" = expanded ] || kind=value; return 0 ;;
    '`'*) inner='`'; depth=0 ;;
  esac
  while [ "$i" -lt "${#COMMAND}" ]; do
    c=${COMMAND:$i:1}; i=$((i + 1))
    if [ "$inner" = "'" ]; then
      [ "$c" != "'" ] || inner=""
      continue
    fi
    if [ "$c" = '\' ]; then
      [ "$i" -lt "${#COMMAND}" ] || return 1
      i=$((i + 1)); continue
    fi
    if [ "$inner" = '`' ]; then
      if [ "$c" = '`' ]; then closed=1; break; fi
      continue
    fi
    if [ "$inner" = '"' ]; then
      [ "$c" != '"' ] || inner=""
      # A nested substitution needs another quoting context. Leave its
      # boundaries unavailable rather than treating its quote as our end.
      case "$c${COMMAND:$i:1}" in '$(') return 1 ;; esac
      continue
    fi
    case "$c" in
      "'" | '"') inner=$c ;;
      '(') depth=$((depth + 1)) ;;
      ')') depth=$((depth - 1)); [ "$depth" -ne 0 ] || { closed=1; break; } ;;
      '<')
        [ "${COMMAND:$i:1}" = '<' ] || continue
        tail=${COMMAND:$((i + 1))}
        # The shipped Claude form uses one literal delimiter. More complex
        # redirection syntax stays unavailable instead of guessing its end.
        if [[ $tail =~ ^[[:blank:]]*([\"\']?)([A-Za-z_][A-Za-z0-9_]*)([\"\']?)[[:blank:]]*$'\n' ]]; then
          [ "${BASH_REMATCH[1]}" = "${BASH_REMATCH[3]}" ] || return 1
          delimiter=${BASH_REMATCH[2]}
          i=$((i + 1 + ${#BASH_REMATCH[0]}))
        else return 1; fi
        while [ "$i" -lt "${#COMMAND}" ]; do
          tail=${COMMAND:$i}; line=${tail%%$'\n'*}
          offset=${#line}; i=$((i + offset))
          [ "$i" -ge "${#COMMAND}" ] || i=$((i + 1))
          [ "$line" != "$delimiter" ] || break
        done
        [ "$line" = "$delimiter" ] || return 1 ;;
    esac
  done
  [ -n "$closed" ] || return 1
  raw="$raw${COMMAND:$start:$((i - start))}"; [ "$kind" = expanded ] || kind=value
}

# Keep words and operators distinct, including an empty quoted argument. No
# eval, glob expansion or shell launch may turn payload data into code. Bash
# unquoted expansion and unresolved substitutions need context this hook does not own.
# An unknown argument keeps only its proven prefix. Later literal text cannot
# establish an option name or a short flag before an unknown value boundary.
tokenize() {
  local i=0 char next quote="" word="" active="" raw="" kind=word operator_kind
  READER_STATE=incomplete
  TOKENS=(); KINDS=(); RAW=()
  while [ "$i" -lt "${#COMMAND}" ]; do
    char=${COMMAND:$i:1}
    i=$((i + 1))
    if [ "$quote" = "'" ]; then
      raw="$raw$char"
      if [ "$char" = "'" ]; then quote=""; elif [ "$kind" = word ]; then word="$word$char"; fi
      continue
    fi
    if [ "$char" = '\' ]; then
      [ "$i" -lt "${#COMMAND}" ] || return 1
      next=${COMMAND:$i:1}; i=$((i + 1))
      if [ "$quote" = '"' ]; then
        case "$next" in '"' | '\' | '$' | '`' | $'\n') ;; *) [ "$kind" != word ] || word="$word$char" ;; esac
      fi
      raw="$raw$char$next"
      [ "$next" = $'\n' ] || { [ "$kind" != word ] || word="$word$next"; active=1; }
      continue
    fi
    case "$char" in
      '$' | '`')
        if [ "$quote" = '"' ]; then
          quoted_expansion || return 1
        else
          case "$char${COMMAND:$i:1}" in
            '$(' | '`'*) quoted_expansion || return 1 ;;
            *) [ "$kind" != word ] || word="$word$char"; raw="$raw$char" ;;
          esac
          active=1; kind=expanded
        fi
        continue ;;
    esac
    if [ "$quote" = '"' ]; then
      raw="$raw$char"
      if [ "$char" = '"' ]; then quote=""; elif [ "$kind" = word ]; then word="$word$char"; fi
      continue
    fi
    case "$char" in
      "'" | '"') quote=$char; active=1; raw="$raw$char" ;;
      '#')
        if [ -z "$active" ]; then
          while [ "$i" -lt "${#COMMAND}" ] && [ "${COMMAND:$i:1}" != $'\n' ]; do i=$((i + 1)); done
        else [ "$kind" != word ] || word="$word$char"; raw="$raw$char"; fi ;;
      ' ' | $'\t' | $'\r' | $'\n' | ';' | '&' | '|' | '(' | ')' | '<' | '>')
        case "$word" in
          '' | *[!0-9]*) ;;
          *)
            case "$char" in '<' | '>') [ "$raw" != "$word" ] || active="" ;; esac ;;
        esac
        if [ -n "$active" ]; then
          TOKENS[${#TOKENS[@]}]=$word; KINDS[${#KINDS[@]}]=$kind; RAW[${#RAW[@]}]=$raw
          word=""; raw=""; active=""; kind=word
        fi
        case "$char" in
          ' ' | $'\t' | $'\r') continue ;;
          '<')
            case "${COMMAND:$i:1}" in '<' | '(') return 1 ;; esac ;;
          '>') [ "${COMMAND:$i:1}" != '(' ] || return 1 ;;
        esac
        operator_kind=separator
        case "$char" in
          '<' | '>') operator_kind=redirect ;;
          '&') [ "${COMMAND:$i:1}" != '>' ] || operator_kind=redirect ;;
        esac
        if [ "$operator_kind" = redirect ]; then
          case "$char${COMMAND:$i:1}" in
            '>&' | '<&' | '>>' | '>|' | '&>') char="$char${COMMAND:$i:1}"; i=$((i + 1)) ;;
          esac
          if [ "$char" = '&>' ] && [ "${COMMAND:$i:1}" = '>' ]; then
            char="$char>"; i=$((i + 1))
          fi
        fi
        word=""; raw=""; active=""; kind=word
        TOKENS[${#TOKENS[@]}]=$char; KINDS[${#KINDS[@]}]=$operator_kind; RAW[${#RAW[@]}]=$char ;;
      '*' | '?' | '[' | '{' | '}')
        # Standalone braces delimit command groups. Brace/glob expansion in a
        # word can change argument count, including which option owns a value.
        case "$char" in
          '{' | '}') [ -z "$active" ] && [ "${COMMAND:$i:1}" = ' ' ] || return 1 ;;
          *) [ "$kind" != word ] || word="$word$char"; raw="$raw$char"; active=1; kind=expanded; continue ;;
        esac
        word=$char; raw=$char; active=1 ;;
      *) [ "$kind" != word ] || word="$word$char"; raw="$raw$char"; active=1 ;;
    esac
  done
  [ -z "$quote" ] || return 1
  if [ -n "$active" ]; then
    TOKENS[${#TOKENS[@]}]=$word; KINDS[${#KINDS[@]}]=$kind; RAW[${#RAW[@]}]=$raw
  fi
  # Only a separator or a fully read end completes a call. Tokens from the
  # failing call cannot prove an option; completed calls keep their results.
  TOKENS[${#TOKENS[@]}]=''; KINDS[${#KINDS[@]}]=separator; RAW[${#RAW[@]}]=''
  READER_STATE=complete
}

# Git's documented global and commit option interfaces own these argument
# boundaries. Only -- ends option parsing; Git permits options after paths.
# It never searches option values for a bypass spelling (git-commit and git manuals).
read_call() {
  local i=0 word rest letter value config="" env_config="" verb="" flag="" config_action=set
  local env_count="" prefix_end candidate key_index value_word present word_kind owns_value uncertain="" value_kind unresolved=""
  CALL_RESULT=other; CALL_BYPASS=""; CALL_FLAG=""
  while [ "$i" -lt "${#ARGS[@]}" ]; do
    word=${ARGS[$i]}; word_kind=${ARG_KINDS[$i]}; i=$((i + 1))
    case "$word" in GIT_CONFIG_*) [ "$word_kind" = word ] || uncertain=1 ;; esac
    case "$word" in
      GIT_CONFIG_COUNT=*)
        env_count=""; [ "$word_kind" != word ] || env_count=${word#*=} ;;
      [A-Za-z_]*=*) ;;
      '!' | '{' | '}' | if | then | else | elif | while | until | do | time | -p | command | env) ;;
      *) break ;;
    esac
  done
  [ "${word##*/}" = git ] && [ "${ARG_KINDS[$((i - 1))]}" = word ] || return 0
  prefix_end=$((i - 1))
  # Git ignores KEY/VALUE variables beyond COUNT. A key named in shell data
  # alone is therefore not evidence that this invocation overrides hooks.
  case "$env_count" in '' | *[!0-9]*) ;;
    *)
      for ((candidate=0; candidate<prefix_end; candidate++)); do
        word=${ARGS[$candidate]}
        case "$word" in GIT_CONFIG_KEY_*=*) ;; *) continue ;; esac
        [ "${ARG_KINDS[$candidate]}" = word ] || { uncertain=1; continue; }
        value=${word#*=}; key_index=${word%%=*}; key_index=${key_index#GIT_CONFIG_KEY_}
        case "$key_index" in '' | *[!0-9]*) continue ;; esac
        [ "$key_index" -lt "$env_count" ] 2>/dev/null || continue
        case "$value" in
          [Cc][Oo][Rr][Ee].[Hh][Oo][Oo][Kk][Ss][Pp][Aa][Tt][Hh])
            present=""
            for ((value_word=0; value_word<prefix_end; value_word++)); do
              case "${ARGS[$value_word]}" in
                "GIT_CONFIG_VALUE_$key_index="*)
                  if [ "${ARG_KINDS[$value_word]}" = word ]; then present=1; else uncertain=1; fi ;;
              esac
            done
            [ -z "$present" ] || env_config=${ORIGINAL[$candidate]} ;;
        esac
      done ;;
  esac
  while [ "$i" -lt "${#ARGS[@]}" ]; do
    word=${ARGS[$i]}; i=$((i + 1))
    word_kind=${ARG_KINDS[$((i - 1))]}
    [ "$word_kind" = word ] || { uncertain=1; continue; }
    case "$word" in
      -c | --config-env)
        [ "$i" -lt "${#ARGS[@]}" ] || return 0
        value=${ARGS[$i]}; config=${ORIGINAL[$i]}; value_kind=${ARG_KINDS[$i]}; i=$((i + 1))
        [ "$value_kind" = word ] || { uncertain=1; continue; } ;;
      -c?*) value=${word#-c}; config=${ORIGINAL[$((i - 1))]} ;;
      --config-env=*) value=${word#--config-env=}; config=${ORIGINAL[$((i - 1))]} ;;
      -C | --git-dir | --work-tree | --namespace | --super-prefix)
        i=$((i + 1)); MOVES=1; continue ;;
      --git-dir=* | --work-tree=*) MOVES=1; continue ;;
      -*) continue ;;
      *) verb=$word; break ;;
    esac
    case "${value%%=*}" in
      [Cc][Oo][Rr][Ee].[Hh][Oo][Oo][Kk][Ss][Pp][Aa][Tt][Hh]) env_config=$config ;;
    esac
  done
  if [ "$verb" = config ]; then
    # Git config writes and unsets are command operations, not evidence of
    # the resulting hook setup. Queries and option values remain data.
    while [ "$i" -lt "${#ARGS[@]}" ]; do
      word=${ARGS[$i]}; i=$((i + 1))
      [ "${ARG_KINDS[$((i - 1))]}" = word ] || return 0
      case "$word" in
        --local | --global | --worktree | --system) continue ;;
        --add | --replace-all | set) continue ;;
        --unset | --unset-all | unset) config_action=reset; continue ;;
        --all) [ "$config_action" != reset ] || continue; return 0 ;;
        -*) return 0 ;;
      esac
      case "$word" in
        [Cc][Oo][Rr][Ee].[Hh][Oo][Oo][Kk][Ss][Pp][Aa][Tt][Hh])
          if [ "$config_action" = reset ] || [ "$i" -lt "${#ARGS[@]}" ]; then
            CALL_RESULT=config-change
          fi ;;
      esac
      return 0
    done
    return 0
  fi
  [ "$verb" = commit ] || return 0
  CALL_RESULT=commit; CALL_BYPASS=$env_config
  [ -z "$uncertain" ] || unresolved=1
  while [ "$i" -lt "${#ARGS[@]}" ]; do
    word=${ARGS[$i]}; value=${ORIGINAL[$i]}; i=$((i + 1))
    word_kind=${ARG_KINDS[$((i - 1))]}; owns_value=""
    case "$word_kind" in
      value)
        case "$word" in
          --*=*) continue ;;
          --*) unresolved=1; continue ;;
          -?*) ;;
          *) unresolved=1; continue ;;
        esac ;;
      expanded) unresolved=1; continue ;;
    esac
    case "$word" in
      --) break ;;
      --dry-run | --short | --porcelain | --long | --help | -h)
        CALL_RESULT=other; CALL_BYPASS=""; return 0 ;;
      --no-verify | --no-veri | --no-verif) [ -n "$flag" ] || flag=$value ;;
      --verify) flag="" ;;
      --message | --file | --reuse-message | --reedit-message | --template | --author | --date | --cleanup | --fixup | --squash | --trailer | --pathspec-from-file)
        [ "${ARG_KINDS[$i]:-word}" != expanded ] || unresolved=1
        i=$((i + 1)) ;;
      --*=* | --*) ;;
      -?*)
        rest=${word#-}
        while [ -n "$rest" ]; do
          letter=${rest:0:1}; rest=${rest:1}
          case "$letter" in
            n) [ -n "$flag" ] || flag=$value ;;
            m | F | c | C | t)
              owns_value=1
              if [ -z "$rest" ] && [ "$word_kind" = word ]; then
                [ "${ARG_KINDS[$i]:-word}" != expanded ] || unresolved=1
                i=$((i + 1))
              fi
              break ;;
            S | u) owns_value=1; break ;;
          esac
        done
        [ "$word_kind" != value ] || [ -n "$owns_value" ] || unresolved=1 ;;
      *) continue ;;
    esac
  done
  CALL_FLAG=$flag
  [ -n "$CALL_BYPASS" ] || CALL_BYPASS=$flag
  # A completed call owns its refusal, independent of prior configuration.
  # Unknown option identity or argument boundaries still withhold a refusal.
  if [ -n "$unresolved" ]; then CALL_RESULT=commit-unavailable
  elif [ -n "$CALL_BYPASS" ]; then CALL_RESULT=commit-refusal; fi
}

tokenize || [ "$READER_STATE" = incomplete ]
# Consent is read from the repository before this tool command. A combined
# config mutation and bypass commit must be split so Git can show real setup.
ARMED=""; HOOKS_DIR=""
if HOOKS_DIR=$(git rev-parse --git-path hooks 2>/dev/null); then
  HOOKS_PATH_STATUS=0
  git config --get core.hooksPath >/dev/null 2>&1 || HOOKS_PATH_STATUS=$?
  if [ "$HOOKS_PATH_STATUS" -eq 1 ] && [ -x "$HOOKS_DIR/pre-commit" ] && [ -x "$HOOKS_DIR/commit-msg" ] \
    && grep -qF -- "$MARKER" "$HOOKS_DIR/pre-commit" 2>/dev/null \
    && grep -qF -- "$MARKER" "$HOOKS_DIR/commit-msg" 2>/dev/null; then
    ARMED=1
  fi
else HOOKS_DIR=""; fi
COMMIT=""; BYPASS=""; SAME_COMMAND=""; CONFIG_MUTATION=""; UNARMED=""; MOVES=""; UNAVAILABLE=""; ARGS=(); ORIGINAL=(); ARG_KINDS=(); target=""
for ((index=0; index<${#TOKENS[@]}; index++)); do
  token=${TOKENS[$index]}
  if [ "${KINDS[$index]}" = redirect ]; then
    target=1
  elif [ "${KINDS[$index]}" = separator ]; then
    if [ "${#ARGS[@]}" -gt 0 ]; then
      read_call
      case "$CALL_RESULT" in
        commit-refusal)
          COMMIT=1
          if [ -n "$CONFIG_MUTATION" ] && [ -n "$CALL_FLAG" ]; then
            if [ -z "$BYPASS" ]; then BYPASS=$CALL_FLAG; SAME_COMMAND=1; fi
          elif [ -n "$ARMED" ]; then
            [ -n "$BYPASS" ] || BYPASS=$CALL_BYPASS
          else UNARMED=1; fi ;;
        commit)
          COMMIT=1
          [ -n "$ARMED" ] || UNARMED=1 ;;
        commit-unavailable) COMMIT=1; UNAVAILABLE=1 ;;
        config-change) CONFIG_MUTATION=1 ;;
        other) ;;
        *) exit 1 ;;
      esac
    fi
    ARGS=(); ORIGINAL=(); ARG_KINDS=(); target=""
  elif [ -n "$target" ]; then
    target=""
  else
    case "$token" in cd | GIT_DIR=* | GIT_WORK_TREE=*) MOVES=1 ;; esac
    ARGS[${#ARGS[@]}]=$token; ORIGINAL[${#ORIGINAL[@]}]=${RAW[$index]}; ARG_KINDS[${#ARG_KINDS[@]}]=${KINDS[$index]}
  fi
done
[ "$READER_STATE" = complete ] || UNAVAILABLE=1

if [ -n "$BYPASS" ]; then
  message bypass "$BYPASS"
  exit 2
fi
[ -z "$UNAVAILABLE" ] || { message command unresolved; exit 0; }
[ -n "$COMMIT" ] || exit 0
[ -n "$HOOKS_DIR" ] || { [ -z "$MOVES" ] || message judged "$PWD"; exit 0; }
[ -n "$UNARMED" ] || exit 0
message unarmed "$PWD"
COMMON=$(git rev-parse --git-common-dir 2>/dev/null) || { message setup consent; exit 0; }
GIT_DIR_LOCAL=$(git rev-parse --git-dir 2>/dev/null) || { message setup consent; exit 0; }
COMMON=$(cd -- "$COMMON" && pwd -P) || { message setup consent; exit 0; }
GIT_DIR_LOCAL=$(cd -- "$GIT_DIR_LOCAL" && pwd -P) || { message setup consent; exit 0; }
if [ "$COMMON" != "$GIT_DIR_LOCAL" ]; then
  MAIN=$(cd -- "$COMMON/.." && pwd -P) || { message setup consent; exit 0; }
  message setup "$MAIN"
else
  message setup consent
fi
exit 0
