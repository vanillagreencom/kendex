#!/usr/bin/env bash
# ---
# name: task-completed-check
# event: TaskCompleted
# matcher:
# description: Run workspace lint checks before marking a task complete. Currently supports Rust (cargo clippy).
# safety: Prevents marking tasks done when source files have lint violations.
# timeout: 120
# harnesses: [claude-code]
# ---

set -euo pipefail

# Consume stdin
cat > /dev/null

# Check for changed source files
CHANGED=$(git diff --name-only 2>/dev/null || true)
STAGED=$(git diff --cached --name-only 2>/dev/null || true)
ALL_CHANGED=$(printf '%s\n%s' "$CHANGED" "$STAGED" | sort -u | grep -v '^$' || true)

if [ -z "$ALL_CHANGED" ]; then
  exit 0
fi

# Check for Rust files
if echo "$ALL_CHANGED" | grep -qE '\.rs$'; then
  # Locate Cargo.toml so the hook works when the manifest is nested
  # (vstack's own `cli/Cargo.toml` is the canonical case) and when the
  # hook is invoked from a subdirectory. Earlier versions ran `cargo
  # clippy` from cwd unconditionally and surfaced "could not find
  # Cargo.toml" as a clippy error.
  MANIFEST_ARGS=()
  REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
  if [ -n "$REPO_ROOT" ] && [ ! -f "$REPO_ROOT/Cargo.toml" ]; then
    MANIFEST=$(echo "$ALL_CHANGED" | grep -E '\.rs$' | while IFS= read -r path; do
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

  OUTPUT=$(cargo clippy "${MANIFEST_ARGS[@]}" --workspace --all-targets -- -D warnings 2>&1 || true)
  # grep no-match exits 1 — swallow under pipefail so an empty result is success.
  ISSUES=$(echo "$OUTPUT" | grep -E '^error' | head -15 || true)

  if [ -n "$ISSUES" ]; then
    echo "Clippy errors found — fix before completing task:" >&2
    echo "$ISSUES" >&2
    exit 2
  fi
fi

exit 0
