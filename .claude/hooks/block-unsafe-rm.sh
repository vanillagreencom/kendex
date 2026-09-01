#!/usr/bin/env bash
# ---
# name: block-unsafe-rm
# event: PreToolUse
# matcher: Bash
# description: Block a recursive rm whose first path operand starts with a variable that may expand empty — a path outside the working tree wherever that variable is empty or unset. Names the rewrite the harness accepts without a prompt.
# safety: The harness stops the whole session on that shape with a "Dangerous rm operation on possibly-empty variable path" prompt; refusing it here lets the agent rewrite and continue. One regex over the raw command decides: an rm in command position, a flag word carrying r or R, then an operand rooted in `$NAME`, `${NAME}` or `${NAME:-…}`. `${NAME:?…}` is the one form that cannot expand empty and it passes. A bypass the shell would assemble — a quoted flag, a line continuation, a variable holding the flag — is not seen here; the harness prompt is the backstop, and this hook only spares the session that stall.
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

# The whole rule, in the order the words stand:
#
#   1. `rm` in command position — the start of the command, or after one of the
#      characters that end a command, or after a `then`/`do`/`else` keyword.
#      A word before it that is none of those makes it another command's
#      argument, so `git rm -r --cached $X` is git's and not this hook's.
#   2. a flag word carrying `r` or `R` — `-rf`, `-R`, `--recursive`. Without
#      recursion the path is a file, and the harness does not prompt.
#   3. the first non-flag operand, rooted in a variable that may expand empty:
#      `$NAME`, `${NAME}`, `${NAME:-…}`. `${NAME:?…}` aborts on empty and is
#      the accepted rewrite, so it is the one variable root that passes; the
#      identifier test is what keeps `${X+x:?}` — an unset-guarded ALTERNATIVE
#      whose text merely contains :? — on the refused side. A leading double
#      quote is peeled, since quoting does not stop an empty expansion; a
#      single-quoted run is a literal the shell never expands and is not a
#      variable root.
#
# The awk segmenter and flag folder this replaced answered a quoted `"-rf"`, a
# backslash-split `-r""f`, a line continuation and a dash-leading operand after
# `--`. Those are not seen here, and that is the trade: it is the frozen
# lexical-scanner class, and a finding of that shape against this file is
# declined, not patched. The harness prompt still stops every one of them; what
# it costs is the stall this hook exists to spare.
UNSAFE_RE='(^|[;&|(){}]|[[:space:]](then|do|else)[[:space:]])[[:space:]]*rm([[:space:]]+-[^[:space:]]+)*[[:space:]]+-[^[:space:]]*[rR][^[:space:]]*([[:space:]]+-[^[:space:]]+)*[[:space:]]+"*\$([A-Za-z_]|\{[A-Za-z_][A-Za-z0-9_]*([^:A-Za-z0-9_]|:[^?]))'

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
