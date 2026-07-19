#!/usr/bin/env bash
# ---
# name: pre-commit-check
# event: PreToolUse
# matcher: Bash
# description: Validate formatting and lint before git commits on source files. Rust runs cargo fmt plus a Clippy lane scoped to the staged files' packages; VSTACK_PRE_COMMIT_RUST_CLIPPY (env or vstack.settings.toml [env]) replaces the Clippy lane with a repo-owned command or "off" skips it. Biome projects (JS/TS/JSON) check staged paths.
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

# Print the last lines of a failed check's combined output so failures are
# actionable (cargo/clippy emit diagnostics on stderr; earlier versions
# discarded them and left only the generic guidance line).
print_output_tail() {
  if [ -n "$1" ]; then
    echo "$1" | tail -40 >&2
  fi
}

# Check for Rust files
if echo "$STAGED" | grep -qE '\.rs$'; then
  REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)

  # Locate Cargo.toml so the hook works in repos that nest the manifest
  # (vstack's own `cli/Cargo.toml` is the canonical example) and when
  # the hook is invoked from a subdirectory. Earlier versions ran
  # `cargo fmt --check` from cwd unconditionally and misreported "could
  # not find Cargo.toml" as a fmt failure.
  MANIFEST_ARGS=()
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
  if ! FMT_OUTPUT=$(cargo fmt ${MANIFEST_ARGS[@]+"${MANIFEST_ARGS[@]}"} --check 2>&1); then
    print_output_tail "$FMT_OUTPUT"
    echo "cargo fmt --check failed. Run 'cargo fmt' first." >&2
    exit 2
  fi

  # Clippy lane, three tiers via VSTACK_PRE_COMMIT_RUST_CLIPPY (parent env
  # wins; then the repo's vstack.settings.toml / .vstack/settings.toml [env]
  # table — parsed inline because this hook must stay self-contained):
  #   unset -> default clippy scoped to the staged files' packages
  #   "off" -> skip entirely (repo-owned validation is authoritative)
  #   other -> run verbatim via `bash -c`; its exit status decides
  CLIPPY_CMD="${VSTACK_PRE_COMMIT_RUST_CLIPPY:-}"
  if [ -z "$CLIPPY_CMD" ] && [ -n "$REPO_ROOT" ]; then
    for SETTINGS_FILE in "$REPO_ROOT/vstack.settings.toml" "$REPO_ROOT/.vstack/settings.toml"; do
      [ -f "$SETTINGS_FILE" ] || continue
      CLIPPY_CMD=$(sed -n 's/^[[:space:]]*VSTACK_PRE_COMMIT_RUST_CLIPPY[[:space:]]*=[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$SETTINGS_FILE" | head -1)
      [ -n "$CLIPPY_CMD" ] && break
    done
  fi

  if [ "$CLIPPY_CMD" = "off" ]; then
    : # Clippy lane disabled by configuration.
  elif [ -n "$CLIPPY_CMD" ]; then
    if ! CLIPPY_OUTPUT=$( (cd "${REPO_ROOT:-.}" && bash -c "$CLIPPY_CMD") 2>&1); then
      print_output_tail "$CLIPPY_OUTPUT"
      echo "configured Clippy check failed (VSTACK_PRE_COMMIT_RUST_CLIPPY): $CLIPPY_CMD" >&2
      echo "Fix the reported warnings before committing." >&2
      exit 2
    fi
  else
    # Default: scope clippy to the packages that own the staged .rs files so
    # pre-existing warnings in unrelated workspace crates can't block the
    # commit. Fall back to --workspace when no package name resolves (virtual
    # manifest, parse failure).
    PKG_NAMES=""
    if [ -n "$REPO_ROOT" ]; then
      PKG_NAMES=$(echo "$STAGED" | grep -E '\.rs$' | while IFS= read -r path; do
        dir=$(dirname "$path")
        while :; do
          if [ -f "$REPO_ROOT/$dir/Cargo.toml" ]; then
            # `name = "..."` from the [package] table only ([[bin]] and
            # dependency tables also carry `name` keys).
            awk '
              /^[[:space:]]*\[/ { in_pkg = ($0 ~ /^[[:space:]]*\[package\][[:space:]]*(#.*)?$/); next }
              in_pkg && /^[[:space:]]*name[[:space:]]*=/ {
                if (match($0, /"[^"]*"/)) { print substr($0, RSTART + 1, RLENGTH - 2) }
                exit
              }
            ' "$REPO_ROOT/$dir/Cargo.toml"
            break
          fi
          if [ "$dir" = "." ] || [ "$dir" = "/" ] || [ -z "$dir" ]; then
            break
          fi
          dir=$(dirname "$dir")
        done
      done | sort -u | grep -v '^$' || true)
    fi

    PKG_ARGS=()
    if [ -n "$PKG_NAMES" ]; then
      while IFS= read -r pkg; do
        PKG_ARGS+=(-p "$pkg")
      done <<EOF
$PKG_NAMES
EOF
    fi

    if [ -n "$PKG_NAMES" ]; then
      SCOPE_ARGS=(${PKG_ARGS[@]+"${PKG_ARGS[@]}"})
    else
      SCOPE_ARGS=(--workspace)
    fi

    if ! CLIPPY_OUTPUT=$(cargo clippy ${MANIFEST_ARGS[@]+"${MANIFEST_ARGS[@]}"} ${SCOPE_ARGS[@]+"${SCOPE_ARGS[@]}"} --all-targets -- -D warnings 2>&1); then
      print_output_tail "$CLIPPY_OUTPUT"
      echo "cargo clippy found warnings. Fix them before committing." >&2
      exit 2
    fi
  fi
fi

# Check for JS/TS/JSON files in Biome projects (no-op when the repo doesn't
# use Biome). Checks only the staged paths, so it stays fast in any repo size.
if echo "$STAGED" | grep -qE '\.(ts|tsx|js|jsx|mjs|cjs|json|jsonc)$'; then
  REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
  if [ -n "$REPO_ROOT" ] && { [ -f "$REPO_ROOT/biome.json" ] || [ -f "$REPO_ROOT/biome.jsonc" ]; }; then
    # Prefer the project-pinned binary; fall back to PATH. Never npx-install.
    BIOME=""
    if [ -x "$REPO_ROOT/node_modules/.bin/biome" ]; then
      BIOME="$REPO_ROOT/node_modules/.bin/biome"
    elif command -v biome > /dev/null 2>&1; then
      BIOME="biome"
    fi
    if [ -n "$BIOME" ]; then
      # Only staged paths that still exist (renames/deletes drop out), as
      # paths relative to the repo root since that's where biome.json lives.
      FILES=$(echo "$STAGED" | grep -E '\.(ts|tsx|js|jsx|mjs|cjs|json|jsonc)$' | while IFS= read -r path; do
        [ -f "$REPO_ROOT/$path" ] && echo "$path"
      done || true)
      if [ -n "$FILES" ]; then
        # shellcheck disable=SC2086 -- intentional word splitting of file list
        if ! OUTPUT=$(cd "$REPO_ROOT" && "$BIOME" check $FILES 2>&1); then
          echo "biome check failed on staged files. Run 'biome check --write' first." >&2
          echo "$OUTPUT" | head -20 >&2
          exit 2
        fi
      fi
    fi
  fi
fi

exit 0
