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
classify_hooks_path() {
  CUSTOM_HOOKS=""
  HOOKS_PATH_SET=0
  HOOKS_PATH_ELSEWHERE=0
  CUSTOM_HOOKS="$(git -C "$REPO_ABS" config --get core.hooksPath 2>/dev/null)" \
    && HOOKS_PATH_SET=1
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
  REPO_ABS="$(cd "$REPO" && pwd)" || die "could not resolve $REPO"
  # --git-common-dir may answer relative to the repository (git predates
  # --path-format), so absolutize it here rather than assuming a git version.
  COMMON_DIR="$(git -C "$REPO_ABS" rev-parse --git-common-dir 2>/dev/null || true)"
  [ -n "$COMMON_DIR" ] || die "could not resolve the common git directory of $REPO"
  case "$COMMON_DIR" in
    /*) ;;
    *) COMMON_DIR="$REPO_ABS/$COMMON_DIR" ;;
  esac
  # From a subdirectory git answers with traversal, and every message below
  # quotes this path at somebody. It exists, so it can name itself.
  COMMON_RESOLVED="$(cd -- "$COMMON_DIR" 2>/dev/null && pwd -P)" \
    && COMMON_DIR="$COMMON_RESOLVED"
  HOOKS_DIR="$COMMON_DIR/hooks"
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

# The one remedy line for that state, so install and check say the same
# thing. Arming is not the whole of it: the installer stands down under any
# value at all, empty included, so the unset has to come first.
HOOKS_OFF_REMEDY="run 'git config --unset core.hooksPath', then 'kendex guard install'"
