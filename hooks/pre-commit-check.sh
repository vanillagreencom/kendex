#!/usr/bin/env bash
# ---
# name: pre-commit-check
# event: PreToolUse
# matcher: Bash
# description: On a git commit, defer to the repository's armed git pre-commit hook (kendex guard install arms one); where none is armed, or the command sidesteps it with git's no-verify flag, -n, or a core.hooksPath override, run the kendex guard pre-commit chain — format, lint, and commit guards — from the working directory as the fallback gate.
# safety: Prevents committing unchecked code in repositories without an armed git pre-commit hook, and in armed repositories when the command bypasses that hook (no-verify, -n, core.hooksPath).
# timeout: 1800
# ---

set -euo pipefail

INPUT=$(cat)

# Word-order detection, no shell parsing: the authoritative check is the
# repository's own git pre-commit hook, which git runs in the right repo
# whatever the command's quoting, substitutions, or directory hops. This
# lane only decides whether to consult the fallback, so a miss here skips
# feedback, never a check — and `git log --grep=commit` merely pays for a
# guard run it did not need.
#
# The payload is JSON, where a string never spans lines: joining the
# payload first reads a key and value that arrived on separate lines.
JOINED=$(printf '%s' "$INPUT" | tr -d '\n\r')
COMMAND=$(printf '%s' "$JOINED" \
  | grep -oE '"command"[[:space:]]*:[[:space:]]*"(\\.|[^"\\])*"' | head -1) || COMMAND=""
# A payload that names a command this lane cannot read is refused, never
# waved through: where no git hook is armed, this lane is the check.
if [ -z "$COMMAND" ]; then
  printf '%s' "$JOINED" | grep -q '"command"[[:space:]]*:' || exit 0
  echo "pre-commit-check: could not read the command out of the hook payload" >&2
  exit 2
fi
# JSON's whitespace escapes separate words too: `cargo fmt\ngit commit`
# is two commands, not one word `ngit`.
WORDS=" $(printf '%s' "$COMMAND" | sed 's/\\[ntr]/ /g' | tr -c 'a-zA-Z0-9_=-' ' ') "
printf '%s' "$WORDS" | grep -qE ' git( .*)? commit ' || exit 0

# An armed hook means git itself will gate the commit; running the chain
# here too would validate everything twice. Unless the command sidesteps
# it: git's no-verify flag — spelled out or cut to any unique prefix, as
# git allows, or `-n` alone or inside a short-flag cluster — tells git to
# skip the hook, and a `core.hooksPath` override points git at
# hooks this lane did not inspect — then git's check never happens and
# this lane is the check after all. One of those words from some other
# command on the line costs a guard run, never a check.
HOOKS_DIR=$(git rev-parse --git-path hooks 2>/dev/null) || exit 0
if [ -x "$HOOKS_DIR/pre-commit" ] \
  && ! printf '%s' "$WORDS" | grep -qE ' (--no-veri[a-z]*|-[a-zA-Z]*n[a-zA-Z]*|core hooksPath[^ ]*) '; then
  exit 0
fi

if ! command -v kendex >/dev/null 2>&1; then
  echo "pre-commit-check: no git pre-commit hook will run for this commit and the kendex binary is not on PATH, so nothing can check it — install kendex, or remove this hook" >&2
  exit 2
fi
# The frontmatter timeout budgets a cold clippy build on top of the other
# lanes; the harness cancelling this hook at that budget is the one way
# left past the gate, so the budget stays above what the chain can take.
CHAIN=$(kendex guard run pre-commit 2>&1) || {
  printf '%s\n' "$CHAIN" >&2
  echo "pre-commit-check: commit blocked by the failures above (no git pre-commit hook runs for this commit; kendex guard install arms one, which git runs unless the command bypasses it)" >&2
  exit 2
}
exit 0
