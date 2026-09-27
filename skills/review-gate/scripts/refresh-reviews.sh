#!/usr/bin/env bash
# Answer automatic reviews on every open or merged same-repository
# kendex/refresh PR. Run from the trusted default-branch checkout, under the
# refresh workflow's concurrency group, with GH_REPO and its scoped GH_TOKEN.
# The trusted predicate owns classification and its private render checkout.
# No script from the pull request is executed.
# Durable author replies are the retry record. A nonzero exit means a dependency
# could not be read or a write failed. Upstream-action-needed records name
# findings that upstream triage assesses against kendex.
set -euo pipefail
# The upstream credential belongs only to the reporter child. In particular,
# predicate source preparation must not inherit it.
export -n KENDEX_ISSUES_TOKEN

fail() {
  printf 'refresh-reviews-error=%s value=%q\n%s\n' "$1" "$2" "$3" >&2
  exit 1
}
if [ "$#" -eq 1 ] && [ "$1" = --help ]; then
  printf '%s\n' 'Usage: GH_REPO=owner/repo GH_TOKEN=app-token refresh-reviews.sh [--report-only]' \
    'Answers automatic review threads and suppressed review-body findings on open and merged kendex/refresh pull requests.' \
    'The workflow uses --report-only with KENDEX_ISSUES_TOKEN and GitHub run/summary variables to file accepted rendered-file claims for upstream triage.'
  exit 0
fi
report_only=false
if [ "$#" -eq 1 ] && [ "$1" = --report-only ]; then report_only=true; shift; fi
[ "$#" -eq 0 ] || fail arguments "$#" 'No arguments are accepted.'
[ -n "${GH_REPO:-}" ] || fail repository '' 'GH_REPO is required.'
[ -n "${GH_TOKEN:-}" ] || fail token '' 'GH_TOKEN must contain the repository-scoped app token.'
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
for dependency in gh jq; do
  command -v "$dependency" >/dev/null || fail dependency "$dependency" 'A required command is unavailable.'
done
for library in diagnostics settings review-findings; do
  . "$script_dir/lib/$library.sh" || fail library "$library" 'A required review-gate library could not load.'
done

# This is the policy reply, not an assertion that an automatic finding is
# false. A consumer installation cannot repair the upstream source.
REPLY='Declined: render class is outside the review gate, including objections, under D003. This pull request contains generated kendex files. Report defects in these files upstream against kendex; fixes belong in the source catalog.'
ERROR_PATTERNS="$(rg_setting REVIEW_GATE_REVIEW_OBJECT_ERROR_PATTERNS 'encountered an error and was unable to review')" || exit 1
TRUSTED_LOGINS="$(rg_setting REVIEW_GATE_REVIEW_OBJECT_TRUSTED_LOGINS '')" || exit 1
TRUSTED_LOGINS_N="$(printf '%s' "$TRUSTED_LOGINS" | tr ';,' '\n')" || exit 1

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
  rg_load_reviews gh api
  review_comments="$(read_pages "repos/$GH_REPO/pulls/$PR_NUMBER/comments?per_page=100")"
  issue_comments="$(read_pages "repos/$GH_REPO/issues/$PR_NUMBER/comments?per_page=100")"
  # Only the root ID is needed from GraphQL. REST supplies every reply,
  # without a nested comment-page cap that could hide a durable answer.
  raw_threads="$(gh api graphql --paginate \
    -f query='query($owner:String!,$repo:String!,$number:Int!,$endCursor:String){repository(owner:$owner,name:$repo){pullRequest(number:$number){reviewThreads(first:100,after:$endCursor){pageInfo{hasNextPage endCursor} nodes{id isResolved comments(first:1){nodes{databaseId}}}}}}}' \
    -F owner="${GH_REPO%/*}" -F repo="${GH_REPO#*/}" -F number="$PR_NUMBER")" \
    || fail threads "$PR_NUMBER" 'Could not read the review threads.'
  threads="$(jq -sc '
    if length > 0 and all(.[]; (.errors // [] | length) == 0
      and (.data.repository.pullRequest.reviewThreads.nodes | type) == "array"
      and (.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage | type) == "boolean")
      and .[-1].data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage == false
    then [.[].data.repository.pullRequest.reviewThreads.nodes[]
      | if (.id | type) == "string" and (.isResolved | type) == "boolean"
          and (.comments.nodes[0].databaseId | type) == "number"
        then {id, isResolved, root: .comments.nodes[0].databaseId}
        else error("malformed review thread") end]
    else error("incomplete thread pages") end' <<<"$raw_threads")" \
    || fail threads-shape "$PR_NUMBER" 'The thread read was incomplete or malformed.'
  jq -e 'all(.[]; (.id | type) == "number" and (.body | type) == "string"
    and (.path | type) == "string")' <<<"$review_comments" >/dev/null \
    || fail comments-shape "$PR_NUMBER" 'The review comments are malformed.'
  jq -e 'all(.[]; (.body | type) == "string")' <<<"$issue_comments" >/dev/null \
    || fail dispositions-shape "$PR_NUMBER" 'The pull request comments are malformed.'

  # A missing REST root means the reads disagree. Refuse before any write.
  actions="$(jq -nc --argjson threads "$threads" --argjson comments "$review_comments" \
    --arg reply "$REPLY" --arg author "$PR_AUTHOR" "$AUTOMATIC_AUTHOR_DEF"'
    [$threads[] | . as $thread
      | ([$comments[] | select(.id == $thread.root)] | first) as $root
      | if $root == null then error("thread root missing from comments") else . end
      | select($root.user | automatic_author)
      | {id, root: .root, resolved: .isResolved, path: $root.path,
          answered: any($comments[]; (.id == $thread.root or .in_reply_to_id == $thread.root)
            and .user.login == $author and .body == $reply)}]')" \
    || fail thread-actions "$PR_NUMBER" 'The thread and comment reads disagree.'
  # The gate owns accepted rows and suppressed_scan. Its disposition marker
  # binds the current head even when a finding came from an older review.
  suppressed="$(jq -c --arg head "$HEAD_SHA" --arg author "$PR_AUTHOR" --arg trusted "$TRUSTED_LOGINS_N" \
    --arg errmarks "$ERROR_PATTERNS" \
    "$AUTOMATIC_AUTHOR_DEF$ACCEPTED_ROWS_DEF$SUPP_NORMALIZE_DEF$SUPP_ENTRY_DEF$SUPP_SCAN_DEF"'
    trust_list($trusted) as $t | error_marks($errmarks) as $mk
    | [accepted_rows($t; $mk; $author; [])[] | select(.user | automatic_author)
      | $head as $sha | (.body // "" | suppressed_scan) as $scan
      | if $scan.unparsed != 0 or $scan.declared != $scan.entries
        then error("unreadable suppressed block")
        elif $scan.entries == 0 then empty
        else {sha: $sha, entries: $scan.list} end]
    | group_by(.sha) | map({sha: .[0].sha, entries: ([.[].entries[]] | unique)})' <<<"$reviews")" \
    || fail suppressed "$PR_NUMBER" 'The automatic review-body findings could not be read.'
  # Exact lines are durable records from this writer. This is not a second
  # parser for arbitrary human dispositions; that grammar belongs to the gate.
  bodies="$(jq -nc --argjson groups "$suppressed" --argjson comments "$issue_comments" \
    --arg author "$PR_AUTHOR" --arg reply "$REPLY" '
    [$groups[] | . as $group | ("Dispositions at " + .sha) as $marker
      | [.entries[] | . as $entry | ($entry + " - " + $reply) as $line
          | select(any($comments[]; .user.login == $author
            and (.body | split("\n") | index($marker)) != null
            and (.body | split("\n") | index($line)) != null) | not)] as $missing
      | select($missing | length > 0)
      | {sha: .sha, entries: $missing,
          body: ($marker + "\n\n" + ([$missing[] | . + " - " + $reply] | join("\n")))}]')" \
    || fail disposition-actions "$PR_NUMBER" 'Could not determine unanswered review-body findings.'

  if ! pending="$(jq -n --argjson actions "$actions" --argjson bodies "$bodies" \
    'any($actions[]; (.answered | not) or (.resolved | not)) or ($bodies | length > 0)')"; then
    fail pending-actions "$PR_NUMBER" 'Could not determine whether review findings still require an answer.'
  fi
  if [ "$pending" = false ] && [ "$report_only" = false ]; then
    printf 'refresh-reviews=already-answered pr=%s\n' "$PR_NUMBER"
    continue
  fi

  # Only this exact predicate result proves both render equality and an
  # active none policy. A branch name or a generic approved verdict cannot
  # authorize dispositions. The sibling is from the trusted checkout.
  if ! proof="$(PR_NUMBER="$PR_NUMBER" HEAD_SHA="$HEAD_SHA" PR_AUTHOR="$PR_AUTHOR" \
    PR_BASE_SHA="$PR_BASE_SHA" bash "$script_dir/review-predicate.sh")"; then
    fail class-proof "$PR_NUMBER" 'The trusted review predicate could not classify this pull request.'
  fi
  [ -n "$proof" ] || fail class-proof "$PR_NUMBER" 'The trusted review predicate returned no result.'
  if [ "$proof" != 'verdict=approved detail=change class render requires no review evidence or thread wait' ]; then
    printf 'refresh-reviews=not-render pr=%s verdict=%q\n' "$PR_NUMBER" "$proof"
    continue
  fi
  # The proof is bound to immutable commits. A concurrent push or base move
  # invalidates its authority to answer the current pull request.
  current="$(gh api "repos/$GH_REPO/pulls/$PR_NUMBER")" \
    || fail head-read "$PR_NUMBER" 'Could not confirm the classified pull request is still current.'
  jq -e --arg head "$HEAD_SHA" --arg base "$PR_BASE_SHA" \
    '.head.sha == $head and .base.sha == $base' <<<"$current" >/dev/null \
    || fail head-moved "$PR_NUMBER" 'The pull request changed during classification; the next run must classify it again.'

  if [ "$report_only" = true ]; then
    # Review prose remains data. Accepted automatic findings are reports for
    # upstream triage, not executable fixes or proof that a defect is true.
    candidates="$(jq -nc --argjson actions "$actions" --argjson comments "$review_comments" \
      --argjson reviews "$reviews" --arg author "$PR_AUTHOR" --arg trusted "$TRUSTED_LOGINS_N" \
      --arg errmarks "$ERROR_PATTERNS" \
      "$AUTOMATIC_AUTHOR_DEF$ACCEPTED_ROWS_DEF$SUPP_NORMALIZE_DEF$SUPP_ENTRY_DEF$SUPP_SCAN_DEF"'
      ($comments | map(select(.in_reply_to_id == null) | .pull_request_review_id)) as $openers
      | ($reviews | trust_list($trusted) as $t | error_marks($errmarks) as $mk
        | accepted_rows($t; $mk; $author; $openers) | map(select(.user | automatic_author))) as $accepted
      | [ $actions[] as $a | $comments[]
          | select(.id == $a.root)
          | select(.pull_request_review_id as $id | any($accepted[]; .id == $id))
          | {path, body, claim: .body, url: .html_url} ]
        + [ $accepted[] | . as $review | (.body | suppressed_scan).list as $locations
          | ($review.body | split("\n") | map(
              . as $line | (display_strip | entry_token // "") as $token
              | if ($locations | index($token)) != null
                then $line | display_strip | split($token) | join($token | sub(":[0-9]+$"; ""))
                else $line end) | join("\n")) as $claim
          | $locations[]
          | {path: sub(":[0-9]+$"; ""), body: $review.body, claim: $claim, url: $review.html_url} ]')" \
      || fail report-candidates "$PR_NUMBER" 'Could not read accepted automatic findings.'
    printf '%s\n' "$candidates" | KENDEX_ISSUES_TOKEN="${KENDEX_ISSUES_TOKEN:-}" \
      python3 "$script_dir/refresh-report.py" "$HEAD_SHA" "$PR_NUMBER"
    continue
  fi

  action_lines="$(jq -c '.[]' <<<"$actions")" || exit 1
  while IFS= read -r action; do
    [ -n "$action" ] || continue
    thread_id="$(jq -r .id <<<"$action")" || exit 1
    root_id="$(jq -r .root <<<"$action")" || exit 1
    answered="$(jq -r .answered <<<"$action")" || exit 1
    resolved="$(jq -r .resolved <<<"$action")" || exit 1
    if [ "$answered" = false ]; then
      path="$(jq -r .path <<<"$action")" || exit 1
      printf 'upstream-action-needed pr=%s finding=%s path=%q\n' "$PR_NUMBER" "$root_id" "$path"
      result="$(gh api -X POST "repos/$GH_REPO/pulls/$PR_NUMBER/comments/$root_id/replies" -f body="$REPLY")" \
        || fail reply "$thread_id" 'Could not post the policy reply.'
      jq -e --arg author "$PR_AUTHOR" --arg body "$REPLY" \
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
  body_lines="$(jq -c '.[]' <<<"$bodies")" || exit 1
  while IFS= read -r disposition; do
    [ -n "$disposition" ] || continue
    body="$(jq -r .body <<<"$disposition")" || exit 1
    entries="$(jq -c .entries <<<"$disposition")" || exit 1
    printf 'upstream-action-needed pr=%s entries=%s\n' "$PR_NUMBER" "$entries"
    result="$(gh api -X POST "repos/$GH_REPO/issues/$PR_NUMBER/comments" -f body="$body")" \
      || fail disposition "$PR_NUMBER" 'Could not post the review-body dispositions.'
    jq -e --arg author "$PR_AUTHOR" --arg body "$body" \
      '.user.login == $author and .body == $body and (.id | type) == "number"' <<<"$result" >/dev/null \
      || fail disposition-author "$PR_NUMBER" 'The disposition was not recorded under the pull request author.'
  done <<<"$body_lines"
  printf 'refresh-reviews=answered pr=%s\n' "$PR_NUMBER"
done <<<"$pr_lines"
