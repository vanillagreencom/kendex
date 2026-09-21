#!/usr/bin/env bash
# The one reading of a linked worktree's `.git` file. Git writes
# `gitdir: <clone>/.git/worktrees/<name>` there, and a caller holding that
# file's bytes composes paths on the directory it names: the hosted mail read
# resolves the clone from it, and a hosted launch writes its lane marker under
# the common git directory it names. Both would otherwise spell the same
# shape, and a lane whose marker lands anywhere else is handed no mail at all.

# Print the absolute common git directory a worktree's `.git` file names.
# Returns 1 on any other content, including a `.git` directory's own bytes and
# a relative gitdir, neither of which names a path a remote caller can use.
lane_gitfile_common_dir() { # GITFILE_CONTENT
  local line="$1"
  case "$line" in
    "gitdir: /"*/.git/worktrees/*) ;;
    *) return 1 ;;
  esac
  line="${line#gitdir: }"
  printf '%s\n' "${line%/worktrees/*}"
}
