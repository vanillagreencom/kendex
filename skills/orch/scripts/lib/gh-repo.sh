# shellcheck shell=bash
#
# Orch entry point for the shared repository resolver, and the one reader of
# ORCH_CONNECTED_REPOS.
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

# Which repository an orch script acts on: GH_REPO first, then `gh repo
# view`, then the project root's origin remote; see the shared resolver for
# the exit codes.
orch_resolve_gh_repo() {
  kendex_github_resolve_gh_repo "$@"
}

# orch_connected_repos [REPO...] — prints, one per line and lowercased, each
# OWNER/REPO ORCH_CONNECTED_REPOS lists that no REPO names in any casing and no
# earlier entry repeats: the repositories a fleet works in beside its own,
# which its watch and its report read after their --repo values and its
# launches are admitted to. GitHub reads a repository path case-insensitively,
# so one lowercase spelling keeps each repository read once. Read through
# orch-env in the current directory, which honors the caller's own value and
# KENDEX_ENV_FILE. Returns 1, orch-env's own words on stderr, when the setting
# cannot be read.
orch_connected_repos() {
  local value entry seen list=()
  value="$("$SCRIPT_DIR/orch-env" ORCH_CONNECTED_REPOS "")" || return 1
  value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"
  seen="$(printf '%s\n' "$@" | tr '[:upper:]' '[:lower:]')"
  IFS=$' \t\n' read -ra list -d '' <<<"$value" || true
  for entry in ${list[@]+"${list[@]}"}; do
    if grep -qxF -- "$entry" <<<"$seen"; then continue; fi
    printf '%s\n' "$entry"
    seen+=$'\n'"$entry"
  done
}
