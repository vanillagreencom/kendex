# shellcheck shell=bash
#
# The landing route's two answers from GitHub, read in one place for the two
# scripts that push a proved commit to a default branch with no pull
# request: refresh/refresh-consumer.sh, from the kendex release tree a
# consumer's run checked out, and tools/lock-record. Whether the branch's
# merge queue holds an entry decides whether the push is tried, since a push
# to a branch whose queue holds an entry makes GitHub rebuild every running
# group; what git reports for the push decides what the caller does next.
# The suite is refresh/tests/refresh-consumer.test.sh.
#
# Source this file; do not execute it directly.

# How many entries the merge queue of BRANCH in REPO, an owner/name slug,
# holds, printed as a whole number. GitHub answers a branch that has no
# merge queue with `"mergeQueue": null` (a recorded run against a
# repository with none), and that counts as 0: nothing waits there. A failed
# read, an answer carrying GraphQL errors, and any other shape print nothing
# and return 1, so the caller keeps the pull request route.
kendex_land_queue_entries() { # REPO BRANCH
  local answer
  answer="$(gh api graphql -f owner="${1%%/*}" -f repo="${1#*/}" -f branch="$2" \
    -f query='query($owner: String!, $repo: String!, $branch: String!) { repository(owner: $owner, name: $repo) { mergeQueue(branch: $branch) { entries { totalCount } } } }')" ||
    return 1
  jq -er 'if (.errors // [] | length) != 0 then error("GraphQL errors")
    else .data.repository.mergeQueue
      | if . == null then 0
        elif (.entries.totalCount | type == "number" and . >= 0 and floor == .) then .entries.totalCount
        else error("no entry count") end end' <<<"$answer" 2>/dev/null
}

# Push REVISION to the branch BASE on REMOTE from the checkout DIR, with
# TOKEN, the landing app's, as GH_TOKEN for this one command: the credential
# helper `gh auth setup-git` installed reads GH_TOKEN when git asks. Sets
# KENDEX_LAND_RESULT to landed, base-moved or refused, and KENDEX_LAND_STATUS
# to git's exit status. The result is read from git's porcelain record
# (git-push(1) OUTPUT): the ref line of a refused push carries the flag `!`,
# and its summary `[rejected]` where git itself refused it because BASE no
# longer holds REVISION's parent, the base having moved since the caller's
# fetch, or `[remote rejected]` where GitHub refused it, a ruleset among
# them. Every refusal other than git's `[rejected]` is refused. The record
# and what git prints go to stderr, so a caller's own records stay alone on
# stdout.
# shellcheck disable=SC2034  # the results are read by the scripts that source this.
kendex_land_push() { # DIR REMOTE REVISION BASE TOKEN
  local record flag ref summary
  KENDEX_LAND_STATUS=0
  record="$(GH_TOKEN="$5" git -C "$1" push --porcelain "$2" "$3:refs/heads/$4")" || KENDEX_LAND_STATUS=$?
  [ -z "$record" ] || printf '%s\n' "$record" >&2
  if [ "$KENDEX_LAND_STATUS" -eq 0 ]; then
    KENDEX_LAND_RESULT=landed
    return 0
  fi
  KENDEX_LAND_RESULT=refused
  while IFS=$'\t' read -r flag ref summary; do
    [ "$flag" = '!' ] || continue
    case "$ref:$summary" in
      *":refs/heads/$4:[rejected]"*) KENDEX_LAND_RESULT=base-moved ;;
    esac
  done <<<"$record"
}
