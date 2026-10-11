#!/usr/bin/env bash
# ---
# name: block-unsafe-rm
# event: PreToolUse
# matcher: Bash
# requires: [command-safety]
# description: Block rm on shared directory roots, globs directly under them, child paths with . or .. segments, and paths that start with a variable that may expand empty. Keep a private mktemp directory and remove it in the same shell call. Not run on antigravity: its required command-safety companion does not name antigravity, whose payload is toolCall.args.
# summary: Stops executable rm commands on shared roots or paths rooted at a possibly empty variable. Quoted arguments of other commands and here-document data pass. Missing tools or unreadable input produce one warning and allow the call.
# safety: Advisory reader: dependency or payload failures warn once and allow the call. Executable command matches retain exit 2. The commit-guards command-position reader selects command words and masks quoted data and data-only here-document bodies. This is a lexical check; assembled command names and unknown launcher option forms are outside its contract. Every diagnostic starts with block-unsafe-rm: <key>=<value>.
# requires-skills: [commit-guards]
# ---

set -euo pipefail
trap 'rc=$?; case $rc in 0 | 2) ;; *) refuse exit "$rc" ;; esac' EXIT

# The command as it was read, empty until the reader has it: the refusal quotes
# it, and a refusal can be reached before it is set.
COMMAND=""
# Every line this hook writes, and the only place its text lives. The first
# line is the contract a reader parses, `block-unsafe-rm: <key>=<value>`: a
# stable key for the condition and the value acted on — the missing tool, why
# the payload could not be read, or the shape refused. The English explanation
# and the rewrites follow on later lines.
# The keyed line stands first, at position 1. What a command this hook runs
# wrote is captured where the hook reads it and passed here as the cause, so
# it is replayed under the key rather than ahead of it.
refuse() { # KEY VALUE [CAUSE]
  printf 'block-unsafe-rm: %s=%s\n' "$1" "$2" >&2
  case "$1=$2" in
    missing-tools=*)
      echo "the commands ${2//,/, } are required to read the hook payload and are not on PATH; this check is unavailable" >&2
      ;;
    payload=invalid-json)
      echo "the hook payload is not valid JSON, or names a command that is not a string; this check is unavailable" >&2
      ;;
    refused=shared-root)
      echo "This rm targets a shared root, its direct glob, or a child path with . or .. segments:" >&2
      echo "  $COMMAND" >&2
      echo 'The :? guard proves only that the variable is not empty.' >&2
      echo 'Keep d=$(mktemp -d) and remove "${d:?}" in the same shell call.' >&2
      ;;
    refused=recursive-rm)
      echo "This rm is on a path rooted at a variable that may be empty:" >&2
      echo "  $COMMAND" >&2
      echo "With the variable empty, the path collapses and the rm can remove from /." >&2
      echo "In Claude Code, the critical-path check prompts for a glob or trailing slash directly under such a variable;" >&2
      echo "that prompt waits two minutes in bypassPermissions mode, then denies the call." >&2
      echo "Rewrite so the path cannot collapse to / — either form is accepted:" >&2
      echo "  rm -- \"\${NAME:?}/file\"      (bash aborts if NAME is unset or empty)" >&2
      echo "  rm -- /absolute/literal/path" >&2
      echo "Keep the flags from your original command." >&2
      ;;
  esac
  # The cause a command this hook ran wrote, captured at the site and replayed
  # here: under the keyed line, never ahead of it.
  [ -z "${3:-}" ] || printf '%s\n' "$3" >&2
  case "$1" in
    refused | path) exit 2 ;;
    *)
      echo "Check skipped. Repair the hook installation, tools or payload adapter; retry the command." >&2
      exit 0 ;;
  esac
}

# jq is the only reader of the payload. Without it the command cannot be read,
# and a command this hook has not read cannot be shown to name a path that
# stays inside the working tree. jq leads so the world with no tools at all
# names it.
MISSING=""
for dependency in jq cat; do
  command -v "$dependency" >/dev/null 2>&1 || MISSING="$MISSING,$dependency"
done
[ -z "$MISSING" ] || refuse missing-tools "${MISSING#,}"

INPUT=$(cat 2>&1) || refuse payload unreadable "$INPUT"

# A payload that does not parse, or that names a command which is not a
# string, produces a warning and allows the call. An absent command is the empty
# string and passes. The command is read where each harness carries it:
# `tool_input.command` (Claude Code, Codex, Gemini CLI and the Pi carrier), a
# bare `command`, or Copilot's `toolArgs.command`, whose `toolArgs` arrives as
# an object or as one JSON-encoded string. The null tests are spelled out
# because jq's `//` reads `false` as absent, and `false` is not a command
# either.
COMMAND=$(printf '%s' "$INPUT" \
  | jq -er 'def copilot: .toolArgs
             | if . == null then null elif type == "string" then fromjson else . end
             | if . == null then null elif type == "object" then .command else error end;
           if .tool_input.command != null then .tool_input.command
           elif .command != null then .command
           elif copilot != null then copilot
           else "" end
           | if type == "string" then . else error end' 2>/dev/null) ||
  refuse payload invalid-json

# Resolve only this hook's installed dependency, never a payload-selected path.
reader=""
for candidate in "${BASH_SOURCE[0]%/*}/../skills/commit-guards/scripts/lib/command-position.sh" \
  "${BASH_SOURCE[0]%/*}/../.agents/skills/commit-guards/scripts/lib/command-position.sh" \
  "${BASH_SOURCE[0]%/*}/../../.agents/skills/commit-guards/scripts/lib/command-position.sh" \
  "${BASH_SOURCE[0]%/*}/../../../.agents/skills/commit-guards/scripts/lib/command-position.sh" \
  "${BASH_SOURCE[0]%/*}/../../skills/commit-guards/scripts/lib/command-position.sh" \
  "${HOME:+$HOME/.agents/skills/commit-guards/scripts/lib/command-position.sh}"; do
  if [ -f "$candidate" ]; then reader=$candidate; break; fi
done
[ -n "$reader" ] || refuse reader unavailable
# shellcheck source=../skills/commit-guards/scripts/lib/command-position.sh
source "$reader" 2>/dev/null || refuse reader unreadable
# Match rm operands only after the shared reader selects rm.
ENDERS='&;|'$'\n'
# BLANK and SPACE_ANY are the class names as they are spelled INSIDE a bracket
# expression, so the same two definitions serve a class of their own and a
# member of a larger one.
BLANK='[:blank:]'
SPACE_ANY='[:space:]'
GAP="[${BLANK}]"
RM_EDGE='^'
ROOT='"*\$([A-Za-z_]|\{[A-Za-z_][A-Za-z0-9_]*([^:A-Za-z0-9_]|:[^?]))'
CROSSABLE="[^${ENDERS}<>${SPACE_ANY}]"
WORD_PART="[^${ENDERS}<>${SPACE_ANY}\"'\\\\]"
QUOTED_WORD='"([^"\\]|\\.)*"|'"'[^']*'"
ESCAPED_WORD='\\[^'$'\n'']'
WORD="(${WORD_PART}|${QUOTED_WORD}|${ESCAPED_WORD})+"
REDIRECT='([[:digit:]]*|\{[[:alpha:]_][[:alnum:]_]*\})(&>[>]?|[<>]&|>>|<<<|<<-|<<|<>|>\||[<>])'
SKIP="(${GAP}+${WORD}|${GAP}*${REDIRECT}${GAP}*${WORD})*"
UNSAFE_RE="${RM_EDGE}rm${SKIP}${GAP}+${ROOT}"

# The harness has no shared-root ownership check.
# With HOME=/shared/home, rm -rf /shared/home/* is a refused direct glob.
SHARED_NAMES='(TMPDIR|TMP|TEMP|AGENT_TMPDIR|HOME)'
SHARED_CHILD="[^/${ENDERS}<>${SPACE_ANY}]*"
SHARED_DOT="(${SHARED_CHILD}/+)*[\"']*\\.\\.?[\"']*(/+${CROSSABLE}*)?"
SHARED_SLASH="/+[\"']*(${SHARED_CHILD}[*?[]${SHARED_CHILD}/*|${SHARED_DOT})?"
SHARED_BOUNDARY="[\"']*($|[${ENDERS}<>${SPACE_ANY}])"
SHARED_END="[\"']*(${SHARED_SLASH})?${SHARED_BOUNDARY}"
# Apple's regex rejects an empty alternative; an optional suffix accepts none.
SHARED_ROOT="\"*\\\$(${SHARED_NAMES}|\\{${SHARED_NAMES}([^[:alnum:]_}][^}]*)?\\})${SHARED_END}"
SHARED_RE="${RM_EDGE}rm${SKIP}${GAP}+${SHARED_ROOT}"
command_segments "$COMMAND"
while IFS= read -r segment; do
  command_text "$segment"
  selected=${COMMAND_TEXTS%"$NL"}
  [[ $selected == rm[[:space:]]* ]] || continue
  [[ ! $selected =~ $SHARED_RE ]] || refuse refused shared-root
for root_name in TMPDIR TMP TEMP AGENT_TMPDIR HOME; do
  root_value=${!root_name-}
  [ -n "$root_value" ] || continue
  while [[ $root_value == */ && $root_value != / ]]; do root_value=${root_value%/}; done
  literal_root=${root_value//[[:space:]]/$MASK}
  literal_end=$SHARED_END
  if [ "$root_value" = / ]; then literal_root=''; literal_end="${SHARED_SLASH}${SHARED_BOUNDARY}"; fi
  for metachar in '\' '.' '[' ']' '(' ')' '{' '}' '*' '+' '?' '^' '$' '|'; do
    literal_root=${literal_root//"$metachar"/\\"$metachar"}
  done
  LITERAL_RE="${RM_EDGE}rm${SKIP}${GAP}+[\"']*${literal_root}${literal_end}"
  [[ ! $selected =~ $LITERAL_RE ]] || refuse refused shared-root
done

  [[ ! $selected =~ $UNSAFE_RE ]] || refuse refused recursive-rm
done <<<"$SEGMENTS"
exit 0
