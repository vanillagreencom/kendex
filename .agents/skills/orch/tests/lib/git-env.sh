#!/usr/bin/env bash
# The git environment every orch suite must not inherit. Sourced as the first
# thing each suite does, before it builds a fixture or invokes a script.
#
# GIT_DIR, GIT_COMMON_DIR, GIT_WORK_TREE and GIT_INDEX_FILE outrank
# `git -C <path>`, so a suite that inherits them builds its fixtures inside the
# caller's repository instead of its own sandbox. The suite still prints
# `pass: N  fail: 0` and exits 0 while its commits land in the wrong repository
# and that repository's index is left carrying deletions of fixture paths, so
# the corruption is silent. ../git-env-isolation.test.sh demonstrates the
# misdirected writes.
#
# All four go together. Clearing GIT_DIR alone leaves GIT_WORK_TREE pointing
# the work tree elsewhere, which turns the same inheritance into an abort
# naming the wrong cause ("not inside a git work tree").
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
