#!/usr/bin/env bash
# ---
# name: pre-commit-check
# event: PreToolUse
# matcher: Bash
# description: Validate formatting and lint before git commits on source files. Rust runs cargo fmt plus a Clippy lane scoped per staged file's owning crate manifest (workspace-excluded crates included); KENDEX_PRE_COMMIT_RUST_CLIPPY (env or kendex.settings.toml [env]) replaces the Clippy lane with a repo-owned command or "off" skips it. Biome projects (JS/TS/JSON) check staged paths.
# safety: Prevents committing code that fails format or lint checks.
# ---

set -euo pipefail

INPUT=$(cat)
# The payload is JSON, and a quoted path — `git -C "$repo" commit`, which is
# what a path with a space requires — arrives with its quotes escaped. A
# reader that stops at the first `"` sees `git -C \` and finds no commit,
# so every check below passes a command it never looked at.
# `block-repo-copy.sh` decodes the same field the same way.
COMMAND=""
decoded=0
if command -v jq >/dev/null 2>&1; then
  # jq's own exit status decides: 2 means it could not read the payload at
  # all, and a swallowed 2 would leave COMMAND empty and every lane below
  # skipped on a commit nobody inspected.
  if COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // .command // ""' 2>/dev/null); then
    decoded=1
  fi
fi
if [ "$decoded" -eq 0 ]; then
  COMMAND=$(printf '%s' "$INPUT" \
    | grep -oE '"command"[[:space:]]*:[[:space:]]*"(\\.|[^"\\])*"' \
    | head -1 \
    | sed 's/.*"command"[[:space:]]*:[[:space:]]*"//; s/"$//' \
    | sed 's/\\n/ /g; s/\\t/ /g; s/\\"/"/g; s/\\\\/\\/g') || COMMAND=""
fi

# A payload carrying no command is not a commit and passes; one that carries
# a command the decoder could not recover is refused, because the checks
# below would otherwise run on an empty string and report success for a
# commit they never saw. `block-repo-copy.sh` draws the same line.
if [ -z "$COMMAND" ] && printf '%s' "$INPUT" | grep -q '"command"[[:space:]]*:'; then
  echo "pre-commit-check: could not read the command out of the hook payload" >&2
  exit 2
fi

# Whether a command commits must never come back "no" because of how it was
# quoted: a no skips every check below, so a wrong no is a commit nobody
# inspected. `git -C "/my repo" commit`, `env X=1 git commit`, a commit
# behind `&&` — each of those needs its own case in a parser, and the cases
# nobody thought of are exactly the ones that fail open. So this does not
# parse. It asks whether the words `git` and `commit` both appear, in that
# order. `git log --grep=commit` pays for that with a lint run it did not
# need, which is the side worth being wrong on.
FLAT=$(printf '%s' "$COMMAND" | tr '\n\t' '  ')
WORDS=" $(printf '%s' "$FLAT" | tr -c 'a-zA-Z0-9_=-' ' ') "
if ! printf '%s' "$WORDS" | grep -qE ' git( .*)? commit '; then
  exit 0
fi

# Split a command into shell words with quotes honoured. Nothing is
# evaluated: this walks characters and tracks which quote is open, so
# `-C "/my repo"` stays one word instead of becoming `"/my` and `repo"` —
# a directory that does not exist, which drops the checks back onto the
# hook's own cwd and answers for another repository's staged work.
TOKENS=()
tokenize() {
  local s=$1 i=0 c quote='' word='' started=0
  TOKENS=()
  while [ "$i" -lt "${#s}" ]; do
    c=${s:$i:1}
    i=$((i + 1))
    if [ -n "$quote" ]; then
      if [ "$c" = "$quote" ]; then
        quote=''
      elif [ "$c" = '\' ] && [ "$quote" = '"' ]; then
        word+=${s:$i:1}
        i=$((i + 1))
      else
        word+=$c
      fi
      continue
    fi
    case $c in
      "'" | '"')
        quote=$c
        started=1
        ;;
      ' ')
        if [ "$started" -eq 1 ]; then
          TOKENS+=("$word")
          word=''
          started=0
        fi
        ;;
      '\')
        word+=${s:$i:1}
        i=$((i + 1))
        started=1
        ;;
      *)
        word+=$c
        started=1
        ;;
    esac
  done
  if [ "$started" -eq 1 ]; then
    TOKENS+=("$word")
  fi
}

# Where the commit lands, which is not always where this hook started: a
# session working in a git worktree commits with `git -C <path>` or a
# `cd <path> &&` prefix. Reading the staged set from the wrong place answers
# for another repository's work — either blocking a commit it has nothing to
# do with, or clearing one nobody checked.
#
# A command is a sequence of segments, so the `-C` that counts is the one
# belonging to the git that commits: in `git -C clean status && git -C dirty
# commit` the first names a repository this hook must not answer for.
git_home=${HOME:-}

# Join a path onto the running target the way the shell would.
move_target() {
  local path=$1
  case $path in
    '~') path=$git_home ;;
    '~/'*) path=$git_home/${path#'~/'} ;;
  esac
  case $path in
    /*) TARGET_DIR=$path ;;
    *) TARGET_DIR=${TARGET_DIR:-.}/$path ;;
  esac
}

tokenize "$FLAT"
TARGET_DIR=""
committing=0
at_segment_start=1
i=0
n=${#TOKENS[@]}
while [ "$i" -lt "$n" ]; do
  token=${TOKENS[$i]}
  case $token in
    '&&' | '||' | ';' | '|' | '&')
      at_segment_start=1
      i=$((i + 1))
      continue
      ;;
  esac
  # A `cd` ahead of the commit moves it; one after belongs to whatever comes
  # next and must not drag the check along with it.
  if [ "$at_segment_start" -eq 1 ] && [ "$token" = "cd" ] && [ "$committing" -eq 0 ]; then
    j=$((i + 1))
    [ "${TOKENS[$j]:-}" = "--" ] && j=$((j + 1))
    [ -n "${TOKENS[$j]:-}" ] && move_target "${TOKENS[$j]}"
    at_segment_start=0
    i=$((i + 1))
    continue
  fi
  at_segment_start=0
  case $token in
    git | */git) ;;
    *)
      i=$((i + 1))
      continue
      ;;
  esac
  # git's own options sit between it and the subcommand, and these carry
  # their value in the next word, so the subcommand is not what follows them.
  pending=()
  j=$((i + 1))
  while [ "$j" -lt "$n" ]; do
    case ${TOKENS[$j]} in
      -C)
        pending+=("${TOKENS[$((j + 1))]:-}")
        j=$((j + 2))
        ;;
      -C?*)
        pending+=("${TOKENS[$j]#-C}")
        j=$((j + 1))
        ;;
      -c | --git-dir | --work-tree | --namespace | --exec-path | --config-env)
        j=$((j + 2))
        ;;
      -*) j=$((j + 1)) ;;
      *) break ;;
    esac
  done
  if [ "${TOKENS[$j]:-}" = "commit" ]; then
    committing=$((committing + 1))
    for path in ${pending[@]+"${pending[@]}"}; do
      move_target "$path"
    done
  fi
  i=$((j + 1))
done

if [ "$committing" -gt 1 ]; then
  echo "pre-commit-check: more than one commit in this command — run them separately so each is checked" >&2
  exit 2
fi

# A named target this hook cannot enter is refused, never dropped. A path
# the shell expands and this reader cannot — `git -C "$repo" commit` — used
# to fall back to the checkout the hook started in, so the commit landed
# somewhere nothing had looked at and the run reported success.
if [ -n "$TARGET_DIR" ] && ! cd "$TARGET_DIR" 2>/dev/null; then
  echo "pre-commit-check: cannot enter '$TARGET_DIR' — name the repository with a literal path so its commit can be checked" >&2
  exit 2
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
  # (kendex's own `cli/Cargo.toml` is the canonical example) and when
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

  # Clippy lane, three tiers via KENDEX_PRE_COMMIT_RUST_CLIPPY (parent env
  # wins; then the repo's kendex.settings.toml / .kendex/settings.toml [env]
  # table — parsed inline because this hook must stay self-contained):
  #   unset -> default clippy scoped per staged file's owning crate manifest
  #   "off" -> skip entirely (repo-owned validation is authoritative)
  #   other -> run verbatim via `bash -c`; its exit status decides
  CLIPPY_CMD="${KENDEX_PRE_COMMIT_RUST_CLIPPY:-}"
  if [ -z "$CLIPPY_CMD" ] && [ -n "$REPO_ROOT" ]; then
    for SETTINGS_FILE in "$REPO_ROOT/kendex.settings.toml" "$REPO_ROOT/.kendex/settings.toml"; do
      [ -f "$SETTINGS_FILE" ] || continue
      CLIPPY_CMD=$(sed -n 's/^[[:space:]]*KENDEX_PRE_COMMIT_RUST_CLIPPY[[:space:]]*=[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$SETTINGS_FILE" | head -1)
      [ -n "$CLIPPY_CMD" ] && break
    done
  fi

  if [ "$CLIPPY_CMD" = "off" ]; then
    : # Clippy lane disabled by configuration.
  elif [ -n "$CLIPPY_CMD" ]; then
    if ! CLIPPY_OUTPUT=$( (cd "${REPO_ROOT:-.}" && bash -c "$CLIPPY_CMD") 2>&1); then
      print_output_tail "$CLIPPY_OUTPUT"
      echo "configured Clippy check failed (KENDEX_PRE_COMMIT_RUST_CLIPPY): $CLIPPY_CMD" >&2
      echo "Fix the reported warnings before committing." >&2
      exit 2
    fi
  else
    # Default: run clippy once per owning manifest — the nearest Cargo.toml
    # with a [package] table above each staged .rs file. --manifest-path
    # scopes cargo's default package selection to that package whether or
    # not it is a member of the root workspace, so crates on the workspace
    # `exclude` list lint against their own manifest instead of failing
    # `-p` resolution from the repo root (kendex#742), and pre-existing
    # warnings in unrelated workspace crates can't block the commit. Fall
    # back to a single --workspace run when no owning manifest resolves
    # (virtual manifest only, files outside any package).
    OWNING_MANIFESTS=""
    if [ -n "$REPO_ROOT" ]; then
      OWNING_MANIFESTS=$(echo "$STAGED" | grep -E '\.rs$' | while IFS= read -r path; do
        dir=$(dirname "$path")
        while :; do
          if [ "$dir" = "." ]; then
            candidate="$REPO_ROOT/Cargo.toml"
          else
            candidate="$REPO_ROOT/$dir/Cargo.toml"
          fi
          if [ -f "$candidate" ]; then
            # Only a manifest with a [package] table owns files; a virtual
            # workspace manifest has no default package to scope to.
            if grep -qE '^[[:space:]]*\[package\][[:space:]]*(#.*)?$' "$candidate"; then
              echo "$candidate"
            fi
            break
          fi
          if [ "$dir" = "." ] || [ "$dir" = "/" ] || [ -z "$dir" ]; then
            break
          fi
          dir=$(dirname "$dir")
        done
      done | sort -u | grep -v '^$' || true)
    fi

    if [ -n "$OWNING_MANIFESTS" ]; then
      while IFS= read -r manifest; do
        if ! CLIPPY_OUTPUT=$(cargo clippy --manifest-path "$manifest" --all-targets -- -D warnings 2>&1); then
          print_output_tail "$CLIPPY_OUTPUT"
          echo "cargo clippy found warnings in $manifest. Fix them before committing." >&2
          exit 2
        fi
      done <<EOF
$OWNING_MANIFESTS
EOF
    else
      if ! CLIPPY_OUTPUT=$(cargo clippy ${MANIFEST_ARGS[@]+"${MANIFEST_ARGS[@]}"} --workspace --all-targets -- -D warnings 2>&1); then
        print_output_tail "$CLIPPY_OUTPUT"
        echo "cargo clippy found warnings. Fix them before committing." >&2
        exit 2
      fi
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
        # --no-errors-on-unmatched: biome EXITS NON-ZERO when every path it was
        # given is excluded by biome.json ("No files were processed"). A commit
        # touching only ignored paths — re-vendoring a bundled dependency is the
        # canonical case — is then unblockable: the files are ignored precisely
        # because they must not be linted, and no amount of `biome check --write`
        # makes them processable. Without this flag the hook reports a lint
        # failure for a commit that has nothing to lint.
        # Intentional word splitting of the file list:
        # shellcheck disable=SC2086
        if ! OUTPUT=$(cd "$REPO_ROOT" && "$BIOME" check --no-errors-on-unmatched $FILES 2>&1); then
          echo "biome check failed on staged files. Run 'biome check --write' first." >&2
          echo "$OUTPUT" | head -20 >&2
          exit 2
        fi
      fi
    fi
  fi
fi

# Preflight lane (no-op when the skill isn't installed): diff-scoped
# deterministic checks on the staged change — shell syntax + fail-open lint,
# dead doc citations, unlinked TODOs, JSON/TOML syntax. High-precision,
# fail-only; its findings are always real defects to fix before committing.
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [ -n "$REPO_ROOT" ]; then
  for PREFLIGHT in "$REPO_ROOT/.agents/skills/preflight/scripts/preflight" "$REPO_ROOT/skills/preflight/scripts/preflight"; do
    [ -x "$PREFLIGHT" ] || continue
    if ! PREFLIGHT_OUTPUT=$("$PREFLIGHT" --staged --repo "$REPO_ROOT" 2>&1); then
      print_output_tail "$PREFLIGHT_OUTPUT"
      echo "preflight found defects in the staged change. Fix them before committing." >&2
      exit 2
    fi
    break
  done

  # Size-ratchet lane: runs only in repos that adopted the ratchet (a baseline
  # exists at the configured or default path), so installing the skill alone
  # never starts enforcing. The script is the single source of truth — same
  # verdict the CI gate gives, moved to commit time; its diagnostics name the
  # remedy (split the file, or hand-lower the baseline row in a reviewed diff).
  # Any nonzero — violations (1) or could-not-measure (2) — blocks, matching
  # the gate's never-degrade-to-passing contract; CI remains the backstop.
  for RATCHET in "$REPO_ROOT/.agents/skills/size-ratchet/scripts/size-ratchet" "$REPO_ROOT/skills/size-ratchet/scripts/size-ratchet"; do
    [ -x "$RATCHET" ] || continue
    SR_BASELINE="${SIZE_RATCHET_BASELINE:-}"
    if [ -z "$SR_BASELINE" ]; then
      for SETTINGS_FILE in "$REPO_ROOT/kendex.settings.toml" "$REPO_ROOT/.kendex/settings.toml"; do
        [ -f "$SETTINGS_FILE" ] || continue
        SR_BASELINE=$(sed -n 's/^[[:space:]]*SIZE_RATCHET_BASELINE[[:space:]]*=[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$SETTINGS_FILE" | head -1)
        [ -n "$SR_BASELINE" ] && break
      done
    fi
    SR_BASELINE="${SR_BASELINE:-tools/size-ratchet-baseline.tsv}"
    case "$SR_BASELINE" in /*) ;; *) SR_BASELINE="$REPO_ROOT/$SR_BASELINE" ;; esac
    if [ -f "$SR_BASELINE" ]; then
      if ! RATCHET_OUTPUT=$(cd "$REPO_ROOT" && "$RATCHET" 2>&1); then
        print_output_tail "$RATCHET_OUTPUT"
        echo "size-ratchet blocked the commit. Split the offending file, or hand-lower its baseline row (tighten-only) as part of this change." >&2
        exit 2
      fi
    fi
    break
  done
fi

exit 0
