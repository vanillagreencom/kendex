# shellcheck shell=bash
#
# What a repository's GitHub settings say about where its pull requests go
# and how they merge: the default branch, the merge method a base branch
# allows, and whether GitHub deletes a merged head branch itself. pr-create,
# pr-merge, the worktree skill and kendex's tools/lock-record read them here,
# so no caller assumes main, squash or a branch deletion.
#
# Source this file after gh-repo.sh; do not execute it directly.

# The branch a new pull request targets and a new worktree starts from.
# WORKTREE_DEFAULT_BRANCH, when set, is the answer and nothing is read: an
# explicit override. Otherwise it is GitHub's default_branch for the
# repository PROJECT_ROOT resolves to through kendex_github_resolve_gh_repo.
#
# Arguments: the project root.
# Stdout: the branch.
# Exit: 0 answered; 1 not answered, with a first line on stderr of
# `default-branch: repo-invalid value=<slug>` or
# `default-branch: unreadable repo=<slug>` and gh's words after it; 3 the
# project root names no GitHub repository, with nothing printed, so a caller
# holding a forge-neutral answer can use it.
kendex_github_default_branch() {
  local root="${1:?kendex_github_default_branch: project root required}" slug="" out="" rc=0

  if [ -n "${WORKTREE_DEFAULT_BRANCH:-}" ]; then
    printf '%s\n' "$WORKTREE_DEFAULT_BRANCH"
    return 0
  fi
  slug=$(kendex_github_resolve_gh_repo "$root") || rc=$?
  case "$rc" in
    0) ;;
    1) return 3 ;;
    *)
      printf 'default-branch: repo-invalid value=%s\n' "$slug" >&2
      return 1
      ;;
  esac
  # A branch name holds no whitespace, so an answer that does is gh's words,
  # not a branch: stderr is captured beside stdout to name the cause.
  if ! out=$(gh api "repos/$slug" --jq '.default_branch // ""' 2>&1) \
    || ! [[ "$out" =~ ^[^[:space:]]+$ ]]; then
    printf 'default-branch: unreadable repo=%s\n' "$slug" >&2
    [ -z "$out" ] || printf '%s\n' "$out" | sed 's/^/  /' >&2
    return 1
  fi
  printf '%s\n' "$out"
}

# The merge method a pull request into BASE takes, chosen from the methods
# the caller accepts. A merge_queue rule on BASE fixes the method to the
# queue's merge_method. Otherwise the allowed set is the repository's
# allow_squash_merge, allow_merge_commit and allow_rebase_merge, narrowed by
# the allowed_merge_methods of every pull_request rule on BASE. The first
# accepted method the set allows is the answer. --direct asks for a merge
# made past the queue, which GitHub holds to the repository's methods and the
# pull_request rules, never to the queue's method: the merge_queue rule is
# not read.
#
# Arguments: an optional --direct; REPO, an owner/name slug or gh's
# {owner}/{repo} placeholder; BASE; then the accepted methods, most preferred
# first, each squash, merge or rebase.
# Stdout and exit: 0 the method; 2 the allowed set comma-joined, `none` when
# empty; 1 what could not be read, one of `accepted` (no method, or a word
# outside the three), `rules` (the base branch's rules), `settings` (the
# repository's allow_* flags, which GitHub omits for a token without push
# access) or `queue` (a queue method outside the three).
kendex_github_merge_method() {
  local repo base encoded="" lines="" rules="" settings=null allowed="" accepted="" method="" kinds='"merge_queue", "pull_request"'
  if [ "${1:-}" = --direct ]; then
    kinds='"pull_request"'
    shift
  fi
  repo="$1" base="$2"
  shift 2
  [ "$#" -gt 0 ] || { echo accepted; return 1; }
  for accepted in "$@"; do
    case "$accepted" in
      squash | merge | rebase) ;;
      *) echo accepted; return 1 ;;
    esac
  done
  if ! encoded=$(jq -nr --arg v "$base" '$v | @uri') \
    || ! lines=$(gh api "repos/$repo/rules/branches/$encoded" --paginate \
      --jq ".[] | select(.type | IN($kinds)) | tojson" 2>/dev/null) \
    || ! rules=$(jq -cs . <<<"$lines" 2>/dev/null); then
    echo rules
    return 1
  fi
  if ! jq -e 'any(.[]; .type == "merge_queue")' >/dev/null <<<"$rules"; then
    settings=$(gh api "repos/$repo" --jq '[.allow_squash_merge, .allow_merge_commit, .allow_rebase_merge] | tojson' 2>/dev/null) \
      || { echo settings; return 1; }
  fi
  if ! allowed=$(jq -r --argjson s "$settings" '
      ["squash", "merge", "rebase"] as $methods
      | . as $rules
      | ([$rules[] | select(.type == "merge_queue") | (.parameters.merge_method // "" | ascii_downcase)] | unique) as $queue
      | if ($queue | length) > 0 then
          if ($queue | length) == 1 and ($methods | index($queue[0])) != null then $queue[0] else "!queue" end
        elif ($s | type) != "array" or ($s | length) != 3 or any($s[]; type != "boolean") then "!settings"
        else
          [$rules[] | select(.type == "pull_request") | (.parameters.allowed_merge_methods // $methods)] as $narrow
          | [range(0; 3) | select($s[.]) | $methods[.] | select(. as $m | all($narrow[]; index($m) != null))]
          | join(" ")
        end' <<<"$rules" 2>/dev/null); then
    echo rules
    return 1
  fi
  case "$allowed" in
    '!queue') echo queue; return 1 ;;
    '!settings') echo settings; return 1 ;;
  esac
  for accepted in "$@"; do
    for method in $allowed; do
      if [ "$accepted" = "$method" ]; then
        printf '%s\n' "$method"
        return 0
      fi
    done
  done
  allowed="${allowed// /,}"
  printf '%s\n' "${allowed:-none}"
  return 2
}

# Whether GitHub deletes a merged pull request's head branch itself: the
# repository's delete_branch_on_merge.
#
# Arguments: REPO, an owner/name slug or gh's {owner}/{repo} placeholder.
# Stdout: true or false. Exit 1 when GitHub answered no boolean, which it
# omits for a token without push access.
kendex_github_deletes_merged_branch() {
  local answer=""
  answer=$(gh api "repos/$1" --jq '.delete_branch_on_merge' 2>/dev/null) || return 1
  case "$answer" in
    true | false) printf '%s\n' "$answer" ;;
    *) return 1 ;;
  esac
}
