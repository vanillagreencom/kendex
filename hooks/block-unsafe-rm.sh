#!/usr/bin/env bash
# ---
# name: block-unsafe-rm
# event: PreToolUse
# matcher: Bash
# requires: [command-safety]
# description: Block rm on shared directory roots, globs directly under them, child paths with . or .. segments, and paths that start with a variable that may expand empty. Keep a private mktemp directory and remove it in the same shell call. Not run on antigravity: its required command-safety companion does not name antigravity, whose payload is toolCall.args.
# summary: Stops deletes of shared directory roots, their direct globs or child paths with . or .. segments, and paths that start with a variable that may be empty. The refusal gives a safe cleanup pattern.
# safety: The raw command scan refuses any rm on TMPDIR, TMP, TEMP, AGENT_TMPDIR or HOME roots, globs directly under them, and child paths containing . or .. segments, regardless of flags, including `${NAME:?…}`. Literal operands are compared as text against nonempty hook environment values, with trailing slashes ignored; no filesystem reads or glob expansion occur. Named child paths without . or .. segments pass this check. The existing empty-variable check refuses `$NAME`, `${NAME}` and `${NAME:-…}` roots; `${NAME:?…}` passes it. A redirection target is not an operand. Harmless text with the same shape can be refused. The scan does not parse shell: aliases such as `D=$TMPDIR`, `${!NAME}`, cd followed by relative rm, command substitutions, split command names and line continuations can escape it. Every refusal opens with `block-unsafe-rm: <key>=<value>`; captured command output follows that line.
# ---

set -euo pipefail

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
      echo "the commands ${2//,/, } are required to read the hook payload and are not on PATH; refusing rather than skipping the guard" >&2
      ;;
    payload=invalid-json)
      echo "the hook payload is not valid JSON, or names a command that is not a string; refusing rather than skipping the guard" >&2
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
  exit 2
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

INPUT=$(cat)

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

# The whole rule, built from named parts so each one is readable on its own.
# The parts count WHEREVER they stand in the command. There is no
# command-position test: one was tried, and a hand-written list of the keywords
# that may precede an rm is an enumeration of shell grammar — every revision of
# it named fewer members than it missed, and `if`, `while`, `until`, `!` and
# `time` all carried a real variable-rooted recursive rm straight past it.
# ENDERS is what remains of that reading: it says where one command ends and
# the next begins, so GAP and SKIP exclude it and a scan never REACHES out of
# the command it began in.
#
#   ENDERS    the characters that END one command: `;`, `&`, `|` and a newline.
#             The newline is one of them because the words of the next line are
#             not this rm's operands.
#   RM_EDGE   what may stand immediately left of the `rm`: the start of the
#             command, or any character an identifier cannot hold, so
#             `confirm -rf $X` is one word and not this hook's rm. It is a word
#             boundary and nothing more — bash's `=~` runs without REG_NEWLINE,
#             so `^` alone would never reach line two of a multi-line call, and
#             a newline is one of the characters this admits.
#   ROOT      an operand rooted in a variable that may expand empty: `$NAME`,
#             `${NAME}`, `${NAME:-…}`. `${NAME:?…}` aborts on empty and is the
#             accepted rewrite for a non-shared root; the
#             identifier test is what keeps `${X+x:?}` — an unset-guarded
#             ALTERNATIVE whose text merely contains :? — on the refused side.
#             A leading double quote is peeled, since quoting does not stop an
#             empty expansion; a single-quoted run is a literal the shell never
#             expands and is not a variable root.
#   GAP       the whitespace standing between two words of ONE command. It is
#             horizontal whitespace and nothing else, because the only
#             whitespace character in ENDERS is the newline: a gap that crossed
#             one would read the next command's words as this rm's operands.
#   SKIP      crosses words and complete redirections in an agent's Bash call.
#             A redirection's operator and target form one unit, so its target
#             never becomes an operand. Quoted and escaped parts stay inside
#             WORD, including spaces in a target. A redirection may touch a
#             word, but an operand still needs GAP before it. Separators in
#             ENDERS stop the scan outside words and redirections.
#
# Flags do not affect the rule. Shell-assembled command names and line
# continuations remain outside this lexical scan.
# The ampersand leads so this string does not spell bash 4's case fall-through
# operator, which tools/bash32-lint flags in string data too. A bracket
# expression carries no order, so the set below is the set named above.
ENDERS='&;|'$'\n'
# BLANK and SPACE_ANY are the class names as they are spelled INSIDE a bracket
# expression, so the same two definitions serve a class of their own and a
# member of a larger one.
BLANK='[:blank:]'
SPACE_ANY='[:space:]'
GAP="[${BLANK}]"
RM_EDGE='(^|[^[:alnum:]_.-])'
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
[[ ! $COMMAND =~ $SHARED_RE ]] || refuse refused shared-root
for root_name in TMPDIR TMP TEMP AGENT_TMPDIR HOME; do
  root_value=${!root_name-}
  [ -n "$root_value" ] || continue
  while [[ $root_value == */ && $root_value != / ]]; do root_value=${root_value%/}; done
  literal_root=$root_value
  literal_end=$SHARED_END
  if [ "$root_value" = / ]; then literal_root=''; literal_end="${SHARED_SLASH}${SHARED_BOUNDARY}"; fi
  for metachar in '\' '.' '[' ']' '(' ')' '{' '}' '*' '+' '?' '^' '$' '|'; do
    literal_root=${literal_root//"$metachar"/\\"$metachar"}
  done
  SHARED_RE="${RM_EDGE}rm${SKIP}${GAP}+[\"']*${literal_root}${literal_end}"
  [[ ! $COMMAND =~ $SHARED_RE ]] || refuse refused shared-root
done

if [[ ! $COMMAND =~ $UNSAFE_RE ]]; then
  exit 0
fi

# Keep the refusal key stable for existing callers.
refuse refused recursive-rm
