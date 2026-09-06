# Take the repository lookup back out of the condition. Outside a repository
# `git rev-parse` exits 128, and under `set -e` the bare assignment carries
# that status out before the refusal below can print: the run dies at 128 with
# nothing on either stream, which is the defect KEN-1193 fixed. The `if false`
# keeps the continuation line and the refusal block parsing.
control_expect "a subcommand run outside a git repository exits 1, not git's bare 128"
control_replace scripts/lib/common.sh 1 \
    'if ! PROJECT_ROOT_RAW="$(git rev-parse --show-toplevel 2>/dev/null)" \' \
    'PROJECT_ROOT_RAW="$(git rev-parse --show-toplevel 2>/dev/null)"; if false \'
