# shellcheck shell=bash
#
# The repository the orch waiters read, resolved in one place.
#
# Source this file; do not execute it directly.

# Resolve the owner/name slug every `gh --repo` argument and `repos/<slug>/`
# API path in a waiter carries, so one value decides which repository a
# verdict is about.
#
# GH_REPO wins. `gh repo view` resolves from the working directory and ignores
# GH_REPO (gh 2.100), unlike `gh pr view` and the rest, so a caller waiting on
# another repository's PR from this checkout would otherwise be handed this
# checkout's repository and a verdict about its same-numbered pull request.
# With GH_REPO unset, the working directory answers: `gh repo view` first, then
# the origin remote for a checkout gh cannot resolve.
#
# Arguments: the project root whose origin remote the fallback reads.
# Stdout: the resolved slug, or the rejected candidate on exit 2.
# Exit: 0 resolved, 1 nothing resolved, 2 resolved to something that is not
# owner/name — two non-empty segments around a single slash, which is what an
# API path and a `--repo` argument accept.
orch_resolve_gh_repo() {
  local project_root="${1:?orch_resolve_gh_repo: project_root required}"
  local repo origin_url origin_status

  if [ -n "${GH_REPO:-}" ]; then
    repo="$GH_REPO"
  else
    repo=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)
    if [ -z "$repo" ]; then
      origin_status=0
      origin_url=$(git -C "$project_root" remote get-url origin 2>/dev/null) || origin_status=$?
      # git answers 2 for "no such remote" — a checkout with no origin. Any
      # other status means git could not answer at all, most often because the
      # project root is no repository. Neither resolves anything, and the
      # caller refuses on that rather than falling back to a repository
      # nobody named.
      [ "$origin_status" -eq 0 ] || return 1
      # Capture owner/repo greedily, then strip a trailing ".git" explicitly.
      # GNU sed / POSIX ERE has no non-greedy quantifier, so a
      # `[^/]+?(\.git)?$` pattern would greedily swallow ".git" into the slug.
      # Do the suffix strip with bash parameter expansion instead — portable
      # for both SSH (git@github.com:owner/repo.git) and HTTPS origins, with
      # or without ".git", and safe for repo names that merely contain the
      # substring "git".
      repo=$(printf '%s' "$origin_url" | sed -nE 's#^.*github\.com[:/]+([^/]+/[^/]+)$#\1#p')
      repo="${repo%.git}"
    fi
  fi

  [ -n "$repo" ] || return 1
  printf '%s\n' "$repo"
  [[ "$repo" =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]] || return 2
  return 0
}
