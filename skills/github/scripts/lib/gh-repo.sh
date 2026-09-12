# shellcheck shell=bash
#
# The repository a kendex script reads and writes, resolved in one place.
#
# Source this file; do not execute it directly.

# Resolve the owner/name slug every `gh --repo` argument and `repos/<slug>/`
# API path carries, so one value decides which repository a command reads and
# which one it mutates.
#
# GH_REPO wins. `gh repo view` resolves from the working directory and ignores
# GH_REPO (gh 2.100), unlike `gh pr view` and the rest, so a caller acting on
# another repository's PR from this checkout would otherwise be handed this
# checkout's repository — and one command would split its read and its write
# across two repositories.
# With GH_REPO unset, the working directory answers: `gh repo view` first, then
# the origin remote for a checkout gh cannot resolve.
#
# Arguments: the project root whose origin remote the fallback reads.
# Stdout: the resolved slug, or the rejected candidate on exit 2.
# Exit: 0 resolved, 1 nothing resolved, 2 resolved to something that is not
# owner/name — two segments of the characters GitHub issues for an owner and a
# repository name, around a single slash.
kendex_github_resolve_gh_repo() {
  local project_root="${1:?kendex_github_resolve_gh_repo: project_root required}"
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
      # github.com must sit where a hostname sits: at the start of the URL,
      # right after the scheme, or right after userinfo that carries no "/".
      # A leading `.*` would accept the string anywhere, so an origin such as
      # https://gitlab.example/group/github.com/owner/repo resolves to
      # owner/repo and kendex reads and writes GitHub with the operator's
      # token for a checkout that is not on GitHub at all.
      #
      # Capture owner/repo greedily, then strip a trailing ".git" explicitly.
      # GNU sed / POSIX ERE has no non-greedy quantifier, so a
      # `[^/]+?(\.git)?$` pattern would greedily swallow ".git" into the slug.
      # Do the suffix strip with bash parameter expansion instead — portable
      # for both SSH (git@github.com:owner/repo.git) and HTTPS origins, with
      # or without ".git", and safe for repo names that merely contain the
      # substring "git".
      repo=$(printf '%s' "$origin_url" \
        | sed -nE 's#^([A-Za-z][A-Za-z0-9+.-]*://)?([^/@]*@)?github\.com[:/]+([^/]+/[^/]+)$#\3#p')
      repo="${repo%.git}"
    fi
  fi

  [ -n "$repo" ] || return 1
  printf '%s\n' "$repo"
  # The characters GitHub issues for an owner and a repository name. A class
  # that only barred whitespace and a second slash admitted the quote,
  # semicolon, dollar, backtick, ampersand, pipe and parenthesis, and
  # open-terminal renders this value into a launch line its caller's shell
  # runs, so a GH_REPO exported by a checkout's tracked settings file became
  # command text in the operator's terminal.
  [[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || return 2
  return 0
}
