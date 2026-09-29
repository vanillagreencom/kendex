# shellcheck shell=bash
# ONE JUDGE OF THE GIT ENVIRONMENT these suites run in. Sourced by every suite
# or world lib that shells out to git, before it builds a fixture; never run as
# a suite: the runners glob tests/*.sh, so the subdirectory and the .bash name
# keep this file out of every run.
#
# GIT_DIR, GIT_COMMON_DIR, GIT_WORK_TREE and GIT_INDEX_FILE, which a pre-commit
# hook exports, outrank `git -C`, so inheriting one points a fixture's git
# calls at the caller's repository instead of the row's. All four go together:
# clearing GIT_DIR alone leaves GIT_WORK_TREE pointing elsewhere.
#
# The caller's config shapes what git prints: core.abbrev lengthens a diff's
# index line, so a row pinning the byte length of `git diff` reads the
# developer's config instead of the script. The system and global files are
# replaced with nothing, and the config git carries in the environment goes
# too: it exports GIT_CONFIG_PARAMETERS into hooks whenever a caller used
# `git -c`, and with GIT_CONFIG_COUNT unset it reads no GIT_CONFIG_KEY_n.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
unset GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
