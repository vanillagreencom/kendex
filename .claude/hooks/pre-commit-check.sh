#!/usr/bin/env bash
# ---
# name: pre-commit-check
# event: PreToolUse
# matcher: Bash
# description: Defers commits to executable, marked pre-commit and commit-msg hooks in the working repository. Refuses a literal bypass option in a direct git commit call or a literal core.hooksPath override applied to that call. Reads quoted words, comments, command boundaries and option values without executing shell text. Messages, path operands and other programs' arguments are not options. Unarmed repositories get a consent notice; linked worktrees get a main-owner setup route. Unavailable tools, unreadable payloads and shell forms this reader cannot resolve get a notice and allow the command. This hook never runs repository setup or check scripts.
# summary: Stops explicit options that skip armed commit checks. Missing setup or an unavailable reader produces a notice with the responsible owner.
# safety: Reads JSON, literal shell words and Git hook files. Executes no command from the payload and no repository script. Shell expansion, substitutions, heredocs and unclosed quotes are reported unresolved and allowed; indirect launches are outside the literal direct-call check. Git's installed hooks enforce checks when the hook cannot read a command. The working repository alone is judged; repository-moving commands get a notice. Every diagnostic starts with pre-commit-check: key=value.
# timeout: 60
# ---

set -euo pipefail

MARKER="# kendex-guards-hook"

message() { # KEY VALUE [CAUSE]
  printf 'pre-commit-check: %s=%s\n' "$1" "$2" >&2
  case "$1" in
    missing-tools)
      echo "The hook reader is unavailable. The machine operator must provide ${2//,/, }. This command is allowed; no hook verdict is available." >&2 ;;
    payload)
      echo "The hook cannot read the tool payload. This command is allowed. Report a repeated payload failure to the hook author; the machine operator must repair an unavailable reader." >&2 ;;
    command)
      echo "The hook cannot resolve this shell form without execution. This command is allowed; Git's installed hooks remain responsible for commit checks." >&2 ;;
    bypass)
      echo "This option skips the repository's armed commit checks. Remove the option and commit with the installed hooks." >&2 ;;
    unarmed)
      echo "Commit checks are not armed in $2. This command is allowed. Repository setup requires a person's consent before repository scripts run." >&2 ;;
    setup)
      if [ "$2" = consent ]; then
        echo "Ask the repository owner for consent. After consent, use the tracked commit-guards installer from the repository root, or kendex guard install. Use kendex guard check to inspect setup." >&2
      else
        echo "Ask the owner of the main checkout at $2 to set up commit checks after consent. An item lane must not change shared hook setup." >&2
      fi ;;
    judged)
      echo "The command moves repositories. Only $2 was inspected. The target repository's own hooks must check its commits." >&2 ;;
  esac
  [ -z "${3:-}" ] || printf '%s\n' "$3" >&2
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

# Keep words and operators distinct, including an empty quoted argument. No
# eval, glob expansion or shell launch may turn payload data into code. Bash
# expansion and heredocs require execution context this hook does not own.
tokenize() {
  local i=0 char next quote="" word="" active="" raw=""
  TOKENS=(); KINDS=(); RAW=()
  while [ "$i" -lt "${#COMMAND}" ]; do
    char=${COMMAND:$i:1}
    i=$((i + 1))
    if [ "$quote" = "'" ]; then
      raw="$raw$char"
      if [ "$char" = "'" ]; then quote=""; else word="$word$char"; fi
      continue
    fi
    if [ "$char" = '\' ]; then
      [ "$i" -lt "${#COMMAND}" ] || return 1
      next=${COMMAND:$i:1}; i=$((i + 1))
      if [ "$quote" = '"' ]; then
        case "$next" in '"' | '\' | '$' | '`' | $'\n') ;; *) word="$word$char" ;; esac
      fi
      raw="$raw$char$next"
      [ "$next" = $'\n' ] || { word="$word$next"; active=1; }
      continue
    fi
    case "$char" in '$' | '`') return 1 ;; esac
    if [ "$quote" = '"' ]; then
      raw="$raw$char"
      if [ "$char" = '"' ]; then quote=""; else word="$word$char"; fi
      continue
    fi
    case "$char" in
      "'" | '"') quote=$char; active=1; raw="$raw$char" ;;
      '#')
        if [ -z "$active" ]; then
          while [ "$i" -lt "${#COMMAND}" ] && [ "${COMMAND:$i:1}" != $'\n' ]; do i=$((i + 1)); done
        else word="$word$char"; raw="$raw$char"; fi ;;
      ' ' | $'\t' | $'\r' | $'\n' | ';' | '&' | '|' | '(' | ')' | '<' | '>')
        case "$word" in
          '' | *[!0-9]*) ;;
          *)
            case "$char" in '<' | '>') [ "$raw" != "$word" ] || active="" ;; esac ;;
        esac
        if [ -n "$active" ]; then
          TOKENS[${#TOKENS[@]}]=$word; KINDS[${#KINDS[@]}]=word; RAW[${#RAW[@]}]=$raw
          word=""; raw=""; active=""
        fi
        case "$char" in
          ' ' | $'\t' | $'\r') continue ;;
          '<')
            case "${COMMAND:$i:1}" in '<' | '(') return 1 ;; esac ;;
          '>') [ "${COMMAND:$i:1}" != '(' ] || return 1 ;;
        esac
        case "$char${COMMAND:$i:1}" in
          '>&' | '<&' | '>>' | '>|') char="$char${COMMAND:$i:1}"; i=$((i + 1)) ;;
        esac
        word=""; raw=""; active=""
        TOKENS[${#TOKENS[@]}]=$char; KINDS[${#KINDS[@]}]=operator; RAW[${#RAW[@]}]=$char ;;
      '*' | '?' | '[' | '{' | '}')
        # Standalone braces delimit command groups. Brace/glob expansion in a
        # word can change argument count, including which option owns a value.
        case "$char" in
          '{' | '}') [ -z "$active" ] && [ "${COMMAND:$i:1}" = ' ' ] || return 1 ;;
          *) return 1 ;;
        esac
        word=$char; raw=$char; active=1 ;;
      *) word="$word$char"; raw="$raw$char"; active=1 ;;
    esac
  done
  [ -z "$quote" ] || return 1
  if [ -n "$active" ]; then
    TOKENS[${#TOKENS[@]}]=$word; KINDS[${#KINDS[@]}]=word; RAW[${#RAW[@]}]=$raw
  fi
}
tokenize || { message command unresolved; exit 0; }
[ "${#TOKENS[@]}" -gt 0 ] || exit 0

# Git's documented global and commit option interfaces own these argument
# boundaries. The reader stops at path operands or --. It never searches
# option values for a bypass spelling (git-commit and git manuals).
read_call() {
  local i=0 word rest letter value config="" env_config="" verb="" flag=""
  local env_count="" prefix_end candidate key_index value_word present
  CALL_COMMIT=""; CALL_BYPASS=""; CALL_CONFIG=""
  while [ "$i" -lt "${#ARGS[@]}" ]; do
    word=${ARGS[$i]}; i=$((i + 1))
    case "$word" in
      GIT_CONFIG_COUNT=*) env_count=${word#*=} ;;
      [A-Za-z_]*=*) ;;
      '!' | '{' | '}' | if | then | else | elif | while | until | do | time | -p | command | env) ;;
      *) break ;;
    esac
  done
  [ "${word##*/}" = git ] || return 0
  prefix_end=$((i - 1))
  # Git ignores KEY/VALUE variables beyond COUNT. A key named in shell data
  # alone is therefore not evidence that this invocation overrides hooks.
  case "$env_count" in '' | *[!0-9]*) ;;
    *)
      for ((candidate=0; candidate<prefix_end; candidate++)); do
        word=${ARGS[$candidate]}
        case "$word" in GIT_CONFIG_KEY_*=*) ;; *) continue ;; esac
        value=${word#*=}; key_index=${word%%=*}; key_index=${key_index#GIT_CONFIG_KEY_}
        case "$key_index" in '' | *[!0-9]*) continue ;; esac
        [ "$key_index" -lt "$env_count" ] 2>/dev/null || continue
        case "$value" in
          [Cc][Oo][Rr][Ee].[Hh][Oo][Oo][Kk][Ss][Pp][Aa][Tt][Hh])
            present=""
            for ((value_word=0; value_word<prefix_end; value_word++)); do
              case "${ARGS[$value_word]}" in "GIT_CONFIG_VALUE_$key_index="*) present=1 ;; esac
            done
            [ -z "$present" ] || env_config=${ORIGINAL[$candidate]} ;;
        esac
      done ;;
  esac
  while [ "$i" -lt "${#ARGS[@]}" ]; do
    word=${ARGS[$i]}; i=$((i + 1))
    case "$word" in
      -c | --config-env)
        [ "$i" -lt "${#ARGS[@]}" ] || return 0
        value=${ARGS[$i]}; config=${ORIGINAL[$i]}; i=$((i + 1)) ;;
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
    # A config query returns data. Only a literal write with its value can
    # change the hooks used by a later commit in this command.
    while [ "$i" -lt "${#ARGS[@]}" ]; do
      word=${ARGS[$i]}; value=${ORIGINAL[$i]}; i=$((i + 1))
      case "$word" in
        --local | --global | --worktree | --system | --add | --replace-all | set) continue ;;
        -*) return 0 ;;
      esac
      case "$word" in
        [Cc][Oo][Rr][Ee].[Hh][Oo][Oo][Kk][Ss][Pp][Aa][Tt][Hh])
          [ "$i" -ge "${#ARGS[@]}" ] || CALL_CONFIG=$value ;;
      esac
      return 0
    done
    return 0
  fi
  [ "$verb" = commit ] || return 0
  CALL_COMMIT=1; CALL_BYPASS=$env_config
  while [ "$i" -lt "${#ARGS[@]}" ]; do
    word=${ARGS[$i]}; value=${ORIGINAL[$i]}; i=$((i + 1))
    case "$word" in
      --) break ;;
      --dry-run | --short | --porcelain | --long | --help | -h)
        CALL_COMMIT=""; CALL_BYPASS=""; return 0 ;;
      --no-verify | --no-veri | --no-verif) [ -n "$flag" ] || flag=$value ;;
      --verify) flag="" ;;
      --message | --file | --reuse-message | --reedit-message | --template | --author | --date | --cleanup | --fixup | --squash | --trailer | --pathspec-from-file)
        i=$((i + 1)) ;;
      --*=* | --*) ;;
      -?*)
        rest=${word#-}
        while [ -n "$rest" ]; do
          letter=${rest:0:1}; rest=${rest:1}
          case "$letter" in
            n) [ -n "$flag" ] || flag=$value ;;
            m | F | c | C | t) [ -n "$rest" ] || i=$((i + 1)); break ;;
            S | u) break ;;
          esac
        done ;;
      *) break ;;
    esac
  done
  [ -n "$CALL_BYPASS" ] || CALL_BYPASS=$flag
}

COMMIT=""; BYPASS=""; CONFIG_BYPASS=""; MOVES=""; ARGS=(); ORIGINAL=(); target=""
for ((index=0; index<${#TOKENS[@]}; index++)); do
  token=${TOKENS[$index]}
  if [ "${KINDS[$index]}" = operator ]; then
    case "$token" in
      '<' | '>' | '<&' | '>&' | '>>' | '>|') target=1; continue ;;
    esac
    if [ "${#ARGS[@]}" -gt 0 ]; then
      read_call
      [ -z "$CALL_COMMIT" ] || COMMIT=1
      [ -n "$BYPASS" ] || BYPASS=$CALL_BYPASS
      [ -z "$CALL_COMMIT" ] || [ -n "$BYPASS" ] || BYPASS=$CONFIG_BYPASS
      [ -z "$CALL_CONFIG" ] || CONFIG_BYPASS=$CALL_CONFIG
    fi
    ARGS=(); ORIGINAL=(); target=""
  elif [ -n "$target" ]; then
    target=""
  else
    case "$token" in cd | GIT_DIR=* | GIT_WORK_TREE=*) MOVES=1 ;; esac
    ARGS[${#ARGS[@]}]=$token; ORIGINAL[${#ORIGINAL[@]}]=${RAW[$index]}
  fi
done
if [ "${#ARGS[@]}" -gt 0 ]; then
  read_call
  [ -z "$CALL_COMMIT" ] || COMMIT=1
  [ -n "$BYPASS" ] || BYPASS=$CALL_BYPASS
  [ -z "$CALL_COMMIT" ] || [ -n "$BYPASS" ] || BYPASS=$CONFIG_BYPASS
  [ -z "$CALL_CONFIG" ] || CONFIG_BYPASS=$CALL_CONFIG
fi
[ -n "$COMMIT" ] || exit 0

HOOKS_DIR=$(git rev-parse --git-path hooks 2>/dev/null) || {
  [ -z "$MOVES" ] || message judged "$PWD"
  exit 0
}
HOOKS_PATH_STATUS=0
git config --get core.hooksPath >/dev/null 2>&1 || HOOKS_PATH_STATUS=$?
ARMED=""
if [ "$HOOKS_PATH_STATUS" -eq 1 ] \
  && [ -x "$HOOKS_DIR/pre-commit" ] && [ -x "$HOOKS_DIR/commit-msg" ] \
  && grep -qF -- "$MARKER" "$HOOKS_DIR/pre-commit" 2>/dev/null \
  && grep -qF -- "$MARKER" "$HOOKS_DIR/commit-msg" 2>/dev/null; then
  ARMED=1
fi
if [ -n "$ARMED" ]; then
  [ -n "$BYPASS" ] || exit 0
  message bypass "$BYPASS"
  exit 2
fi
message unarmed "$PWD"
COMMON=$(git rev-parse --git-common-dir 2>/dev/null) || { message setup consent; exit 0; }
GIT_DIR_LOCAL=$(git rev-parse --git-dir 2>/dev/null) || { message setup consent; exit 0; }
if [ "$COMMON" != "$GIT_DIR_LOCAL" ]; then
  MAIN=$(cd -- "$COMMON/.." && pwd -P) || { message setup consent; exit 0; }
  message setup "$MAIN"
else
  message setup consent
fi
exit 0
