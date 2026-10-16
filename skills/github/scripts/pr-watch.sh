#!/usr/bin/env bash
# pr-watch — reduce every open PR to normalized needs-attention lines, each
# read from GitHub's own review state: unresolved review threads, the pull
# request's reviewDecision, its auto-merge arm, its merge-queue entry and a
# lanes-app refresh head's CI aggregate. A PR
# sitting steadily over an open thread TRANSITIONS NOTHING, so a watcher keyed
# on state transitions idles for hours over a thread posted minutes after its
# last pass; this reducer reports the standing state on every call.
# A pass batches the initial read into one gh process and one jq reduction.
# Listing pages stay in that gh process. Further thread-page depths each
# take one shared gh call and jq reduction, independent of the PR count.
# The authoritative contract — attention kinds, output format, exit
# codes, env — is print_usage below: run with --help.
# Stdout is the whole-text attention protocol consumed by orch oversee-watch
# and lane-close: PR number, head prefix, kind, and detail separated by
# literal tabs. The detail includes the queue annotation.
# Preserve these payloads.
# Global refusals use diagnostic records on stderr, followed by explanation.
set -euo pipefail

# The diagnostic record: `pr-watch: CODE value=VALUE`, the value escaped
# with Bash printf %q, then the explanation.
watch_message() { # CODE VALUE MESSAGE
  printf 'pr-watch: %s value=%q\n%s\n' "$1" "$2" "$3"
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for lib in refresh-identity kendex-env; do
  # shellcheck source=/dev/null
  if [ ! -r "$script_dir/lib/$lib.sh" ] || ! . "$script_dir/lib/$lib.sh"; then
    watch_message "$lib-load" "$script_dir/lib/$lib.sh" "Could not load lib/$lib.sh." >&2
    exit 2
  fi
done

print_usage() {
  cat <<'USAGE'
Usage: pr-watch.sh [PR# ...] [--awaiting-after SECS]

Reduce every open PR to normalized needs-attention lines, read from GitHub's
review state: unresolved review threads, the PR's reviewDecision, its
auto-merge arm, its merge-queue entry and a lanes-app refresh head's CI
aggregate. One invocation answers: does any
open PR need attention RIGHT NOW?

  PR# ...            watch only these PRs (default: every open PR)
  --awaiting-after S override the awaiting-stale threshold (default: the
                     PR_REVIEW_WAIT_SECS setting, else 900)

Attention kinds:
  threads-open       unresolved review threads, which the base branch's
                     thread rule holds the merge on. Counted across pages
                     (bound: 20 pages / 2000 threads); past the bound, or on
                     pagination metadata that cannot advance, the count
                     fails CLOSED as attention. QUEUED PRs are annotated — a
                     queued PR needs a DEQUEUE before any fix push; GitHub
                     rejects pushes to queued branches. While a thread
                     stands, the PR reports neither disarmed nor
                     awaiting-stale: answering the thread comes first
  changes-requested  reviewDecision CHANGES_REQUESTED: a standing objection
                     holds the merge. Reported beside threads-open
  disarmed           reviewDecision APPROVED on an open, un-queued,
                     non-draft PR with auto-merge NOT armed — nothing will
                     merge it (the known eviction-disarm failure mode). A
                     PR orch's merge route takes past the queue with
                     --admin is unarmed by design until its lane's direct
                     merge attempt, so for such a PR the line reports that
                     wait, not an eviction.
  awaiting-stale     reviewDecision REVIEW_REQUIRED and the head has sat
                     unapproved longer than the quiet period
                     (PR_REVIEW_WAIT_SECS, default 900), counted from the
                     newest of the head commit, the PR's creation, and a
                     ready-for-review, reopen or re-review-request event.
                     Drafts are never reported. Time for a re-review trigger
                     or the fallback approval
  refresh-ready      reviewDecision REVIEW_REQUIRED on a non-draft head
                     whose exact branch is kendex/refresh and whose author
                     is vanillagreen-fleet-lanes[bot] with type Bot. Its
                     current-head CI aggregate completed successfully.
                     Reported immediately, without a quiet period or lane.
                     The overseer still proves the render before approval
  head-moved         the head changed between shared reads, or the head
                     commit read beside the PR is not its head. A push
                     landed during the read, so the findings
                     (or the silence) describe the OLD head; re-run.
                     Attention, not an error: the race is ordinary, the
                     response is one more poll
  error              this PR could not be reduced (a read failed or
                     answered malformed data) — fail LOUD, never silently
                     skipped

Ordinary REVIEW_REQUIRED inside the quiet period, and an approved PR with auto-merge
armed or queued, are healthy states and emit NOTHING — silence on stdout
means "nothing needs you", which is what makes the exit code a cheap
loop/cron predicate.

A null reviewDecision, which GitHub answers on a base no approval rule
targets (a stacked PR's base among them), is not an approval: that PR gets
neither a disarmed nor an awaiting-stale line.

One pass reads every PR in one gh call per repository. The open-PR listing
may send several GraphQL requests inside that call. Each further thread-page
depth takes one extra gh call and jq reduction shared by every PR that needs
it. No subprocess starts per PR or per attention line.

Output: one tab-separated line per finding on stdout:
  <pr-number> <TAB> <head-sha-8> <TAB> <kind> <TAB> <detail>

Exit codes:
  0  nothing needs attention
  1  at least one attention line
  2  read failure, in two shapes: per-PR failures carry `error` lines on
     stdout (attention lines may also be present), while GLOBAL failures
     (missing GH_REPO, a broken open-PR listing, which a GraphQL error
     anywhere in it is) report on stderr only
     with no per-PR lines — surface stderr, not just stdout

Env (required): GH_TOKEN (or ambient gh auth), GH_REPO

Settings: PR_REVIEW_WAIT_SECS from the environment, else the project
settings at the git root of the working directory, read as the github.sh
router reads them. Unreadable project settings are a global failure.

Consumers: orch's workflows treat this as the single state reducer for
multi-PR watching (orch's approval-wait remains the single-PR foreground
wait with on-timeout policy; orch's oversee consumes it through
oversee-watch, and lane-close reads its silence before a park); harness
wake-up mechanisms (a monitor loop, cron, a scheduler) call it rather than
re-deriving state keys per session.
USAGE
}

for arg in "$@"; do
  case "$arg" in
    -h|--help) print_usage; exit 0 ;;
  esac
done

if [ -z "${GH_REPO:-}" ]; then
  watch_message watch-repo-missing "${GH_REPO:-}" "::error::pr-watch: GH_REPO is required" >&2
  exit 2
fi

AWAITING_AFTER=""
PR_ARGS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --awaiting-after)
      shift
      AWAITING_AFTER="${1:-}"
      case "$AWAITING_AFTER" in
        ''|*[!0-9]*) watch_message watch-wait-invalid "$AWAITING_AFTER" "::error::pr-watch: --awaiting-after needs a positive integer" >&2; exit 2 ;;
      esac
      # Same bound as the settings path: past Bash's integer range the later
      # [ -gt ] comparisons fail silently inside their ifs. Leading zeros
      # are stripped first so a zero-padded fixed-width value is judged by
      # its numeric magnitude, not its character count.
      AWAITING_AFTER="${AWAITING_AFTER#"${AWAITING_AFTER%%[!0]*}"}"
      [ -z "$AWAITING_AFTER" ] && AWAITING_AFTER=0
      if [ "${#AWAITING_AFTER}" -gt 9 ]; then
        watch_message watch-wait-range "$AWAITING_AFTER" "::error::pr-watch: --awaiting-after is out of range (max 9 digits)" >&2
        exit 2
      fi
      ;;
    -*) watch_message watch-flag-unknown "$1" "::error::pr-watch: unknown flag $1" >&2; exit 2 ;;
    *)
      case "$1" in
        ''|*[!0-9]*) watch_message watch-pr-invalid "$1" "::error::pr-watch: PR arguments must be numbers (got '$1')" >&2; exit 2 ;;
      esac
      # Base-10 normalization: a zero-padded "09" is not valid JSON for the
      # --argjson binding check downstream.
      PR_ARGS="$PR_ARGS $((10#$1))"
      ;;
  esac
  shift
done

if [ -z "$AWAITING_AFTER" ]; then
  # The project's settings load in a subshell, as the github.sh router finds
  # them, so the project files set nothing else in this process.
  project_root="$(git rev-parse --show-toplevel 2>/dev/null)" || project_root=""
  AWAITING_AFTER="$(kendex_load_project_env "$project_root" && printf '%s' "${PR_REVIEW_WAIT_SECS-900}")" || {
    watch_message watch-settings-unreadable "$project_root" "::error::pr-watch: the project settings could not be read for PR_REVIEW_WAIT_SECS" >&2
    exit 2
  }
  # Fail-loud, same as --awaiting-after: a typo ("90s") must never silently
  # become the 900 default — a silent fallback CHANGES the review-silence
  # policy the operator thinks they set. Digit-only AND bounded: a digit
  # string beyond Bash's integer range (e.g. 20 digits) passes a pure [!0-9]
  # check but then errors inside the later [ -gt ] comparisons — swallowed by
  # the if, silently disabling the awaiting-stale alert. 9 digits (~31 years)
  # is bound enough.
  case "$AWAITING_AFTER" in
    ''|*[!0-9]*)
      watch_message watch-wait-setting-invalid "$AWAITING_AFTER" "::error::pr-watch: PR_REVIEW_WAIT_SECS must be a non-negative integer, got '$AWAITING_AFTER'" >&2
      exit 2
      ;;
  esac
  AWAITING_AFTER="${AWAITING_AFTER#"${AWAITING_AFTER%%[!0]*}"}"
  [ -z "$AWAITING_AFTER" ] && AWAITING_AFTER=0
  if [ "${#AWAITING_AFTER}" -gt 9 ]; then
    watch_message watch-wait-setting-range "$AWAITING_AFTER" "::error::pr-watch: PR_REVIEW_WAIT_SECS is out of range (max 9 digits), got '$AWAITING_AFTER'" >&2
    exit 2
  fi
fi

# --- one read ------------------------------------------------------------
# Every pull request comes from a batched GraphQL read per repository, so its
# head, review state, threads, head commit, CI aggregate and timeline describe
# one moment rather than the seconds a per-PR walk of REST reads spans. A push
# that lands during the request shows as a head commit that is not the PR's
# head, which reads as head-moved. The reduction is one jq program; nothing
# here starts a process per pull request or per output line.
# CheckSuiteFilter names suites, not their check runs. Select CI inside each
# suite so a GitHub Actions aggregate remains visible.
PR_STATE_FIELDS='number state isDraft headRefOid headRefName createdAt author{login __typename}
  autoMergeRequest{mergeMethod} isInMergeQueue mergeQueueEntry{position} reviewDecision
  commits(last:1){totalCount nodes{commit{oid committedDate
    checkSuites(first:10){pageInfo{hasNextPage}
      nodes{checkRuns(first:20,filterBy:{checkName:"CI",checkType:LATEST}){pageInfo{hasNextPage} nodes{name status conclusion}}}}}}}
  timelineItems(last:10,itemTypes:[READY_FOR_REVIEW_EVENT,REOPENED_EVENT,REVIEW_REQUESTED_EVENT]){nodes{
    ... on ReadyForReviewEvent{createdAt} ... on ReopenedEvent{createdAt} ... on ReviewRequestedEvent{createdAt}}}'
PR_FIELDS="$PR_STATE_FIELDS reviewThreads(first:100){pageInfo{hasNextPage endCursor} nodes{isResolved}}"
owner="${GH_REPO%%/*}"
name="${GH_REPO#*/}"
now="$(date +%s)" || {
  watch_message watch-clock-failed "" "::error::pr-watch: could not read the clock" >&2
  exit 2
}

# Named PRs are aliased into one request. A failed or empty answer is every
# named PR's error line, never a global refusal: the caller asked about those
# PRs. The open-PR listing pages inside the same gh process; gh follows the
# first pageInfo in the answer, which is the listing's, so it comes before
# the PR fields.
main_read=ok
if [ -n "$PR_ARGS" ]; then
  mode=named
  selection=""
  for number in $PR_ARGS; do
    selection="$selection p$number:pullRequest(number:$number){...PR}"
  done
  main="$(gh api graphql -f owner="$owner" -f name="$name" \
      -f query="query(\$owner:String!,\$name:String!){repository(owner:\$owner,name:\$name){$selection}} fragment PR on PullRequest{$PR_FIELDS}" \
      2>/dev/null)" || main_read=failed
  [ "$main_read" = failed ] || [ -n "$main" ] || main_read=empty
else
  mode=list
  main="$(gh api graphql --paginate -f owner="$owner" -f name="$name" \
      -f query="query(\$owner:String!,\$name:String!,\$endCursor:String){repository(owner:\$owner,name:\$name){pullRequests(states:OPEN,first:50,after:\$endCursor,orderBy:{field:CREATED_AT,direction:DESC}){pageInfo{hasNextPage endCursor} nodes{...PR}}}} fragment PR on PullRequest{$PR_FIELDS}")" || {
    watch_message watch-list-failed "$GH_REPO" "::error::pr-watch: could not list open PRs" >&2
    exit 2
  }
  if [ -z "$main" ]; then
    watch_message watch-list-empty "$GH_REPO" "::error::pr-watch: open-PR listing produced zero bytes (broken read)" >&2
    exit 2
  fi
fi

# The reduction. Input: the main read's pages on stdin; $read, the named
# read's status; a marker and response per thread-page round on stdin after
# the main pages. Output: a control line, then the attention protocol.
# The control line is `exit<TAB>code`, `global<TAB>key` for a listing that
# cannot be trusted, or `walk<TAB>request`, the GraphQL request body for the
# next thread page of every PR whose count needs one. A malformed answer is that
# PR's error line, never health: a node read as unqueued, unreviewed or
# threadless would print a false disarmed line or drop a dequeue note.
REDUCE_JQ='
def sha: type == "string" and test("^[0-9a-fA-F]{40}$");
# Epoch seconds of an ISO-8601 time in UTC or with an offset (a commit time
# keeps its author offset); null when it does not parse.
def epoch:
  if type != "string" then null
  else ([capture("^(?<t>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(?<z>Z|(?<s>[+-])(?<h>[0-9]{2}):(?<m>[0-9]{2}))$")] | first) as $c
  | if $c == null then null
    else (try (($c.t + "Z") | fromdateiso8601) catch null) as $base
    | if $base == null or $c.z == "Z" then $base
      else $base - (if $c.s == "-" then -1 else 1 end) * (($c.h | tonumber) * 3600 + ($c.m | tonumber) * 60)
      end
    end
  end;
def finding($n; $head; $kind; $detail): {n: $n, head: $head[0:8], kind: $kind, detail: $detail};

# The unresolved count across pages. Past 20 pages, or at a truthy
# hasNextPage whose cursor cannot advance, the count fails closed as
# overflow: long-lived PRs keep hundreds of resolved threads, so a bound at
# the first page would make attention permanent.
def thread_page_ok:
  type == "object" and (.nodes | type) == "array"
  and all(.nodes[]; type == "object" and (.isResolved | type) == "boolean");
def threads($first; $later):
  def step($page; $rest; $count; $used; $pages):
    if ($page | thread_page_ok | not) then {error: "thread response malformed (non-boolean isResolved) or unparsable"}
    elif ($page.pageInfo.hasNextPage | type) != "boolean" then {error: "thread pagination metadata malformed (non-boolean hasNextPage)"}
    else ($count + ([$page.nodes[] | select(.isResolved == false)] | length)) as $total
    | if ($page.pageInfo.hasNextPage | not) then {unresolved: $total}
      else ($page.pageInfo.endCursor // "") as $next
      | if ($next | type) != "string" or $next == "" or $next == $used or $pages >= 20 then {overflow: true}
        elif ($rest | length) == 0 then {walk: $next}
        elif $rest[0].status == "failed" then {error: "thread read failed"}
        elif $rest[0].status == "empty" then {error: "thread read produced zero bytes (broken read)"}
        else step($rest[0].page; $rest[1:]; $total; $next; $pages + 1)
        end
      end
    end;
  step($first; $later; 0; ""; 1);

# The refresh aggregate: every check named CI on the head commit completed
# successfully. Pending or unsuccessful CI never starts a review wait.
def refresh_ci($commit; $n; $head; $queued):
  $commit.checkSuites as $s
  | if ($s | type) != "object" or ($s.nodes | type) != "array" or ($s.pageInfo.hasNextPage | type) != "boolean"
       or any($s.nodes[]; type != "object" or (.checkRuns | type) != "object"
         or (.checkRuns.nodes | type) != "array" or (.checkRuns.pageInfo.hasNextPage | type) != "boolean")
    then [finding($n; $head; "error"; "refresh CI response malformed")]
    elif $s.pageInfo.hasNextPage or any($s.nodes[]; .checkRuns.pageInfo.hasNextPage)
    then [finding($n; $head; "error"; "refresh CI read is past one page (fail loud, never a refresh line)")]
    else [$s.nodes[].checkRuns.nodes[]] as $runs
    | if any($runs[]; type != "object" or (.name | type) != "string"
          or (.status | type) != "string" or (has("conclusion") | not)
          or ((.conclusion | type) != "null" and (.conclusion | type) != "string"))
      then [finding($n; $head; "error"; "refresh CI response malformed")]
      else [$runs[] | select(.name == "CI")] as $ci
      | if ($ci | length) > 0 and all($ci[]; .status == "COMPLETED" and .conclusion == "SUCCESS")
        then [finding($n; $head; "refresh-ready"; "current-head CI passed; prove the render and approve as the overseer app\($queued)")]
        else [] end
      end
    end;

# Reviewer silence counts from when this head became the head. GitHub exposes
# no head-transition time, so the clock starts at the newer of the head
# commit time and the PR creation, which covers an old commit opened in a
# fresh PR. A ready-for-review, reopen or re-review request restarts it. The
# commit time is author-controlled: beyond a small skew a future time is an
# error, never silence. A push of an old commit onto an old PR still reads
# stale early, which errs toward a nudge, never toward a stall.
def stale($p; $commit; $n; $head; $queued):
  $commit.committedDate as $at
  | if $at == null or $at == "" then [finding($n; $head; "error"; "head commit has no usable committer date (broken read)")]
    elif ($at | epoch) == null then [finding($n; $head; "error"; "head committer date unparsable (broken read) — the silence clock never substitutes the creation time for broken head metadata")]
    elif ($p.createdAt | epoch) == null then [finding($n; $head; "error"; "PR creation timestamp unparsable (broken read) — the silence floor cannot be computed")]
    else ([($at | epoch), ($p.createdAt | epoch)] | max) as $from
    | ($now - $from) as $age
    | if $age < -300 then [finding($n; $head; "error"; "silence clock is in the future by \(-$age)s (author-controlled committer timestamp) — silence age unprovable")]
      elif $age <= $wait then []
      elif ($p.timelineItems | type) != "object" or ($p.timelineItems.nodes | type) != "array"
        or any($p.timelineItems.nodes[]; type != "object" or (.createdAt | type) != "string")
      then [finding($n; $head; "error"; "timeline pages malformed while confirming staleness (fail loud, not a stale alert)")]
      else ([$p.timelineItems.nodes[].createdAt] | sort | last) as $ready
      | (if $ready == null then {age: $age}
         elif ($ready | epoch) == null then {error: "readiness/reopen timestamp unparsable while confirming staleness (fail loud, not a stale alert)"}
         elif ($ready | epoch) > $from then ($now - ($ready | epoch)) as $since
           | if $since < -300 then {error: "silence clock is in the future by \(-$since)s (timeline event timestamp) — silence age unprovable"}
             else {age: $since} end
         else {age: $age} end) as $r
      | if $r.error then [finding($n; $head; "error"; $r.error)]
        elif $r.age > $wait then [finding($n; $head; "awaiting-stale"; "no approval for \($r.age)s (reviewDecision REVIEW_REQUIRED, quiet period \($wait)s) — trigger a re-review, or apply the fallback approval\($queued)")]
        else [] end
      end
    end;

def reduce_pr($n; $initial; $later):
  # Thread histories can span concurrent pushes, arms and review updates.
  # Keep the first head for binding, but judge the latest state read beside
  # the last thread page before returning silence or a head-sensitive line.
  ($later | last) as $last
  | (if $last == null or $last.status != "ok" then $initial
     else $last.p + {reviewThreads: $initial.reviewThreads} end) as $p
  | if ($p | type) != "object" or $p.number != $n or ($p.headRefOid | sha | not)
     or ($p.state | type) != "string" or ($p | has("isDraft") | not) or ($p.isDraft | type) != "boolean"
     or ($p | has("autoMergeRequest") | not)
     or (($p.autoMergeRequest | type) != "null"
         and (($p.autoMergeRequest | type) != "object" or ($p.autoMergeRequest.mergeMethod | type) != "string"))
     or ($p.createdAt | type) != "string"
  then [finding($n; "--------"; "error"; "PR #\($n) response is not a well-formed PR object (broken read)")]
  else $initial.headRefOid as $head
  # Closed and merged PRs need nothing (reachable through named PRs); a
  # state outside the enum must never read as closed.
  | if $p.state == "CLOSED" or $p.state == "MERGED" then []
    elif $p.state != "OPEN" then [finding($n; $head; "error"; "PR state '\''\($p.state)'\'' is outside the open|closed enum (malformed response)")]
    elif ($p.isInMergeQueue | type) != "boolean"
      or (($p.mergeQueueEntry | type) != "null" and ($p.mergeQueueEntry | type) != "object")
      or ($p | has("reviewDecision") | not)
      or (($p.reviewDecision | type) != "null"
          and ($p.reviewDecision | IN("APPROVED", "CHANGES_REQUESTED", "REVIEW_REQUIRED") | not))
    then [finding($n; $head; "error"; "review-state read is malformed (GraphQL errors, a missing field, or a value outside the queue or reviewDecision enums)")]
    # Pushes to a queued branch are rejected, so every attention line on a
    # queued PR carries the dequeue note. A null reviewDecision, which GitHub
    # answers on a base no approval rule targets, is NONE: never an approval.
    else (if $p.isInMergeQueue or $p.mergeQueueEntry != null then " (QUEUED: dequeue before pushing)" else "" end) as $queued
    | ($p.reviewDecision // "NONE") as $decision
    | threads($p.reviewThreads; $later) as $t
    | if $t.walk then [{n: $n, walk: $t.walk}]
      elif $t.error then [finding($n; $head; "error"; $t.error)]
      else (if $t.overflow then [finding($n; $head; "threads-open"; "review threads beyond the pagination bound (count overflow — fail closed)\($queued)")]
            elif $t.unresolved > 0 then [finding($n; $head; "threads-open"; "\($t.unresolved) unresolved review thread(s)\($queued)")]
            else [] end) as $threads
      # One line per finding: open threads do not suppress an objection, but
      # an open thread holds the re-arm and stale-review nudges.
      | $threads + (
        if $decision == "CHANGES_REQUESTED" then [finding($n; $head; "changes-requested"; "a reviewer requested changes (reviewDecision CHANGES_REQUESTED)\($queued)")]
        elif ($threads | length) > 0 then []
        elif ($decision | IN("APPROVED", "CHANGES_REQUESTED", "NONE", "REVIEW_REQUIRED") | not)
        then [finding($n; $head; "error"; "reviewDecision '\''\($decision)'\'' reached the reduction unhandled — the review-state read admits only APPROVED, CHANGES_REQUESTED, REVIEW_REQUIRED and NONE")]
        elif $p.headRefOid != $head
        then [finding($n; $head; "head-moved"; "the head changed during this reduction (now \($p.headRefOid[0:8])) — findings describe the old head; re-run")]
        else (try $p.commits.nodes[0].commit catch null) as $commit
        | if ($commit | type) != "object" or ($commit.oid | sha | not)
          then [finding($n; $head; "error"; "head commit read returned no usable sha (broken read)")]
          # GitHub lists only the first 250 commits of a PR, so past them the
          # last listed commit is not the head: unreadable, not a push.
          elif $p.commits.totalCount >= 250 and $commit.oid != $head
          then [finding($n; $head; "error"; "head commit is past the 250 commits GitHub lists for a PR (broken read)")]
          elif $commit.oid != $head
          then [finding($n; $head; "head-moved"; "the head changed during this reduction (now \($commit.oid[0:8])) — findings describe the old head; re-run")]
          # GraphQL names an app author without the [bot] suffix REST gives
          # it, and the identity rule is written against the REST shape.
          else ((try ({head: {ref: $p.headRefName},
                       user: ($p.author | if type == "object"
                         then {login: (if .__typename == "Bot" then "\(.login)[bot]" else .login end), type: .__typename}
                         else null end)} | refresh_identity) catch false) == true) as $refresh
          | if $refresh and ($p.isDraft | not) and $decision == "REVIEW_REQUIRED"
            then refresh_ci($commit; $n; $head; $queued)
            # Approved, unarmed, unqueued and ready: nothing will merge it.
            elif $decision == "APPROVED" and ($p.isDraft | not) and $p.autoMergeRequest == null and $queued == ""
            then [finding($n; $head; "disarmed"; "approved (reviewDecision APPROVED) but auto-merge is not armed and the PR is not queued — nothing will merge this (re-arm)")]
            # Drafts await readiness, not review: the clock skips them.
            elif $decision == "REVIEW_REQUIRED" and ($p.isDraft | not) and ($refresh | not)
            then stale($p; $commit; $n; $head; $queued)
            else [] end
          end
        end)
      end
    end
  end;

def page_of($n): try .data.repository["p\($n)"] catch null;

[try inputs catch null] as $documents
| [$documents | to_entries[] | select(.value | type == "object" and has("_watch_round")) | .key] as $starts
| [$starts[] as $i | $documents[$i]._watch_round as $r
   | {status: $r.status,
      numbers: ($r.request.variables | keys_unsorted | map(select(startswith("c")) | ltrimstr("c"))),
      answer: $documents[$i + 1]}] as $rounds
| $documents[:($starts[0] // ($documents | length))] as $pages
| (if $mode == "list" then
     if ($pages | length) == 0
        or any($pages[]; type != "object" or (try (.data.repository.pullRequests.nodes | type) catch null) != "array")
        or any($pages[].data.repository.pullRequests.nodes[]; type != "object" or (.number | type) != "number")
     then null
     else [$pages[].data.repository.pullRequests.nodes[] | {n: .number, p: .}] end
   else [$numbers | split(" ")[] | select(. != "") | tonumber as $n
     | if $read != "ok" then {n: $n, unread: true}
       else {n: $n, p: (if ($pages | length) == 1 then $pages[0] | page_of($n) else null end)} end]
   end) as $prs
| if $prs == null then "global\twatch-list-malformed"
  else [$prs[] | . as $e
    | if $e.unread then [finding($e.n; "--------"; "error"; "could not read PR #\($e.n)")]
      else reduce_pr($e.n; $e.p;
        [$rounds[] | select(any(.numbers[]; . == ($e.n | tostring)))
         | (.answer | page_of($e.n)) as $p | {status, p: $p, page: (try $p.reviewThreads catch null)}])
      end | .[]] as $all
  | [$all[] | select(.walk)] as $walks
  | if ($walks | length) > 0 then $walks | unique_by(.n)
    # The cursor rides a GraphQL variable, never the query text.
    | "walk\t" + ({query: "query($owner:String!,$name:String!\([.[] | ",$c\(.n):String!"] | join(""))){repository(owner:$owner,name:$name){\([.[] | "p\(.n):pullRequest(number:\(.n)){...PRState reviewThreads(first:100,after:$c\(.n)){pageInfo{hasNextPage endCursor} nodes{isResolved}}}"] | join(" "))}} fragment PRState on PullRequest{\($state_fields)}",
        variables: ({owner: $owner, name: $name} + ([.[] | {key: "c\(.n)", value: .walk}] | from_entries))} | tojson)
    else "exit\t\(if any($all[]; .kind == "error") then 2 elif ($all | length) > 0 then 1 else 0 end)",
      ($all[] | "\(.n)\t\(.head)\t\(.kind)\t\(.detail)")
    end
  end'

# A PR whose threads run past a page gets its next page in one request shared
# by every such PR, so a pass grows with the deepest thread history, not with
# the PR count.
rounds=()
reduction_input() {
  # gh can return full shared pages larger than the OS argument limit.
  # Native GraphQL documents have no _watch_round field; the marker binds
  # each response to its request without putting response bytes in argv.
  printf '%s\n' "$main"
  local i
  for ((i=0; i < ${#rounds[@]}; i+=3)); do
    printf '{"_watch_round":{"status":"%s","request":%s}}\n' "${rounds[$i]}" "${rounds[$((i + 1))]}"
    printf '%s\n' "${rounds[$((i + 2))]:-null}"
  done
}
while :; do
  reduced="$(reduction_input | jq -nr --arg mode "$mode" --arg numbers "$PR_ARGS" --arg read "$main_read" \
      --arg state_fields "$PR_STATE_FIELDS" \
      --arg owner "$owner" --arg name "$name" --argjson now "$now" --argjson wait "$AWAITING_AFTER" \
      "def refresh_identity: $REFRESH_IDENTITY_JQ; $REDUCE_JQ")" || {
    watch_message watch-reduce-failed "$GH_REPO" "::error::pr-watch: the reduction failed" >&2
    exit 2
  }
  control="${reduced%%$'\n'*}"
  case "$control" in
    walk$'\t'*) request="${control#walk$'\t'}" ;;
    *) break ;;
  esac
  round_read=ok
  round="$(gh api graphql --input - <<<"$request" 2>/dev/null)" || round_read=failed
  [ "$round_read" = failed ] || [ -n "$round" ] || round_read=empty
  rounds+=("$round_read" "$request" "$round")
done

case "$control" in
  exit$'\t'[012]) ;;
  global$'\t'watch-list-malformed)
    watch_message watch-list-malformed "$GH_REPO" "::error::pr-watch: open-PR listing pages are malformed (broken read or a row without a number)" >&2
    exit 2
    ;;
  *)
    watch_message watch-reduce-unexpected "$control" "::error::pr-watch: the reduction answered no known control line" >&2
    exit 2
    ;;
esac
if [ "$reduced" != "$control" ]; then
  printf '%s\n' "${reduced#*$'\n'}"
fi
exit "${control#*$'\t'}"
