#!/usr/bin/env bash
# ---
# name: task-completed-check
# event: TaskCompleted
# matcher:
# description: Before a task is marked complete, runs `cargo clippy --workspace --all-targets -- -D warnings` against the repository's Cargo.toml, or the nearest one above a changed file when the root has none, whenever a Rust file changed in the working tree, the index or as an untracked file, and refuses the completion naming the first error lines, or the output tail when there are none. Rust only.
# safety: Refuses on any clippy failure and on a git that cannot list the changed set. Claude Code does not block on a hook that outruns its budget, so the budget is that harness's own default for a command hook; a cold build of a large workspace that outruns it completes the task unchecked, and a warm target directory is what keeps this gate closed. Refusals carry the line `task-completed-check: <key>=<value>`; a reader matches that prefix, not line 1, because a command this hook runs may write its own diagnostic first.
# timeout: 600
# harnesses: [claude-code]
# ---

set -euo pipefail

# Consume stdin
cat > /dev/null

# The clippy lines the refusal quotes, empty until there are any.
ISSUES=""
# Every line this hook writes, and the only place its text lives. The first
# line is the contract a reader parses, `task-completed-check: <key>=<value>`:
# a stable key for the condition and the value acted on — the git subcommand
# that could not answer, or the status clippy left. The English explanation and
# the diagnostics follow it.
# A reader matches `^task-completed-check: `, not line 1: a command this hook
# runs may write its own diagnostic to the same stream first, and that line
# names a cause the keyed one does not carry.
refuse() { # KEY VALUE [DETAIL]
  {
    printf 'task-completed-check: %s=%s\n' "$1" "$2"
    case "$1" in
      git)
        printf 'git %s failed, so what changed is unknown:\n' "$2"
        printf '%s\n' "${3:-}"
        ;;
      clippy)
        echo "Clippy failed — fix before completing task:"
        printf '%s\n' "$ISSUES"
        ;;
    esac
  } >&2
  exit 2
}

git_failed() { # SUBCOMMAND OUTPUT — an unreadable changed set is not an empty one
  refuse git "$1" "$2"
}

# A git that cannot answer blocks, with no reading of the failure that means
# "nothing to gate": rev-parse exits 128 outside a repository and inside one
# whose metadata it cannot read, and the hook has no way to tell which.
REPO_ROOT=$(git rev-parse --show-toplevel 2>&1) || git_failed 'rev-parse' "$REPO_ROOT"

# What counts as changed: the worktree, the index, and untracked non-ignored
# paths. Without that last set a task whose only work is an untracked file
# presents an empty changed set and skips the gate entirely. `-z` asks for the paths
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
  CLIPPY_STATUS=0
  OUTPUT=$(cargo clippy ${MANIFEST_ARGS[@]+"${MANIFEST_ARGS[@]}"} --workspace --all-targets -- -D warnings 2>&1) ||
    CLIPPY_STATUS=$?
  if [ "$CLIPPY_STATUS" -ne 0 ]; then
    # The exit status is the verdict, and it is what the first line carries: a
    # missing cargo and a lint failure leave different ones. Diagnostic lines
    # are only how the failure is reported, so a run that produced none — a
    # missing cargo, a killed build — falls back to the tail of what it printed.
    ISSUES=$(printf '%s\n' "$OUTPUT" | grep -E '^error' | head -15 || true)
    [ -n "$ISSUES" ] || ISSUES=$(printf '%s\n' "$OUTPUT" | tail -15)
    refuse clippy "$CLIPPY_STATUS"
  fi
fi

exit 0
