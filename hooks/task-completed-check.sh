#!/usr/bin/env bash
# ---
# name: task-completed-check
# event: TaskCompleted
# matcher:
# description: Before a task is marked complete, runs `cargo clippy --all-targets` once for the workspace members that own the changed Rust files, `-p` per member as the one `cargo metadata --no-deps` read names them, against the repository's Cargo.toml, or the nearest one above a changed file when the root has none, whenever a Rust file changed in the working tree, the index or as an untracked file. A failing clippy, a compile error or a deny-by-default lint, refuses the completion naming the first error lines, or the output tail when there are none; warnings complete the task and are shown as advice under a `warnings=<count>` notice. A changed Rust file no workspace member owns is not linted. Rust only. Not run on pi: the pi-hooks carrier runs its own end-of-turn clippy check, and a second run is left out. Not run on codex: it has no TaskCompleted event (Codex hooks reference, CLI 0.160.0). Not run on gemini: it has no TaskCompleted event. Not run on copilot: it has no TaskCompleted event (Copilot hooks reference, CLI 1.0.91). Not run on antigravity: it has no TaskCompleted event.
# summary: Runs clippy before a task is marked complete whenever Rust files changed, and refuses the completion with the first errors it found.
# safety: Refuses on a clippy that exits nonzero and on a `cargo metadata` read that fails, both a defect in the change. A host that cannot run the check is not the committer's to fix and is never read as a pass: a git that cannot list the changed set, or a missing cargo or jq, completes the task with one `git=<subcommand>` or `missing-tools=<list>` notice saying the change was not checked. Claude Code does not block on a hook that outruns its budget, so the budget is that harness's own default for a command hook; a cold build that outruns it completes the task unchecked, and a warm target directory is what keeps this gate closed. Every refusal and notice opens with `task-completed-check: <key>=<value>`; what a command this hook runs writes is captured at the site and replayed under that line, so nothing precedes the key.
# timeout: 600
# harnesses: [claude, opencode, cursor]
# ---

set -euo pipefail

# Consume stdin
cat > /dev/null

# The clippy lines a refusal or the warnings notice quotes, empty until there
# are any.
ISSUES=""
# Every line this hook writes, and the only place its text lives. The first
# line is the contract a reader parses, `task-completed-check: <key>=<value>`:
# a stable key for the condition and the value acted on — the git subcommand
# that could not answer, the tools missing, the status clippy left, or the
# warnings it printed. The English explanation and the diagnostics follow it.
# The keyed line stands first, at position 1. What a command this hook runs
# wrote is captured where the hook reads it and passed here as the cause, so
# it is replayed under the key rather than ahead of it.
message() { # KEY VALUE [DETAIL]
  {
    printf 'task-completed-check: %s=%s\n' "$1" "$2"
    case "$1" in
      git)
        printf 'git %s failed, so what changed is unknown; clippy did not run and the change is unchecked:\n' "$2"
        ;;
      missing-tools)
        printf '%s not on PATH; clippy did not run and the change is unchecked.\n' "$2"
        ;;
      members)
        echo "the changed Rust files could not be matched to workspace members; clippy did not run and the change is unchecked."
        ;;
      metadata)
        echo "cargo metadata failed, so the crates to lint are unknown — fix the manifest before completing the task:"
        ;;
      clippy)
        echo "Clippy failed — fix before completing task:"
        printf '%s\n' "$ISSUES"
        ;;
      warnings)
        echo "Clippy passed with warnings; worth fixing:"
        printf '%s\n' "$ISSUES"
        ;;
    esac
    # The cause a command this hook ran wrote, captured at the site and
    # replayed here: under the keyed line, never ahead of it.
    [ -z "${3:-}" ] || printf '%s\n' "$3"
  } >&2
}

refuse() { # KEY VALUE [DETAIL]
  message "$@"
  exit 2
}

# A host that cannot run the check is not the committer's to fix, so it does
# not hold the task (hooks/AGENTS.md); it is reported, never passed silently.
unchecked() { # KEY VALUE [DETAIL]
  message "$@"
  exit 0
}

git_failed() { # SUBCOMMAND OUTPUT — an unreadable changed set is not an empty one
  unchecked git "$1" "$2"
}

# rev-parse exits 128 outside a repository and inside one whose metadata it
# cannot read, and the hook has no way to tell which, so neither reads as
# "nothing changed".
REPO_ROOT=$(git rev-parse --show-toplevel 2>&1) || git_failed 'rev-parse' "$REPO_ROOT"

# Every git read that yields paths goes through here, one path per line in
# PATHS. `-z` asks for the paths themselves: line-oriented git output C-quotes a
# non-ASCII path, and a quoted path ends in a quote rather than in .rs. Only
# stdout becomes the list. A run that succeeds may still write to stderr
# (core.autocrlf's line-ending warning, the rename limit), and a warning read as
# a path would enter the changed set, so git's and tr's stderr are captured
# apart and replayed under the git= key only when the read fails.
git_paths() { # LABEL ARGS... — sets PATHS; LABEL is the git= value on failure
  local label="$1"
  shift
  PATHS=$(
    {
      cause=$( { git "$@" | tr '\0' '\n' >&3; } 2>&1) || {
        printf '%s\n' "$cause"
        exit 1
      }
    } 3>&1
  ) || git_failed "$label" "$PATHS"
}

# What counts as changed: the worktree, the index, and untracked non-ignored
# paths. Without that last set a task whose only work is an untracked file
# presents an empty changed set and skips the gate entirely.
git_paths 'diff' diff --name-only -z
CHANGED=$PATHS
git_paths 'diff --cached' diff --cached --name-only -z
STAGED=$PATHS
git_paths 'ls-files' ls-files --others --exclude-standard --full-name -z -- :/
UNTRACKED=$PATHS
ALL_CHANGED=$(printf '%s\n%s\n%s' "$CHANGED" "$STAGED" "$UNTRACKED" | sort -u | sed '/^$/d')

if [ -z "$ALL_CHANGED" ]; then
  exit 0
fi

# Check for Rust files. Neither filter may stop reading early: `grep -q` and
# `head -1` exit at their first match, and under pipefail the SIGPIPE that
# kills the producer becomes the pipeline's status — 141, read as no match.
RUST_CHANGED=$(printf '%s\n' "$ALL_CHANGED" | sed -n '/\.rs$/p')
[ -n "$RUST_CHANGED" ] || exit 0

MISSING=""
for tool in cargo jq; do
  command -v "$tool" >/dev/null 2>&1 || MISSING="$MISSING,$tool"
done
[ -z "$MISSING" ] || unchecked missing-tools "${MISSING#,}"

# Locate Cargo.toml so the hook works when the manifest is nested
# (kendex's own `cli/Cargo.toml` is the canonical case) and when the
# hook is invoked from a subdirectory. Earlier versions ran `cargo
# clippy` from cwd unconditionally and surfaced "could not find
# Cargo.toml" as a clippy error.
MANIFEST_ARGS=()
if [ ! -f "$REPO_ROOT/Cargo.toml" ]; then
  # `sed -n 1p` reads to the end, so no writer dies of SIGPIPE.
  if MANIFEST=$(printf '%s\n' "$RUST_CHANGED" | while IFS= read -r path; do
    dir=$(dirname "$path")
    while [ -n "$dir" ] && [ "$dir" != "." ] && [ "$dir" != "/" ]; do
      if [ -f "$REPO_ROOT/$dir/Cargo.toml" ]; then
        echo "$REPO_ROOT/$dir/Cargo.toml"
        break
      fi
      dir=$(dirname "$dir")
    done
  done | sed -n 1p) && [ -n "$MANIFEST" ]; then
    MANIFEST_ARGS=(--manifest-path "$MANIFEST")
  fi
fi

# The workspace members, one `<name>\t<directory>` per line, read once. Only
# stdout is JSON: a read that succeeds may still warn on stderr, so stderr is
# captured apart and replayed under the key only when the read fails.
# A repository whose root holds Cargo.toml leaves MANIFEST_ARGS empty, and
# bash 3.2 under `set -u` reads an empty array as an unbound variable.
# Hence the guarded expansion.
MEMBERS=$(
  {
    cause=$( { cargo metadata ${MANIFEST_ARGS[@]+"${MANIFEST_ARGS[@]}"} --no-deps --format-version 1 |
      jq -r '.packages[] | [.name, (.manifest_path | sub("[/\\\\][^/\\\\]*$"; ""))] | @tsv' >&3; } 2>&1) || {
      printf '%s\n' "$cause"
      exit 1
    }
  } 3>&1
) || refuse metadata failed "$MEMBERS"

# Each changed Rust file belongs to the member whose directory is its longest
# prefix; both sides are compared physically, since cargo and git may spell
# the same directory through different links. A file no member owns is not
# one clippy would lint.
REPO_REAL=$(cd "$REPO_ROOT" && pwd -P)
TAB=$(printf '\t')
OWNED=$(printf '%s\n' "$MEMBERS" | while IFS="$TAB" read -r name dir; do
  real=$(cd "$dir" 2>/dev/null && pwd -P) || continue
  printf '%s\t%s\n' "$name" "$real"
done)
PACKAGES=$(printf '%s\n' "$RUST_CHANGED" | while IFS= read -r path; do
  best=""
  best_len=0
  while IFS="$TAB" read -r name real; do
    [ -n "$real" ] || continue
    case "$REPO_REAL/$path" in
      "$real"/*)
        if [ "${#real}" -gt "$best_len" ]; then
          best=$name
          best_len=${#real}
        fi
        ;;
    esac
  done <<<"$OWNED"
  [ -z "$best" ] || printf '%s\n' "$best"
done | sort -u) || unchecked members unmatched
[ -n "$PACKAGES" ] || exit 0

PACKAGE_ARGS=()
while IFS= read -r name; do
  PACKAGE_ARGS+=(-p "$name")
done <<<"$PACKAGES"

# Errors refuse; warnings are advice, so clippy runs without `-D warnings` and
# its exit status is the verdict: nonzero only for a compile error or a
# deny-by-default lint, or a run that died, which the committer can fix.
CLIPPY_STATUS=0
OUTPUT=$(cargo clippy ${MANIFEST_ARGS[@]+"${MANIFEST_ARGS[@]}"} "${PACKAGE_ARGS[@]}" --all-targets 2>&1) ||
  CLIPPY_STATUS=$?
if [ "$CLIPPY_STATUS" -ne 0 ]; then
  # Diagnostic lines are only how the failure is reported, so a run that
  # produced none — a killed build — falls back to the tail of what it printed.
  if ! ISSUES=$(sed -n '/^error/p' <<<"$OUTPUT" | sed -n '1,15p') || [ -z "$ISSUES" ]; then
    ISSUES=$(tail -15 <<<"$OUTPUT")
  fi
  refuse clippy "$CLIPPY_STATUS"
fi

# cargo's per-crate tally (`warning: ``x`` (lib) generated 2 warnings`) is not a
# warning of its own, so it is left out of the count.
if WARNINGS=$(sed -n '/^warning/{/generated [0-9]* warning/!p;}' <<<"$OUTPUT") && [ -n "$WARNINGS" ]; then
  ISSUES=$(sed -n '1,15p' <<<"$WARNINGS")
  message warnings "$(wc -l <<<"$WARNINGS" | tr -d ' ')"
fi

exit 0
