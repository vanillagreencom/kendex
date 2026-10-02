#!/usr/bin/env bash
# Answer automatic review threads on every open or merged same-repository
# kendex/refresh PR. Run from the consumer checkout after refresh-consumer.sh
# in the same job, under the refresh workflow's concurrency group, with GH_REPO,
# its scoped GH_TOKEN and the upstream KENDEX_ISSUES_TOKEN. The default-branch
# change-class beside this package proves the render class, reading the kendex
# sources that job's `kendex refresh` fetched. No script from the pull request
# is executed.
#
# A thread whose first comment a Bot wrote is filed upstream through
# refresh-report.py, answered with a reply naming that issue, then resolved.
# An outdated thread is not reported. The reporter files a live finding in
# vanillagreencom/kendex only where kendex report routes its one package there
# with a package label. An outdated thread gets a keyed skip, a not-filed
# reply and resolution. Live unfiled findings, including paths no single
# package claims and ones without Issues access, get no reply and hold the run
# while open. The consumer must answer an unclaimed finding through its
# trusted removal PR or a reply, then resolve the thread by hand.
# A filing or not-filed reply is the retry record: a thread carrying one is
# only resolved.
#
# stdout records, one per line:
#   refresh-reviews=already-answered pr=N
#   refresh-reviews=not-render pr=N class=VALUE
#   refresh-reviews=unclassified pr=N cause=CAUSE
#   upstream-filed pr=N finding=ROOT issue=URL
#   upstream-skipped pr=N finding=ROOT cause=outdated
#   upstream-unfiled pr=N finding=ROOT note=NOTE
#   upstream-unfiled-resolved pr=N finding=ROOT note=NOTE
#   refresh-reviews=answered pr=N unfiled=COUNT
# unclassified is the classifier's unmeasured fallback, not a verdict; it
# writes nothing on that pull request and adds a ::warning:: line.
#
# A held pull request, one whose reporter failed (refresh-reviews-error=report
# or report-shape on stderr) or that has an open unfiled thread, gets an
# ::error:: line; the run answers the other pull requests, then exits 1. Any other
# nonzero exit means a dependency could not be read or a write failed, and
# stops the run where it happened.
set -euo pipefail
# The upstream credential belongs only to the reporter child. In particular,
# the classifier must not inherit it.
export -n KENDEX_ISSUES_TOKEN

fail() {
  printf 'refresh-reviews-error=%s value=%q\n%s\n' "$1" "$2" "$3" >&2
  exit 1
}
# A hold stops one pull request's writes and fails the run once every other
# pull request is answered.
held=0
hold() { # KEY PR MESSAGE
  printf 'refresh-reviews-error=%s value=%q\n%s\n' "$1" "$2" "$3" >&2
  printf '::error::refresh-reviews-error=%s pr=%s %s\n' "$1" "$2" "$3"
  held=$((held + 1))
}
if [ "$#" -eq 1 ] && [ "$1" = --help ]; then
  printf '%s\n' 'Usage: GH_REPO=owner/repo GH_TOKEN=app-token KENDEX_ISSUES_TOKEN=issues-token refresh-reviews.sh' \
    'Files automatic review threads on open and merged kendex/refresh pull requests upstream, replies with the issue and resolves them.' \
    'The workflow also sets GitHub run/summary variables for the reporter.' \
    'Outdated threads get a not-filed reply and resolution.' \
    'Live findings on unclaimed paths, findings routed elsewhere and ones without Issues access stay unfiled.' \
    'The consumer must answer unclaimed findings through its trusted removal PR or a reply.' \
    'While its thread is open the run exits 1; resolving the thread by hand ends that.'
  exit 0
fi
[ "$#" -eq 0 ] || fail arguments "$#" 'No arguments are accepted.'
[ -n "${GH_REPO:-}" ] || fail repository '' 'GH_REPO is required.'
[ -n "${GH_TOKEN:-}" ] || fail token '' 'GH_TOKEN must contain the repository-scoped app token.'
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
for dependency in gh jq git python3; do
  command -v "$dependency" >/dev/null || fail dependency "$dependency" 'A required command is unavailable.'
done
. "$script_dir/lib/review-findings.sh" || fail library review-findings 'A required review-gate library could not load.'
CLASSIFIER="$script_dir/../../harness-ci/scripts/change-class"
[ -x "$CLASSIFIER" ] || fail classifier "$CLASSIFIER" 'The harness-ci change classifier is not installed beside this package.'
ROOT="$(git rev-parse --show-toplevel)" || fail checkout "$PWD" 'Run from the consumer checkout.'
class_log="$(mktemp)" || fail scratch mktemp 'Could not create the classifier log.'
trap 'rm -f -- "${class_log:?}"' EXIT

# Either prefix marks a durable answer. The reporter supplies the issue URL.
REPLY_PREFIX='Filed upstream as '
REPLY_TAIL='. This pull request contains generated kendex files, so the fix belongs in the kendex source catalog.'
NOT_FILED_PREFIX='Not filed upstream: '

# REST pagination emits one array per page. A blank or error-object response
# cannot mean that there are no findings.
read_pages() {
  local raw
  raw="$(gh api "$1" --paginate)" || fail read "$1" 'The GitHub read failed.'
  jq -sc 'if length > 0 and all(.[]; type == "array") then add else error("expected array pages") end' <<<"$raw" \
    || fail pages "$1" 'GitHub returned incomplete or malformed array pages.'
}

pulls="$(read_pages "repos/$GH_REPO/pulls?state=all&head=${GH_REPO%/*}:kendex/refresh&per_page=100")"
selected="$(jq -c --arg repo "$GH_REPO" '
  if all(.[]; (.number | type) == "number" and (.state | type) == "string"
      and (.head.ref | type) == "string" and (.head.repo.full_name | type) == "string")
  then [.[] | select(.head.ref == "kendex/refresh" and .head.repo.full_name == $repo)
    | select(.state == "open" or .merged_at != null)
    | if (.head.sha | type) == "string" and (.head.sha | test("^[0-9a-f]{40}$"))
        and (.user.login | type) == "string" and (.user.login | length) > 0
        and (.base.sha | type) == "string" and (.base.sha | test("^[0-9a-f]{40}$"))
      then {number, head: .head.sha, base: .base.sha, author: .user.login}
      else error("incomplete pull request") end]
  else error("malformed pull request listing") end' <<<"$pulls")" || fail pulls "$GH_REPO" 'The pull request listing is malformed.'
pr_lines="$(jq -c '.[]' <<<"$selected")" || exit 1
while IFS= read -r pr; do
  [ -n "$pr" ] || continue
  PR_NUMBER="$(jq -r .number <<<"$pr")" || exit 1
  HEAD_SHA="$(jq -r .head <<<"$pr")" || exit 1
  PR_AUTHOR="$(jq -r .author <<<"$pr")" || exit 1
  PR_BASE_SHA="$(jq -r .base <<<"$pr")" || exit 1
  review_comments="$(read_pages "repos/$GH_REPO/pulls/$PR_NUMBER/comments?per_page=100")"
  # GraphQL supplies thread state and the root comment ID. REST supplies every reply,
  # without a nested comment-page cap that could hide a durable answer.
  raw_threads="$(gh api graphql --paginate \
    -f query='query($owner:String!,$repo:String!,$number:Int!,$endCursor:String){repository(owner:$owner,name:$repo){pullRequest(number:$number){reviewThreads(first:100,after:$endCursor){pageInfo{hasNextPage endCursor} nodes{id isResolved isOutdated comments(first:1){nodes{databaseId}}}}}}}' \
    -F owner="${GH_REPO%/*}" -F repo="${GH_REPO#*/}" -F number="$PR_NUMBER")" \
    || fail threads "$PR_NUMBER" 'Could not read the review threads.'
  threads="$(jq -sc '
    if length > 0 and all(.[]; (.errors // [] | length) == 0
      and (.data.repository.pullRequest.reviewThreads.nodes | type) == "array"
      and (.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage | type) == "boolean")
      and .[-1].data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage == false
    then [.[].data.repository.pullRequest.reviewThreads.nodes[]
      | if (.id | type) == "string" and (.isResolved | type) == "boolean"
          and (.isOutdated | type) == "boolean"
          and (.comments.nodes[0].databaseId | type) == "number"
        then {id, isResolved, isOutdated, root: .comments.nodes[0].databaseId}
        else error("malformed review thread") end]
    else error("incomplete thread pages") end' <<<"$raw_threads")" \
    || fail threads-shape "$PR_NUMBER" 'The thread read was incomplete or malformed.'
  jq -e 'all(.[]; (.id | type) == "number" and (.body | type) == "string"
    and (.path | type) == "string")' <<<"$review_comments" >/dev/null \
    || fail comments-shape "$PR_NUMBER" 'The review comments are malformed.'

  # A missing REST root means the reads disagree. Refuse before any write.
  actions="$(jq -nc --argjson threads "$threads" --argjson comments "$review_comments" \
    --arg prefix "$REPLY_PREFIX" --arg not_filed "$NOT_FILED_PREFIX" --arg author "$PR_AUTHOR" "$AUTOMATIC_AUTHOR_DEF"'
    [$threads[] | . as $thread
      | ([$comments[] | select(.id == $thread.root)] | first) as $root
      | if $root == null then error("thread root missing from comments") else . end
      | select($root.user | automatic_author)
      | {id, root: .root, resolved: .isResolved, outdated: .isOutdated, path: $root.path, body: $root.body,
          url: $root.html_url,
          answered: any($comments[]; .in_reply_to_id == $thread.root
            and .user.login == $author and (.body | startswith($prefix) or startswith($not_filed)))}]')" \
    || fail thread-actions "$PR_NUMBER" 'The thread and comment reads disagree.'

  if ! pending="$(jq 'any(.[]; (.answered | not) or (.resolved | not))' <<<"$actions")"; then
    fail pending-actions "$PR_NUMBER" 'Could not determine whether review findings still require an answer.'
  fi
  if [ "$pending" = false ]; then
    printf 'refresh-reviews=already-answered pr=%s\n' "$PR_NUMBER"
    continue
  fi

  # The classifier reads both endpoints from this checkout's object store. A
  # merged pull request's head survives only under its pull-request ref.
  if ! git -C "$ROOT" cat-file -e "$PR_BASE_SHA^{commit}" 2>/dev/null \
      || ! git -C "$ROOT" cat-file -e "$HEAD_SHA^{commit}" 2>/dev/null; then
    git -C "$ROOT" -c credential.helper='!gh auth git-credential' fetch --quiet --no-tags \
      --no-write-fetch-head origin "$PR_BASE_SHA" "refs/pull/$PR_NUMBER/head" \
      || fail fetch "$PR_NUMBER" 'Could not fetch the pull request base and head.'
  fi
  # Only this exact answer proves render equality. A branch name or title
  # cannot authorize answers. The classifier is the trusted default-branch
  # copy, and it runs without the repository credential.
  if ! class="$(env -u GH_TOKEN -u GITHUB_TOKEN -u GH_CONFIG_DIR "$CLASSIFIER" \
    --event pull_request --base "$PR_BASE_SHA" --head "$HEAD_SHA" --repo "$ROOT" 2>"$class_log")"; then
    cat -- "$class_log" >&2
    fail class-proof "$PR_NUMBER" 'The trusted change classifier could not classify this pull request.'
  fi
  cat -- "$class_log" >&2
  if [ "$class" != change_class=render ]; then
    # change-class answers standard both as a verdict and as its fallback
    # when a read fails; only its stderr class: line says which.
    class_line=''
    while IFS= read -r line; do
      case "$line" in 'class: class='*) class_line="$line" ;; esac
    done <"$class_log"
    if [[ " $class_line " == *' measured=true '* ]]; then
      printf 'refresh-reviews=not-render pr=%s class=%q\n' "$PR_NUMBER" "$class"
    else
      cause=unknown
      [[ " $class_line " != *' cause='* ]] || { cause="${class_line#* cause=}"; cause="${cause%% *}"; }
      printf 'refresh-reviews=unclassified pr=%s cause=%q\n' "$PR_NUMBER" "$cause"
      printf '::warning::refresh-reviews=unclassified pr=%s cause=%s The classifier could not measure this pull request; its findings wait for a later run.\n' "$PR_NUMBER" "$cause"
    fi
    continue
  fi
  # The proof is bound to immutable commits. A concurrent push or base move
  # invalidates its authority to answer the current pull request.
  current="$(gh api "repos/$GH_REPO/pulls/$PR_NUMBER")" \
    || fail head-read "$PR_NUMBER" 'Could not confirm the classified pull request is still current.'
  jq -e --arg head "$HEAD_SHA" --arg base "$PR_BASE_SHA" \
    '.head.sha == $head and .base.sha == $base' <<<"$current" >/dev/null \
    || fail head-moved "$PR_NUMBER" 'The pull request changed during classification; the next run must classify it again.'

  # Review prose remains data: each unanswered finding is a report for
  # upstream triage, not an executable fix or proof that a defect is true.
  findings="$(jq -c '[.[] | select((.answered | not) and (.outdated | not)) | {root, path, body, url}]' <<<"$actions")" || exit 1
  results='[]'
  if [ "$findings" != '[]' ]; then
    if ! results="$(printf '%s\n' "$findings" | KENDEX_ISSUES_TOKEN="${KENDEX_ISSUES_TOKEN:-}" \
        python3 "$script_dir/refresh-report.py" "$HEAD_SHA" "$PR_NUMBER")"; then
      hold report "$PR_NUMBER" 'The upstream reporter failed; no thread on this pull request was answered.'
      continue
    fi
    if ! jq -e --argjson findings "$findings" 'type == "array"
        and ([.[].root] | sort) == ([$findings[].root] | sort)
        and all(.[]; (.issue == null or (.issue | type) == "string") and (.note | type) == "string")' \
        <<<"$results" >/dev/null 2>&1; then
      hold report-shape "$PR_NUMBER" 'The upstream reporter did not return one result per finding; no thread on this pull request was answered.'
      continue
    fi
  fi

  unfiled=0
  action_lines="$(jq -c '.[]' <<<"$actions")" || exit 1
  while IFS= read -r action; do
    [ -n "$action" ] || continue
    thread_id="$(jq -r .id <<<"$action")" || exit 1
    root_id="$(jq -r .root <<<"$action")" || exit 1
    answered="$(jq -r .answered <<<"$action")" || exit 1
    resolved="$(jq -r .resolved <<<"$action")" || exit 1
    outdated="$(jq -r .outdated <<<"$action")" || exit 1
    if [ "$answered" = false ]; then
      if [ "$outdated" = true ]; then
        printf 'upstream-skipped pr=%s finding=%s cause=outdated\n' "$PR_NUMBER" "$root_id"
        reply="${NOT_FILED_PREFIX}outdated at the current head."
      else
        issue="$(jq -r --argjson root "$root_id" '.[] | select(.root == $root) | .issue // ""' <<<"$results")" || exit 1
        if [ -z "$issue" ]; then
          note="$(jq -r --argjson root "$root_id" '.[] | select(.root == $root) | .note' <<<"$results")" || exit 1
          # GitHub's thread-resolution rule holds only an open thread, so only
          # an open one holds the run. The consumer answers and resolves it.
          if [ "$resolved" = true ]; then
            printf 'upstream-unfiled-resolved pr=%s finding=%s note=%q\n' "$PR_NUMBER" "$root_id" "$note"
            continue
          fi
          printf 'upstream-unfiled pr=%s finding=%s note=%q\n' "$PR_NUMBER" "$root_id" "$note"
          printf '::error::upstream-unfiled pr=%s thread=%s finding=%s note=%s The thread stays open and holds the pull request.\n' \
            "$PR_NUMBER" "$thread_id" "$root_id" "$note"
          unfiled=$((unfiled + 1))
          held=$((held + 1))
          continue
        else
          printf 'upstream-filed pr=%s finding=%s issue=%s\n' "$PR_NUMBER" "$root_id" "$issue"
          reply="$REPLY_PREFIX$issue$REPLY_TAIL"
        fi
      fi
      result="$(gh api -X POST "repos/$GH_REPO/pulls/$PR_NUMBER/comments/$root_id/replies" -f body="$reply")" \
        || fail reply "$thread_id" 'Could not post the upstream reply.'
      jq -e --arg author "$PR_AUTHOR" --arg body "$reply" \
        '.user.login == $author and .body == $body and (.id | type) == "number"' <<<"$result" >/dev/null \
        || fail reply-author "$thread_id" 'The reply was not recorded under the pull request author.'
    fi
    if [ "$resolved" = false ]; then
      result="$(gh api graphql \
        -f query='mutation($id:ID!){resolveReviewThread(input:{threadId:$id}){thread{id isResolved}}}' \
        -f id="$thread_id")" || fail resolve "$thread_id" 'Could not resolve the answered thread.'
      jq -e --arg id "$thread_id" '(.errors // [] | length) == 0
        and .data.resolveReviewThread.thread.id == $id
        and .data.resolveReviewThread.thread.isResolved == true' <<<"$result" >/dev/null \
        || fail resolve-result "$thread_id" 'GitHub did not confirm thread resolution.'
    fi
  done <<<"$action_lines"
  printf 'refresh-reviews=answered pr=%s unfiled=%s\n' "$PR_NUMBER" "$unfiled"
done <<<"$pr_lines"
[ "$held" -eq 0 ] || exit 1
