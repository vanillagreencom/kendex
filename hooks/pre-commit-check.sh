#!/usr/bin/env bash
# ---
# name: pre-commit-check
# event: PreToolUse
# matcher: Bash
# description: On a git commit, defer to the repository's armed git pre-commit hook (kendex guard install arms one); where none is armed, run the kendex guard pre-commit chain — format, lint, and commit guards — from the working directory as the fallback gate.
# safety: Prevents committing unchecked code in repositories without an armed git pre-commit hook.
# ---

set -euo pipefail

INPUT=$(cat)

# Word-order detection, no shell parsing: the authoritative check is the
# repository's own git pre-commit hook, which git runs in the right repo
# whatever the command's quoting, substitutions, or directory hops. This
# lane only decides whether to consult the fallback, so a miss here skips
# feedback, never a check — and `git log --grep=commit` merely pays for a
# guard run it did not need.
COMMAND=$(printf '%s' "$INPUT" \
  | grep -oE '"command"[[:space:]]*:[[:space:]]*"(\\.|[^"\\])*"' | head -1) || COMMAND=""
WORDS=" $(printf '%s' "$COMMAND" | tr -c 'a-zA-Z0-9_=-' ' ') "
printf '%s' "$WORDS" | grep -qE ' git( .*)? commit ' || exit 0

# An armed hook means git itself will gate the commit; running the chain
# here too would validate everything twice.
HOOKS_DIR=$(git rev-parse --git-path hooks 2>/dev/null) || exit 0
[ -x "$HOOKS_DIR/pre-commit" ] && exit 0

if ! command -v kendex >/dev/null 2>&1; then
  echo "pre-commit-check: no git pre-commit hook is armed here and the kendex binary is not on PATH, so nothing can check this commit — install kendex, or remove this hook" >&2
  exit 2
fi
CHAIN=$(kendex guard run pre-commit 2>&1) || {
  printf '%s\n' "$CHAIN" >&2
  echo "pre-commit-check: commit blocked by the failures above (no git pre-commit hook is armed here; kendex guard install moves this gate into git itself)" >&2
  exit 2
}
exit 0
