# shellcheck shell=bash
# The names the github package's scripts take from the project's settings
# files and its private env file: the settings keys they read and the
# credentials and repository names gh and git-https-auth read from the
# environment. Every github call of the shared loader passes this list, or
# the part of it the call reads; a name not here is never assigned from a
# project file.
# shellcheck disable=SC2034
github_settings_names=(
  GH_BOT_TOKEN
  GH_BOT_USERNAME
  GH_HOST
  GH_ISSUE_PATTERN
  GH_REPO
  GH_TOKEN
  GH_VERIFY_CMD
  GITHUB_TOKEN
  KENDEX_GITHUB_AUTH_TIMEOUT
  KENDEX_GITHUB_GIT_HTTPS_FALLBACK
  KENDEX_GITHUB_OP_TIMEOUT
  KENDEX_GITHUB_PR_VIEW_TIMEOUT
  ORCH_GH_PUSH_TOKEN_FILE
  ORCH_GH_READ_TOKEN_FILE
  PR_REVIEW_WAIT_SECS
  WORKTREE_DEFAULT_BRANCH
)
