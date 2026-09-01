#!/usr/bin/env bash
# ---
# name: block-unsafe-rm
# event: PreToolUse
# matcher: Bash
# description: Block a recursive rm with a path operand that starts with a variable that may expand empty — a path outside the working tree wherever that variable is empty or unset. Names the rewrite the harness accepts without a prompt.
# safety: The harness stops the whole session on that shape with a "Dangerous rm operation on possibly-empty variable path" prompt; refusing it here lets the agent rewrite and continue. One regex over the raw command decides: an rm in command position (the start of a line included, so a multi-line call is read past its first line), a recursion flag — a single-dash cluster carrying r or R, or `--recursive` — and an operand rooted in `$NAME`, `${NAME}` or `${NAME:-…}`, in either order and wherever in that rm's operands they stand. `${NAME:?…}` is the one form that cannot expand empty and it passes, and a redirection target is not an operand. A bypass the shell would assemble — a quoted flag, a line continuation, a variable holding the flag — is not seen here; the harness prompt is the backstop, and this hook only spares the session that stall.
# harnesses: [claude-code, cursor, opencode, codex]
# ---

set -euo pipefail

# jq is the only reader of the payload. Without it the command cannot be read,
# and a command this hook has not read cannot be shown to name a path that
# stays inside the working tree.
if ! command -v jq >/dev/null 2>&1 || ! command -v cat >/dev/null 2>&1; then
  echo "block-unsafe-rm: jq and cat are required to read the hook payload; refusing rather than skipping the guard" >&2
  exit 2
fi

INPUT=$(cat)

# A payload that does not parse, or that names a command which is not a
# string, is refused rather than skipped. An absent command is the empty
# string and passes. The null tests are spelled out because jq's `//` reads
# `false` as absent, and `false` is not a command either.
if ! COMMAND=$(printf '%s' "$INPUT" \
  | jq -r 'if .tool_input.command == null then (if .command == null then "" else .command end)
           else .tool_input.command end
           | if type == "string" then . else error end' 2>/dev/null); then
  echo "block-unsafe-rm: hook payload is not valid JSON, or names a command that is not a string; refusing rather than skipping the guard" >&2
  exit 2
fi

# The whole rule, built from named parts so each one is readable on its own.
# ENDERS is the one definition of where a command stops, and every other part
# is built from it, so no two of them can answer "how far does this rm reach?"
# differently:
#
#   ENDERS    the characters that END one command: `;`, `&`, `|` and a newline.
#             The newline is one of them because a newline both starts a
#             command and ends the one before it.
#   POSITION  `rm` in command position — the start of the command, one of
#             ENDERS, a brace or parenthesis, or a `then`/`do`/`else` keyword.
#             A word before it that is none of those makes it another command's
#             argument, so `git rm -r --cached $X` is git's and not this
#             hook's. The newline earns its place here because bash's `=~` runs
#             without REG_NEWLINE, so `^` anchors the whole command and nothing
#             else would reach line two of a multi-line call.
#   RECURSE   a flag word that means recursion: a single-dash cluster carrying
#             `r` or `R`, or `--recursive` spelled out. A long flag merely
#             holding an r (`--verbose`, `--interactive`, `--preserve-root`) is
#             not one — without recursion the path is a file, and the harness
#             does not prompt.
#   ROOT      an operand rooted in a variable that may expand empty: `$NAME`,
#             `${NAME}`, `${NAME:-…}`. `${NAME:?…}` aborts on empty and is the
#             accepted rewrite, so it is the one variable root that passes; the
#             identifier test is what keeps `${X+x:?}` — an unset-guarded
#             ALTERNATIVE whose text merely contains :? — on the refused side.
#             A leading double quote is peeled, since quoting does not stop an
#             empty expansion; a single-quoted run is a literal the shell never
#             expands and is not a variable root.
#   GAP       the whitespace standing between two words of ONE command. It is
#             horizontal whitespace and nothing else, because the only
#             whitespace character in ENDERS is the newline: a gap that crossed
#             one would read the next command's words as this rm's operands.
#   SPACE     whitespace INCLUDING that newline, spelled apart from GAP so the
#             two places it belongs are the two places it stands: around the
#             POSITION keywords, where a newline is the separator that puts the
#             rm in command position, and after a trailing RECURSE, where a
#             newline ends the flag word rather than reaching past it.
#   SKIP      the words the scan crosses to get from one part to the next,
#             built from GAP and CROSSABLE — any character but ENDERS, `<` and
#             `>`. An ender would end this rm, and a redirection target is not
#             an operand at all, so `rm -rf /var/tmp/x > $LOG` is not a
#             variable-rooted rm. Crossing ordinary words is what reaches a
#             LATER operand and a flag written after the operand, both of which
#             GNU rm accepts.
#
# Both orders are spelled out rather than folded together: the flag before the
# operand, and the operand before the flag.
#
# The awk segmenter and flag folder this replaced answered a quoted `"-rf"`, a
# backslash-split `-r""f`, a line continuation and a dash-leading operand after
# `--`. Those are not seen here, and that is the trade: it is the frozen
# lexical-scanner class, and a finding of that shape against this file is
# declined, not patched. The harness prompt still stops every one of them; what
# it costs is the stall this hook exists to spare.
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
SPACE="[${SPACE_ANY}]"
POSITION="(^|[${ENDERS}(){}]|${SPACE}(then|do|else)${SPACE})${SPACE}*rm"
RECURSE="(-[^-${SPACE_ANY}]*[rR][^${SPACE_ANY}]*|--recursive)"
ROOT='"*\$([A-Za-z_]|\{[A-Za-z_][A-Za-z0-9_]*([^:A-Za-z0-9_]|:[^?]))'
CROSSABLE="[^${ENDERS}<>${SPACE_ANY}]"
SKIP="(${GAP}+${CROSSABLE}+)*"
UNSAFE_RE="${POSITION}${SKIP}${GAP}+(${RECURSE}${SKIP}${GAP}+${ROOT}|${ROOT}${CROSSABLE}*${SKIP}${GAP}+${RECURSE}(${SPACE}|\$))"

if [[ ! $COMMAND =~ $UNSAFE_RE ]]; then
  exit 0
fi

{
  echo "Recursive rm on a variable-rooted path stalls the session: the harness stops on"
  echo "  $COMMAND"
  echo "with a 'Dangerous rm operation on possibly-empty variable path' prompt."
  echo "Rewrite so the path cannot collapse to / — either form is accepted:"
  echo "  rm -rf -- \"\${NAME:?}/sub\"      (bash aborts if NAME is unset or empty)"
  echo "  rm -rf -- /absolute/literal/path"
} >&2
exit 2
