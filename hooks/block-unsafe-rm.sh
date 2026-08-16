#!/usr/bin/env bash
# ---
# name: block-unsafe-rm
# event: PreToolUse
# matcher: Bash
# description: Block a recursive rm whose path starts with a variable that may expand empty. Names the rewrite the harness accepts without a prompt.
# safety: The harness stops the whole session on that shape with a "Dangerous rm operation on possibly-empty variable path" prompt; refusing it here lets the agent rewrite and continue.
# ---

set -euo pipefail

# Read stdin with the shell builtin so the fast exit forks nothing.
INPUT=''
_line=''
while IFS= read -r _line || [ -n "$_line" ]; do
  INPUT="$INPUT$_line"
done

# Fast exit on every Bash call that carries no rm at all.
case "$INPUT" in
  *rm*) ;;
  *) exit 0 ;;
esac

if command -v jq >/dev/null 2>&1; then
  COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // .command // empty' 2>/dev/null || true)
else
  # Escape-aware fallback: the value may carry \" and \\ inside it.
  COMMAND=$(printf '%s' "$INPUT" | grep -o '"command"[[:space:]]*:[[:space:]]*"\([^"\\]\|\\.\)*"' | head -1 \
    | sed 's/^"command"[[:space:]]*:[[:space:]]*"//;s/"$//;s/\\"/"/g;s/\\\\/\\/g' 2>/dev/null || true)
fi

# One rm invocation per line: split on command separators, then keep the
# segments that start with rm (optionally under sudo/env prefixes are out of
# scope — the shape the harness prompts on is a plain rm).
SEGMENTS=$(printf '%s\n' "$COMMAND" | sed 's/\\n/\n/g' | sed -E 's/(&&|\|\||;|\|)/\n/g')

while IFS= read -r seg; do
  seg=$(printf '%s' "$seg" | sed 's/^[[:space:]]*//')
  case "$seg" in
    rm\ *) ;;
    *) continue ;;
  esac
  # Recursive form: -r/-R anywhere in a short-option cluster, or --recursive.
  printf '%s' "$seg" | grep -Eq '(^|[[:space:]])(-[a-zA-Z]*[rR][a-zA-Z]*|--recursive)([[:space:]]|$)' || continue
  # Any operand (not an option) that begins with a variable expansion whose
  # value can be empty: $NAME, ${NAME}, "$NAME/…", ${NAME:-…}. The one form
  # that cannot expand empty is ${NAME:?…}, which the harness accepts.
  for tok in $seg; do
    case "$tok" in
      -*) continue ;;
    esac
    stripped=${tok#\"}; stripped=${stripped#\'}
    case "$stripped" in
      \$\{[A-Za-z_]*:\?*) continue ;;   # ${NAME:?} — cannot expand empty
      \$*)
        {
          echo "Recursive rm on a variable-rooted path stalls the session: the harness stops on"
          echo "  $tok"
          echo "with a 'Dangerous rm operation on possibly-empty variable path' prompt."
          echo "Rewrite so the path cannot collapse to / — either form is accepted:"
          echo "  rm -rf -- \"\${NAME:?}/sub\"      (bash aborts if NAME is unset or empty)"
          echo "  rm -rf -- /absolute/literal/path"
        } >&2
        exit 2
        ;;
    esac
  done
done <<<"$SEGMENTS"

exit 0
