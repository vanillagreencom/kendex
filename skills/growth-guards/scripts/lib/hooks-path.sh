# shellcheck shell=bash
# What core.hooksPath means for THIS repository, asked once for every mode.
#
# Sourced by install-git-hooks, which owns REPO_ABS and HOOKS_DIR. Reads
# only: it decides which directory git executes hooks from and whether that
# is the directory this installer writes, and answers in three variables —
# CUSTOM_HOOKS (the configured value), HOOKS_PATH_SET, HOOKS_PATH_ELSEWHERE.
# Strict on its own terms rather than on its caller's: a reader of one of
# these functions should not have to go find out which shell options were on
# when the file was read.
set -euo pipefail

# Set at all means somewhere this installer does not write, and that is the
# whole of the classification.
#
# It used to work out whether the configured directory was in fact this
# repository's own — resolving on disk, folding `..` on paper, absolutizing
# a relative value against the work tree. Each of those was correct and each
# was another place to be subtly wrong: a `..` folded across a symlink named
# a foreign directory the default, and a relative value resolved from the
# wrong base stood an install down over a repository's own hooks. The
# question is not worth its failure modes. Set means stand down, which costs
# an arming somebody can still do by wiring the directory themselves, and
# never writes shims into a directory git does not read.
#
# The empty value is still told apart from a path, in the MESSAGE only:
# unsetting it and wiring a directory are different things to be told to do.
# Exit 1 is git for "not set", and it is the only answer that means
# unredirected. `&&` treated every other status the same way — a broken
# .git/config exits 128 — so a repository whose configuration could not be
# read was classified "hooks are where I expect", and --check could print
# armed while git took its hooks from a redirect nobody managed to see.
#
# Returns 2 for that state. Its callers stop: --check exits 2 (could not
# determine), and a mode that writes dies rather than arming a directory it
# has not established git reads.
classify_hooks_path() { # -> 0 classified, 2 could not read the config
  local status=0
  CUSTOM_HOOKS=""
  HOOKS_PATH_SET=0
  HOOKS_PATH_ELSEWHERE=0
  gg_git_path CUSTOM_HOOKS "$REPO_ABS" config --get core.hooksPath || status=$?
  case "$status" in
    0) HOOKS_PATH_SET=1 ;;
    1) ;;
    *) return 2 ;;
  esac
  HOOKS_PATH_ELSEWHERE="$HOOKS_PATH_SET"
  return 0
}

# The three roots every hooks question is asked against, from the one place
# that asks them: where the caller stands, where git runs a hook from, and
# which directory git would read hooks from with nothing in the way.
#
# Sets REPO_ABS, COMMON_DIR and HOOKS_DIR. Uses `die` from
# install-git-hooks, which is the only caller.
resolve_roots() {
  gg_path REPO_ABS gg_physical "$REPO" || die "could not resolve $REPO"
  # --git-common-dir may answer relative to the repository (git predates
  # --path-format), so absolutize it here rather than assuming a git version.
  gg_git_path COMMON_DIR "$REPO_ABS" rev-parse --git-common-dir || COMMON_DIR=""
  [ -n "$COMMON_DIR" ] || die "could not resolve the common git directory of $REPO"
  case "$COMMON_DIR" in
    /*) ;;
    *) COMMON_DIR="$REPO_ABS/$COMMON_DIR" ;;
  esac
  # From a subdirectory git answers with traversal, and every message below
  # quotes this path at somebody. It exists, so it can name itself.
  gg_path COMMON_RESOLVED gg_physical "$COMMON_DIR" \
    && COMMON_DIR="$COMMON_RESOLVED"
  HOOKS_DIR="$COMMON_DIR/hooks"
}

# The classification, and what every mode does when it cannot be made.
#
# Never a pass and never a write: whether git reads hooks from the directory
# this installer writes is exactly what could not be established, so --check
# says so and a mode that writes dies rather than arming a directory it has
# not shown git reads.
classify_hooks_path_or_stop() {
  local status=0
  classify_hooks_path || status=$?
  [ "$status" -eq 0 ] && return 0
  if [ "$MODE" = "check" ]; then
    echo "growth-guards git hooks: could not determine whether the shims are armed — core.hooksPath could not be read in $REPO_ABS"
    exit 2
  fi
  die "could not read core.hooksPath in $REPO_ABS"
}

# core.hooksPath set to the empty string switches git hooks off outright.
#
# Its own question because git's answer about it misleads everywhere else:
# `rev-parse --git-path hooks` reports `./`, so every caller that resolves
# the directory would measure the repository ROOT in place of a directory
# git never reads — and a root holding the right shapes then reads as armed
# for a repository whose commits nothing gates. Callers ask this before they
# resolve anything.
hooks_path_off() { # -> 0 when hooks are switched off
  [ "$HOOKS_PATH_SET" -eq 1 ] && [ -z "$CUSTOM_HOOKS" ]
}

# The remedy is git's own accounting of the value, printed, not a command
# this file composed.
#
# Composing one has been wrong twice. The first spelling unset the local
# file for a value that lived elsewhere; the second read the scope and still
# had to be right about `--unset-all`, about an `include.path` bringing the
# key in from a file no scope names, and about a second file the winning
# value shadows. Each of those is this tool predicting what somebody's
# configuration will do to a command it wrote for them, and each prediction
# has been a finding.
#
# git already knows. `--show-origin --show-scope --get-all` names every file
# and every scope that contributes the key — an included file appears under
# the scope that pulled it in, with its own path, which is exactly the file
# a scoped `--unset` would miss. Printing that verbatim leaves nothing
# composed to be wrong about, and points the instruction at the files rather
# than at a command.
#
# Arming is not the whole of it: the installer stands down under any value
# at all, empty included, so the unset comes first.
HOOKS_PATH_REMEDY="unset core.hooksPath in each file listed above, then run 'kendex guard install'"

# Both modes print this block, so both say the same thing about the same
# repository. It goes to stderr in each: --check keeps one verdict line on
# stdout, and the install lane already reports there.
hooks_path_origins() { # -> git's accounting of core.hooksPath, on stderr
  echo "  core.hooksPath is set from:" >&2
  # git's own words, indented and otherwise untouched. A listing git will not
  # produce is not stood in for — an invented origin is the composing this
  # function exists to stop — so the command to run by hand is named instead.
  if ! git -C "$REPO_ABS" config --show-origin --show-scope --get-all core.hooksPath 2>/dev/null \
    | sed 's/^/    /' >&2; then
    echo "    (git would not list them; run: git -C $REPO_ABS config --show-origin --show-scope --get-all core.hooksPath)" >&2
  fi
  echo "  $HOOKS_PATH_REMEDY" >&2
}
