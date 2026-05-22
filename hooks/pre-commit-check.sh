#!/usr/bin/env bash
# ---
# name: pre-commit-check
# event: PreToolUse
# matcher: Bash
# description: Validate formatting and lint before git commits on source files. Currently supports Rust (cargo fmt + clippy).
# safety: Prevents committing code that fails format or lint checks.
# ---

set -euo pipefail

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | grep -o '"command"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"command"[[:space:]]*:[[:space:]]*"//;s/"$//' 2>/dev/null || true)

# Only relevant for git commit commands
if ! echo "$COMMAND" | grep -qE 'git[[:space:]]+commit'; then
  exit 0
fi

# Check staged files
STAGED=$(git diff --cached --name-only 2>/dev/null || true)
if [ -z "$STAGED" ]; then
  exit 0
fi

# Check for Rust files
if echo "$STAGED" | grep -qE '\.rs$'; then
  # Locate Cargo.toml so the hook works in repos that nest the manifest
  # (vstack's own `cli/Cargo.toml` is the canonical example) and when
  # the hook is invoked from a subdirectory. Earlier versions ran
  # `cargo fmt --check` from cwd unconditionally and misreported "could
  # not find Cargo.toml" as a fmt failure.
  MANIFEST_ARGS=()
  REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
  if [ -n "$REPO_ROOT" ] && [ ! -f "$REPO_ROOT/Cargo.toml" ]; then
    MANIFEST=$(echo "$STAGED" | grep -E '\.rs$' | while IFS= read -r path; do
      dir=$(dirname "$path")
      while [ -n "$dir" ] && [ "$dir" != "." ] && [ "$dir" != "/" ]; do
        if [ -f "$REPO_ROOT/$dir/Cargo.toml" ]; then
          echo "$REPO_ROOT/$dir/Cargo.toml"
          break
        fi
        dir=$(dirname "$dir")
      done
    done | head -1)
    if [ -n "$MANIFEST" ]; then
      MANIFEST_ARGS=(--manifest-path "$MANIFEST")
    fi
  fi

  # Format check
  if ! cargo fmt "${MANIFEST_ARGS[@]}" --check 2>/dev/null; then
    echo "cargo fmt --check failed. Run 'cargo fmt' first." >&2
    exit 2
  fi

  # Clippy check
  if ! cargo clippy "${MANIFEST_ARGS[@]}" --workspace --all-targets -- -D warnings 2>/dev/null; then
    echo "cargo clippy found warnings. Fix them before committing." >&2
    exit 2
  fi
fi

exit 0
