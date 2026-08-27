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

git_failed() { # SUBCOMMAND OUTPUT — an unreadable changed set is not an empty one
  echo "task-completed-check: git $1 failed, so what changed is unknown:" >&2
  printf '%s\n' "$2" >&2
  exit 2
}

# A git that cannot answer blocks, with no reading of the failure that means
# "nothing to gate": rev-parse exits 128 outside a repository and inside one
# whose metadata it cannot read, and the hook has no way to tell which.
REPO_ROOT=$(git rev-parse --show-toplevel 2>&1) || git_failed 'rev-parse' "$REPO_ROOT"

# What counts as changed: the worktree, the index, and untracked non-ignored
# paths. Without that last set a task whose only work is a new file presents
# an empty changed set and skips the gate entirely. `-z` asks for the paths
# themselves. Line-oriented git output C-quotes a non-ASCII path, and a
# quoted path ends in a quote rather than in .rs.
CHANGED=$(git diff --name-only -z 2>&1 | tr '\0' '\n') || git_failed 'diff' "$CHANGED"
STAGED=$(git diff --cached --name-only -z 2>&1 | tr '\0' '\n') ||
  git_failed 'diff --cached' "$STAGED"
UNTRACKED=$(git ls-files --others --exclude-standard --full-name -z -- :/ 2>&1 | tr '\0' '\n') ||
  git_failed 'ls-files' "$UNTRACKED"
ALL_CHANGED=$(printf '%s\n%s\n%s' "$CHANGED" "$STAGED" "$UNTRACKED" | sort -u | sed '/^$/d')

if [ -z "$ALL_CHANGED" ]; then
  exit 0
fi

# Check for Rust files. Neither filter may stop reading early: `grep -q` and
# `head -1` exit at their first match, and under pipefail the SIGPIPE that
# kills the producer becomes the pipeline's status — 141, read as no match.
RUST_CHANGED=$(printf '%s\n' "$ALL_CHANGED" | sed -n '/\.rs$/p')
if [ -n "$RUST_CHANGED" ]; then
  # Locate Cargo.toml so the hook works when the manifest is nested
  # (kendex's own `cli/Cargo.toml` is the canonical case) and when the
  # hook is invoked from a subdirectory. Earlier versions ran `cargo
  # clippy` from cwd unconditionally and surfaced "could not find
  # Cargo.toml" as a clippy error.
  MANIFEST_ARGS=()
  if [ ! -f "$REPO_ROOT/Cargo.toml" ]; then
    MANIFEST=$(printf '%s\n' "$RUST_CHANGED" | while IFS= read -r path; do
      dir=$(dirname "$path")
      while [ -n "$dir" ] && [ "$dir" != "." ] && [ "$dir" != "/" ]; do
        if [ -f "$REPO_ROOT/$dir/Cargo.toml" ]; then
          echo "$REPO_ROOT/$dir/Cargo.toml"
          break
        fi
        dir=$(dirname "$dir")
      done
    done | sed -n 1p)
    if [ -n "$MANIFEST" ]; then
      MANIFEST_ARGS=(--manifest-path "$MANIFEST")
    fi
  fi

  # A repository whose root holds Cargo.toml leaves MANIFEST_ARGS empty, and
  # bash 3.2 under `set -u` reads an empty array as an unbound variable.
  # Hence the guarded expansion.
  if ! OUTPUT=$(cargo clippy ${MANIFEST_ARGS[@]+"${MANIFEST_ARGS[@]}"} --workspace --all-targets -- -D warnings 2>&1); then
    # The exit status is the verdict. Diagnostic lines are only how the
    # failure is reported, so a run that produced none — a missing cargo, a
    # killed build — falls back to the tail of whatever it did print.
    ISSUES=$(printf '%s\n' "$OUTPUT" | grep -E '^error' | head -15 || true)
    [ -n "$ISSUES" ] || ISSUES=$(printf '%s\n' "$OUTPUT" | tail -15)
    echo "Clippy failed — fix before completing task:" >&2
    printf '%s\n' "$ISSUES" >&2
    exit 2
  fi
fi

exit 0
