# shellcheck shell=bash
#
# Orch entry point for the shared repository resolver.
#
# Source this file; do not execute it directly.

_ORCH_GH_REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ORCH_SHARED_GH_REPO="$_ORCH_GH_REPO_DIR/../../../github/scripts/lib/gh-repo.sh"
if [[ ! -f "$_ORCH_SHARED_GH_REPO" ]]; then
  {
    printf 'gh-repo: helper-missing path=%s\n' "$_ORCH_SHARED_GH_REPO"
    printf '%s\n' "orch gh-repo: shared repository resolver not found at $_ORCH_SHARED_GH_REPO"
  } >&2
  return 1 2>/dev/null || exit 1
fi
# shellcheck source=../../../github/scripts/lib/gh-repo.sh
source "$_ORCH_SHARED_GH_REPO"
unset _ORCH_GH_REPO_DIR _ORCH_SHARED_GH_REPO

# The resolver ci-wait, queue-wait, approval-wait, oversee-watch and
# open-terminal ask which repository they are acting on. GH_REPO first, then
# `gh repo view`, then the project root's origin remote; see the shared
# resolver for the exit codes.
orch_resolve_gh_repo() {
  kendex_github_resolve_gh_repo "$@"
}
