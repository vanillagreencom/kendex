#!/bin/bash
set -euo pipefail

# merge-pr and submit-pr consume the merge-route line on stderr. A lane
# records its admin|queue route and cause in its status and PR body.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/github-api.sh"
TRANSIENT_PREFIXES='unknown:|ci_pending:|ci_unconfigured:|ci_fetch_failed:'

# Scope a `gh pr checks` array to the current authoritative substantive run per
# workflow. Shared with orch `ci-wait` so the merge gate and the waiter cannot
# disagree about which run is current — see the library for the
# full rationale.
# shellcheck source=../lib/ci-run-correlation.sh
source "$SCRIPT_DIR/../lib/ci-run-correlation.sh"

show_help() {
    cat <<'EOF'
Merge PR as bot account with safety checks

Usage: pr-merge <PR_NUMBER> [options]

Options:
  --squash         Accept a squash merge
  --merge          Accept a merge commit
  --rebase         Accept a rebase merge
                   Repeat to accept several, most preferred first; none of
                   the three accepts all of them, squash first. See Merge
                   method below.
  --delete-branch  Delete the head branch after an immediate merge, where
                   the repository's delete_branch_on_merge is off and the
                   head is not a fork's
  --keep-branch    Keep the head branch (the default)
  --check          Run checks only, don't merge. JSON on stdout; a one-word
                   verdict (mergeable|blocked|merged|closed) plus the run
                   scope ("head-run: <ids>" — the runs the CI classification
                   was scoped to) on stderr. On a refusal,
                   ci-classify-refusal names the cause.
  --auto           Read the merge route. Refuse an admin route unless
                   --queue is explicit; otherwise enable GitHub auto-merge
                   (fires when CI + branch protection clear). Exits 75.
                   Arms only where the base branch's rulesets require at
                   least 1 approval and thread resolution and dismiss
                   stale approvals on push, and the review replies pass;
                   see Approvals and review threads and Review replies
                   below.
  --expected-head SHA
                   Bind GitHub's match-head merge guard to prepared SHA.
  --queue          With --auto only: explicitly arm through the queue even
                   where the merge route would allow a direct admin merge.
  --dry-run        Show what would happen without merging

Modes:
  (default)        Run checks, block if critical issues, merge if pass
  --check          Run checks, output JSON for workflow to parse
  --auto           Enable auto-merge when immediate merge is blocked

Merge-mode exit codes:
  0    MERGED PR #N
       Merge completed immediately.
  0    ALREADY MERGED PR #N <mergedAt>
       The PR was merged before this call. Nothing was attempted.
  75   QUEUED IN MERGE QUEUE PR #N
       The required merge queue has an active entry.
  75   AUTO-MERGE ENABLED PR #N
       Classic auto-merge is armed until protection clears.
  1    BLOCKED PR #N
       The requested operation failed; a pre-existing queue entry or auto-merge request may remain active.
  1    merge-route: admin cause=queue-bypass-safe ruleset=<ids> bypass=<values>
       --auto armed nothing: the immediate merge takes this PR
       past the queue, and an arm would queue it first.
  1    arm: no-merge-gate=<allow_auto_merge|required_approval|required_thread_resolution|dismiss_stale_reviews|unverified> repo=<owner/repo>
       --auto refused, nothing mutated. allow_auto_merge: the repository has
       auto-merge off. required_approval: no ruleset on the base branch
       requires an approval, so GitHub would merge the armed PR before any
       review. required_thread_resolution: an approval is required but no
       ruleset requires thread resolution, so GitHub would merge the armed
       PR on its first approval past open review threads.
       dismiss_stale_reviews: approvals and thread resolution are required
       but no ruleset dismisses stale approvals on push, so GitHub would
       merge the armed PR on an approval of an earlier head, with no review
       of the pushed one. unverified: a read failed, or a pull_request
       rule's approval count did not read as a whole number or one of its
       two flags as a boolean, which proves no gate.
  1    pr-merge: merge-method allowed=<method,...|none> accepted=<method,...>
  1    pr-merge: merge-method-unreadable cause=<base|rules|settings|queue>
       Nothing mutated: the base allows none of the accepted methods, or its
       method could not be read; see Merge method below.
  1    CLOSED (not merged) PR #N
       The PR is closed unmerged. Nothing was attempted.

--check exit:
  --check exits 0 after any valid readiness JSON, including can_merge=false for
  blocked or CLOSED. Argument or dispatch failures before JSON remain nonzero.

Exit 75 is volatile:
  A queue ejection can disarm merge state. Block on .agents/skills/orch/scripts/queue-wait <N> <poll> <budget> --json before returning; it produces the verdict for the head just armed. Size the poll and budget as orch merge-pr.md § 5 step 1 does: the default budget outlives any foreground call an agent harness holds, so a call without them is killed before the verdict.
  Route verdicts through queue-wait --help Verdicts, named by SKILL.md § PR Merge Outcomes; the review-gate reducer still reports fleet attention.
  Re-arm only through the merge route of orch merge-pr.md § 5 step 1 after
  that route: the workflow picks the direct attempt or an explicit queue
  arm after its readiness and approval checks.

Approvals and review threads:
  GitHub enforces both, through the base branch's ruleset pull_request
  rules, the most restrictive of them applying: it holds the merge, and an
  armed PR, until the required approvals are in and, only where a rule sets
  required_review_thread_resolution, until every review thread is resolved.
  An approval keeps counting after a push unless a rule sets
  dismiss_stale_reviews_on_push. GitHub defaults both flags to false on a new
  rule, so a base can require an approval and still merge past an open
  thread, or merge a pushed head on the approval of an earlier one. This
  command resolves no review thread. It reports reviewDecision as review,
  blocks on a changes-requested review, and names a missing approval as the
  not_approved warning.

  --auto reads every pull_request rule on the base branch
  (repos/{owner}/{repo}/rules/branches/<base>, which returns the rules of
  every active ruleset, organization and repository) and arms only where
  each of these is set by one rule, the same or another: at least 1
  approval, thread resolution, and stale approvals dismissed on push.
  Classic branch protection's review settings are not read: a base gated
  there alone is refused as required_approval, which arms nothing.

Review replies:
  GitHub's approval and thread resolution prove that a reply exists, never
  what it says, and a reply can change without a push. So each readiness
  check, the one --check, the merge and the --auto arm run, runs
  check-review-replies <N>, a read-only live read of the replies
  (github.sh check-review-replies --help states its rules). A failing rule
  is one permanent issue joining its rule lines:
    review_replies: <rule line>; <rule line>...
  A reply check that reaches no verdict is permanent too, carrying its
  first stderr line:
    review_replies_unread: check-review-replies: <key> pr=<N>
  --auto defers every other blocker to GitHub, but no GitHub rule holds an
  armed PR on a reply, so either issue refuses the arm as it refuses a
  merge: BLOCKED, exit 1, nothing armed. The check holds at the moment
  this command runs and no later: a PR armed before its replies exist is
  not read again by pr-merge while it stays armed or queued.

Merge route:
  The immediate merge takes one of two routes past a merge queue, and reads
  which before its merge call, under the merge's own token, since GitHub
  answers the bypass question per caller. GitHub applies --admin to every
  rule the token may bypass, not to the queue alone, so the route reads the
  base branch's rules and each ruleset they name, current_user_can_bypass
  included, and the branch's classic protection. It names the route on
  stderr, ahead of the merge call:

    merge-route: admin cause=queue-bypass-safe ruleset=<ids> bypass=<values>
        Every ruleset holding a merge_queue rule holds no other rule and
        answers always, pull_requests_only or exempt; every other ruleset on
        the base answers never; the base has no classic protection; the base
        allows a direct merge with one of the accepted methods (see Merge
        method); the base's merge queue is empty; and the PR is not
        queue-only. The merge call adds --admin, bound to the
        verified head by --match-head-commit, and exits 0 once merged. So the
        queue is all --admin skips: GitHub still refuses the merge unless
        every other ruleset, the required checks, thread resolution and
        approvals among them, passes on that head. ids and values name the
        merge-queue rulesets, comma-joined. The next line is the
        classifier's queue-only line.
    merge-route: queue cause=<cause> [ruleset=<id>] [rule=<type>] [bypass=<value>] [allowed=<method,...|none> accepted=<method,...>] [read=<what>]
        The merge call passes --auto and no --admin, so GitHub enrolls the
        PR in the queue (exit 75): GitHub refuses a merge call on a queue
        base that passes neither. This --auto reads no approval rule, as
        the plain merge does not. cause is ruleset-unreadable
        (that ruleset could not be read), queue-ruleset-mixed (that
        merge-queue ruleset also holds the rule named as rule=), no-bypass
        (that merge-queue ruleset answered another value for this token,
        named as bypass=), other-bypass (that ruleset without the queue
        answered a value other than never), classic-protection (the base has
        classic branch protection), protection-unreadable (the branch's
        protection could not be read), direct-method (a direct merge allows
        none of the accepted methods, the methods it allows named as
        allowed=), direct-method-unreadable (the methods a direct merge
        allows could not be read, read= naming the read as the
        merge-method-unreadable cause does), explicit-queue (--auto --queue
        intentionally arms a PR eligible for the admin route), queue-occupied
        (the base's queue holds entries), queue-unreadable (its entry count
        could not be read as a whole number) or queue-only (the next lines
        are the classifier's queue-only line or the cause it was not read,
        and its diagnostics).

  A base whose rules hold no merge_queue rule prints no route line: there is
  no queue to bypass, and the merge call is the plain one. --auto, --check
  and --dry-run never pass --admin. Every live --auto attempt reads the
  route: where it reads admin, it arms nothing and exits 1 on the admin
  line above; otherwise it arms. --auto --queue explicitly chooses the
  queue instead of that admin route. --check and --dry-run mutate nothing.

  The queue-only class is read only once everything else allows the admin
  route, from <skills>/harness-ci/scripts/change-class, else change-class on
  PATH, over the PR's base and head. The classifier takes a merge-base diff, so both commits AND an ancestor they share must be in this
  checkout, and baseRefOid is the base branch's current tip: the two SHAs
  are fetched from origin (no tags, no FETCH_HEAD rewrite) when the range is
  not readable, and it is checked again. Its stderr
  `queue-only: queue_only=true|false` line is the class, and change-class
  --help states when it reads true. No classifier, an unreadable range, a
  range whose head is not the head the merge is pinned to (cause=head-moved),
  a failed classifier and a missing line all read queue-only.

Merge method:
  The merge modes and --dry-run read the method from GitHub, never --check. A
  merge_queue rule on the base branch fixes it to the queue's merge_method.
  Otherwise the base allows the repository's allowed methods, narrowed by
  the allowed_merge_methods of every pull_request rule on it. The admin
  route merges past the queue, so it takes its method from that second set,
  whatever the queue's merge_method. The first
  accepted method the base allows is passed to gh pr merge. A base that
  allows none of the accepted methods refuses before any mutation with one
  line, exit 1:
    pr-merge: merge-method allowed=<method,...|none> accepted=<method,...>
  A read that fails refuses the same way, exit 1:
    pr-merge: merge-method-unreadable cause=<base|rules|settings|queue>
  settings is the repository's allow_* flags, which GitHub omits for a
  token without push access.

Branch deletion:
  --delete-branch deletes the head branch after an immediate MERGED only
  where the repository's delete_branch_on_merge is off; where it is on,
  GitHub deletes the branch. A fork's head branch lives in the fork and is
  never deleted. A kept branch is said on stderr, exit still 0:
    pr-merge: branch-kept branch=<name> cause=<cross-repository|cross-repository-unreadable|setting-unreadable>
  cross-repository-unreadable: GitHub did not say whether the head is a
  fork's; setting-unreadable: the delete_branch_on_merge read failed.
  A merge the queue makes later is GitHub's alone.

Terminal and mutation rules:
  After github.sh router setup, MERGED or CLOSED short-circuits pr-merge safety
  checks, bot-token load, and merge-state mutation; UNKNOWN continues to the
  readiness check, which re-reads it, and any mode, --auto included, refuses
  with nothing merged or armed when that read is not OPEN. --check reports state.

  Every gh pr merge invocation is exact-head guarded by --match-head-commit; a changed head is BLOCKED.
  Queue membership comes from GraphQL isInMergeQueue and mergeQueueEntry. An
  OPEN PR with an active queue entry exits 75 even when autoMergeRequest is
  absent. An OPEN PR with no queue or auto-merge proof fails closed. The
  --delete-branch cleanup after MERGED is best-effort, not merge-state mutation.

--check JSON:
  stdout is one object with these fields:
    can_merge   boolean readiness result
    issues      blocking issue strings
                unknown: cause=computing when GitHub answers UNKNOWN;
                unknown: cause=read-failed when the read fails or is invalid
    warnings    non-blocking issue strings
    mergeable   MERGEABLE, CONFLICTING, or UNKNOWN
    review      GitHub review decision
    transient   retry classification; see issue prefixes below
    state       OPEN, MERGED, CLOSED, or UNKNOWN
    merged_at   merge timestamp, or an empty string
    head_runs   run IDs used for CI classification
    checks      raw check rollup read by the classification
    required_contexts
                classic base-branch context names
    requirements
                complete classic-context and required-workflow evidence used
                by classification and refusal diagnosis

  stderr carries mergeable, blocked, merged, or closed, followed by
  head-run: <ids> when CI runs were classified. can_merge=false with an empty
  issues array means the PR is terminal; inspect state instead of treating it
  as a blocker to repair.

  transient=true requires every issue prefix to be unknown:, ci_pending:,
  ci_unconfigured:, or ci_fetch_failed:. A ci_failed: issue is permanent, as
  are conflicts, changes_requested, review_replies and review_replies_unread. Running checks use ci_pending: while
  failed or cancelled checks use ci_failed:.

  ci_pending: and ci_failed: name only contexts the base branch requires, read
  from its rulesets and classic protection. A red check outside that set is a
  ci_optional_failed: warning, which blocks nothing — GitHub merges over it. A
  required context that has registered no check on the head is ci_pending:
  "<context> (missing)", the state GitHub itself is in while it waits. A base
  that requires nothing, other unreadable protection or an unnameable rule
  type counts every check. Required workflows contribute their check links
  from current completed runs on the head in the consumer repository.
  Their source repository, path and configured revision must be proved by
  the workflow file metadata. Distinct definitions cannot share an execution.
  Optional pending or queued checks hold nothing. A pending required workflow
  or unregistered jobs hold as ci_pending. Unreadable workflow evidence
  refuses as ci_fetch_failed even when visible jobs pass. A failed required
  workflow holds as ci_failed.

  head_runs contains the authoritative workflow run plus runs referenced by
  custom commit statuses. checks is the same snapshot consumed by
  ci-classify-refusal <N>, so cause:, fail:, and superseded: lines cannot race
  a second fetch.

Examples:
  github.sh pr-merge 42 --check          # Check only, JSON output
  github.sh pr-merge 42                  # Check + merge if pass
  github.sh pr-merge 42 --auto           # Route-aware arm; see Merge route
EOF
}

# One authoritative read of the PR's lifecycle state, published in
# PR_STATE_JSON. Also validates that the PR exists — a bare number does not.
# Every caller shares the single fetch; a failed read is not cached, so the
# next caller retries rather than inheriting an empty state.
#
# On failure PR_STATE_ERROR carries a prefixed issue string. Only GitHub's
# own "this PR does not exist" wording becomes `not_found:` — an auth, network,
# rate-limit, or API failure keeps its own diagnostic instead of being
# reported as a missing PR.
PR_STATE_JSON=""
PR_STATE_JSON_PR=""
PR_STATE_ERROR=""
load_pr_state_json() {
    local pr_num="$1"
    if [ -n "$PR_STATE_JSON_PR" ] && [ "$PR_STATE_JSON_PR" = "$pr_num" ]; then
        return 0
    fi

    local err_file state_json status=0
    if ! err_file=$(mktemp "${TMPDIR:-/tmp}/pr-merge-state.XXXXXX"); then
        PR_STATE_ERROR="gh_error: could not create a temporary file for the PR state lookup"
        return 1
    fi

    state_json=$(gh pr view "$pr_num" --json state,mergedAt 2>"$err_file") || status=$?
    local detail
    detail=$(grep -v '^[[:space:]]*$' "$err_file" | head -1)
    rm -f "$err_file"

    if [ "$status" -eq 0 ]; then
        PR_STATE_JSON="$state_json"
        PR_STATE_JSON_PR="$pr_num"
        PR_STATE_ERROR=""
        return 0
    fi

    case "$detail" in
    *"Could not resolve to a PullRequest"* | *"o pull requests found"*)
        PR_STATE_ERROR="not_found: PR #$pr_num not found"
        ;;
    "")
        PR_STATE_ERROR="gh_error: gh pr view exited $status with no diagnostic"
        ;;
    *)
        PR_STATE_ERROR="gh_error: $detail"
        ;;
    esac
    return 1
}

# Report a PR that has left OPEN and exit. Every mode routes its terminal
# states through here so the outcome lines and exit codes cannot diverge.
# Any other state returns and lets the caller continue.
exit_terminal_state() {
    local state="$1" pr_num="$2" merged_at="${3:-}"

    case "$state" in
    MERGED)
        if [ -n "$merged_at" ]; then
            echo "ALREADY MERGED PR #$pr_num $merged_at" >&2
        else
            echo "ALREADY MERGED PR #$pr_num" >&2
        fi
        exit 0
        ;;
    CLOSED)
        echo "CLOSED (not merged) PR #$pr_num" >&2
        echo "  No merge attempted, none queued. Reopen the PR or supersede it." >&2
        exit 1
        ;;
    esac
}

# harness-ci's classifier, asked for one pull request's queue-only class, runs
# out of the checkout through here. GH_CONFIG_DIR is dropped: a GH_CONFIG_DIR
# the caller exported is a credential of theirs that checkout code has no
# business reading. The child's stderr goes to the caller's FILE whatever the
# exit, replayed by no one here: that caller reads its answer off the stderr
# and replays it itself. Its stdout is this function's.
run_checkout_child() { # FILE DIR ARGV...
    local err="$1" dir="$2"
    shift 2
    local out status=0
    out=$(cd -- "$dir" && env -u GH_CONFIG_DIR "$@" 2>"$err") || status=$?
    [ "$status" -eq 0 ] || return "$status"
    printf '%s' "$out"
}

# The checkout this command runs in: its repository root, else the working
# directory. The classifier runs there, and the pull request's two commits
# are fetched into it.
checkout_root() {
    git rev-parse --show-toplevel 2>/dev/null || pwd
}

# The pull request's range as GitHub reports it: the base branch's current
# tip and the head, blank-separated. Non-zero where it cannot be read, with
# gh's own words, or the missing end, on stderr for the caller to keep.
pr_range() { # PR
    local range_json base_sha head_sha
    range_json=$(gh pr view "$1" --json baseRefOid,headRefOid) || return 1
    base_sha=$(jq -r '.baseRefOid // ""' <<<"$range_json") || return 1
    head_sha=$(jq -r '.headRefOid // ""' <<<"$range_json") || return 1
    if [ -z "$base_sha" ] || [ -z "$head_sha" ]; then
        echo "pr-merge: pull request #$1 reports no base or head commit" >&2
        return 1
    fi
    printf '%s %s' "$base_sha" "$head_sha"
}

# The range, as this checkout can read it: both ends present AND an ancestor
# they share, since the classifier takes a merge-base diff and a shallow or
# grafted checkout can hold two commits with no reachable ancestor between
# them.
pr_range_present() { # ROOT BASE HEAD
    git -C "$1" cat-file -e "$2^{commit}" 2>/dev/null &&
        git -C "$1" cat-file -e "$3^{commit}" 2>/dev/null &&
        git -C "$1" merge-base "$2" "$3" >/dev/null 2>&1
}

# Make the range readable here, or say why it is not. baseRefOid is the base
# branch's CURRENT tip, which a checkout that has not fetched since another
# pull request merged does not hold, and no classifier can read a diff to a
# commit that is not here. Fetch the TWO SHAs, never every ref, without tags
# and without writing FETCH_HEAD, so the read neither downloads tags nor
# rewrites FETCH_HEAD in a git directory other worktrees share. Then look
# again; a range still unreadable returns non-zero and the caller refuses.
# git's own words for a failed fetch are replayed under the fixed line, so an
# unreachable SHA, an auth failure and a dead network do not read alike.
pr_range_materialize() { # ROOT BASE HEAD
    local root="$1" base_sha="$2" head_sha="$3" err
    pr_range_present "$root" "$base_sha" "$head_sha" && return 0
    if ! err=$(git -C "$root" fetch --quiet --no-tags --no-write-fetch-head \
        origin "$base_sha" "$head_sha" 2>&1); then
        echo "pr-merge: the pull request's range is not in this checkout and the fetch of its two commits from origin failed:" >&2
        printf '%s\n' "$err" >&2
    fi
    pr_range_present "$root" "$base_sha" "$head_sha"
}

# A sibling skill's script: <skills>/SKILL/scripts/NAME beside this scripts
# tree, else NAME on PATH, else nothing. The queue-only classifier is found
# here.
sibling_script() { # SKILL NAME
    local path="$SCRIPT_DIR/../../../$1/scripts/$2"
    [ -x "$path" ] || path=$(command -v "$2" 2>/dev/null) || path=""
    printf '%s' "$path"
}

run_checks() {
    local pr_num="$1"
    local can_merge=true
    local issues=()
    local warnings=()
    local head_runs_json='[]' checks_json='[]' required_json='[]'

    local pr_state pr_merged_at
    if ! load_pr_state_json "$pr_num"; then
        jq -n --arg issue "$PR_STATE_ERROR" '{can_merge: false, issues: [$issue], warnings: [], mergeable: "UNKNOWN", review: "", transient: false, state: "UNKNOWN", merged_at: "", head_runs: [], checks: [], required_contexts: [], requirements: []}'
        return 0 # Return 0 so JSON is output, caller checks can_merge
    fi
    pr_state=$(jq -r '.state // "UNKNOWN"' <<<"$PR_STATE_JSON")
    pr_merged_at=$(jq -r '.mergedAt // ""' <<<"$PR_STATE_JSON")

    # A terminal PR is unmergeable for a reason no caller can act on, and its
    # check data is meaningless: `mergeable` is permanently UNKNOWN, post-merge
    # CI runs and bot comments are not blockers. Report the state, no issues.
    if [ "$pr_state" = "MERGED" ] || [ "$pr_state" = "CLOSED" ]; then
        jq -n --arg state "$pr_state" --arg merged_at "$pr_merged_at" '{can_merge: false, issues: [], warnings: [], mergeable: "UNKNOWN", review: "", transient: false, state: $state, merged_at: $merged_at, head_runs: [], checks: [], required_contexts: [], requirements: []}'
        return 0
    fi

    local mergeable="UNKNOWN" mergeable_err mergeable_status=0 mergeable_detail=""
    if ! mergeable_err=$(mktemp "${TMPDIR:-/tmp}/pr-merge-mergeable.XXXXXX"); then
        mergeable_detail="could not create a temporary file for the mergeable lookup"
    else
        mergeable=$(gh pr view "$pr_num" --json mergeable --jq '.mergeable' 2>"$mergeable_err") || mergeable_status=$?
        if [ "$mergeable_status" -ne 0 ]; then
            mergeable_detail=$(sed -n '/[^[:space:]]/{p;q;}' "$mergeable_err") || mergeable_detail="gh pr view exited $mergeable_status; diagnostic read failed"
            [ -n "$mergeable_detail" ] || mergeable_detail="gh pr view exited $mergeable_status with no diagnostic"
        else
            case "$mergeable" in
            MERGEABLE | CONFLICTING | UNKNOWN) ;;
            *) mergeable_detail="gh pr view returned invalid mergeable answer '$mergeable'" ;;
            esac
        fi
        rm -f -- "$mergeable_err"
    fi
    if [ -n "$mergeable_detail" ]; then
        mergeable="UNKNOWN"
        can_merge=false
        issues+=("unknown: cause=read-failed $mergeable_detail; retry, or arm with --auto")
    elif [ "$mergeable" = "UNKNOWN" ]; then
        can_merge=false
        issues+=("unknown: cause=computing GitHub still computing mergeable status; retry, or arm with --auto")
    fi
    if [ "$mergeable" = "MERGEABLE" ]; then
        : # ok
    elif [ "$mergeable" = "CONFLICTING" ]; then
        can_merge=false
        issues+=("conflicts: PR has merge conflicts. Resolve by rebasing onto your default branch and force-pushing")
    fi

    # 2. Check CI status. The fetch tolerance (gh exit 8 with usable JSON)
    # lives with the shared fetch_checks_rollup.
    local ci_json
    if ! ci_json=$(fetch_checks_rollup "$pr_num"); then
        can_merge=false
        issues+=("ci_fetch_failed: Failed to fetch CI checks from GitHub")
    else
        # Drop checks belonging to superseded workflow runs before classifying,
        # so a prior canceled run can't be reported as a current merge blocker.
        # Mirrors orch ci-wait's pre-classification scoping; the shared
        # classify_checks_rollup carries the scoping and name-sanitization
        # contract, including the required contexts that registered no check.
        local rollup pending failed optional_failed required_evidence required_state
        required_evidence=$(required_contexts "$pr_num") || required_evidence='{"state":"unreadable","contexts":[]}'
        required_state=$(jq -r '.state' <<<"$required_evidence")
        required_json="$required_evidence"
        case "$required_state" in
            ready) ;;
            pending) can_merge=false; issues+=("ci_pending: Required workflow") ;;
            failed) can_merge=false; issues+=("ci_failed: Required workflow") ;;
            unreadable) can_merge=false; issues+=("ci_fetch_failed: Required workflow evidence unavailable") ;;
            *) echo "pr-merge: required-state=$required_state" >&2; return 1 ;;
        esac
        if [ "$required_state" != ready ]; then
            checks_json="$ci_json"
            head_runs_json=$(scope_current_run <<<"$ci_json" | jq -c "$CI_RUN_JQ_DEFS"'head_runs')
        else
            rollup=$(echo "$ci_json" | classify_checks_rollup "$required_json")
            checks_json=$(jq -c '.checks' <<<"$rollup")
            head_runs_json=$(jq -c '.head_runs' <<<"$rollup")
            pending=$(jq -r '.pending' <<<"$rollup")
            failed=$(jq -r '.failed' <<<"$rollup")
            optional_failed=$(jq -r '.optional_failed' <<<"$rollup")
            # An empty rollup is "no status checks configured" only where the base
            # requires none. With a required context outstanding the checks ARE
            # configured and none has reported yet, which the classification
            # already names in `pending`.
            if [ "$(jq 'length' <<<"$ci_json")" -eq 0 ] && [ -z "$pending" ]; then
                warnings+=("ci_unconfigured: No status checks configured")
            fi
            if [ -n "$pending" ]; then
                can_merge=false
                issues+=("ci_pending: $pending")
            fi
            if [ -n "$failed" ]; then
                can_merge=false
                issues+=("ci_failed: $failed")
            fi
            # A warning, not an issue: the base branch does not require these, so
            # GitHub merges over them and so must this gate.
            if [ -n "$optional_failed" ]; then
                warnings+=("ci_optional_failed: $optional_failed")
            fi
        fi
    fi

    # reviewDecision requires branch protection; latestReviews covers both terminal review states.
    local review="" has_approved_review=false has_changes_requested=false
    local review_json
    if ! review_json=$(json_or_default '{}' object gh pr view "$pr_num" --json reviewDecision,latestReviews); then
        can_merge=false
        issues+=("review_fetch_failed: Failed to fetch review status from GitHub")
    else
        review=$(echo "$review_json" | jq -r '.reviewDecision // ""')
        has_approved_review=$(echo "$review_json" | jq '[.latestReviews[] | select(.state == "APPROVED")] | length > 0')
        has_changes_requested=$(echo "$review_json" | jq '[.latestReviews[] | select(.state == "CHANGES_REQUESTED")] | length > 0')

        if [ "$review" = "CHANGES_REQUESTED" ] || [ "$has_changes_requested" = "true" ]; then
            can_merge=false
            issues+=("changes_requested: Reviewer requested changes")
        elif [ "$review" != "APPROVED" ] && [ "$has_approved_review" != "true" ]; then
            warnings+=("not_approved: Review status is '$review'")
        fi
    fi

    # GitHub's approval and thread resolution cannot read what a reply says,
    # and a reply can change without a push, so check-review-replies reads
    # the replies live on every check. Its rule lines join into one issue.
    local replies_out replies_err replies_rc=0
    if ! replies_err=$(mktemp "${TMPDIR:-/tmp}/pr-merge-replies.XXXXXX"); then
        can_merge=false
        issues+=("review_replies_unread: could not create a temporary file for the reply check")
    else
        replies_out=$(bash "$SCRIPT_DIR/check-review-replies.sh" "$pr_num" 2>"$replies_err") || replies_rc=$?
        case "$replies_rc" in
        0) ;;
        1)
            can_merge=false
            issues+=("review_replies: $(sed 1d <<<"$replies_out" | paste -s -d ';' - | sed 's/;/; /g')")
            ;;
        *)
            can_merge=false
            issues+=("review_replies_unread: $(grep -m 1 -v '^[[:space:]]*$' "$replies_err" || echo "check-review-replies exited $replies_rc")")
            ;;
        esac
        rm -f "$replies_err"
    fi

    local issues_json warnings_json
    issues_json=$(printf '%s\n' "${issues[@]:-}" | jq -R -s -c 'split("\n") | map(select(. != ""))')
    warnings_json=$(printf '%s\n' "${warnings[@]:-}" | jq -R -s -c 'split("\n") | map(select(. != ""))')

    local transient
    transient=$(echo "$issues_json" | jq --arg p "^($TRANSIENT_PREFIXES)" '
        (length > 0) and (all(. | test($p)))
    ')

    jq -n \
        --argjson can_merge "$can_merge" \
        --argjson issues "$issues_json" \
        --argjson warnings "$warnings_json" \
        --arg mergeable "$mergeable" \
        --arg review "$review" \
        --argjson transient "$transient" \
        --arg state "$pr_state" \
        --arg merged_at "$pr_merged_at" \
        --argjson head_runs "$head_runs_json" \
        --argjson checks "$checks_json" \
        --argjson required_contexts "$required_json" \
        "$CI_RUN_JQ_DEFS"'{can_merge: $can_merge, issues: $issues, warnings: $warnings, mergeable: $mergeable, review: $review, transient: $transient, state: $state, merged_at: $merged_at, head_runs: $head_runs, checks: $checks, required_contexts: (requirement_set($required_contexts) | .contexts), requirements: $required_contexts}'
}

# True when --auto answers the readiness result no better than a merge: a
# state other than OPEN, whose checks returned before the reply check ran, or
# a reply-check issue. No GitHub rule holds an armed PR on a reply.
auto_refused() {
    jq -e '.state != "OPEN" or any(.issues[]; startswith("review_replies"))' >/dev/null <<<"$1"
}

print_blocked() {
    local check_result="$1"
    local pr_num="$2"
    local transient
    transient=$(echo "$check_result" | jq -r '.transient')

    echo "BLOCKED PR #$pr_num — no merge attempted, none queued" >&2
    if [ "$transient" = "true" ]; then
        echo "  (transient: GitHub read unavailable, mergeability computing or CI pending)" >&2
    else
        echo "  (permanent — needs fix or review action)" >&2
    fi
    echo "$check_result" | jq -r '.issues[]' | sed 's/^/  ✗ /' >&2
    echo "$check_result" | jq -r '.warnings[]' | sed 's/^/  ⚠ /' >&2
    echo "" >&2
    auto_refused "$check_result" || echo "Use --auto to queue for auto-merge." >&2
}

# Run gh with the same effective identity used for the merge mutation. Keep the token scoped to the
# subprocess so the caller's environment is never changed.
with_token() {
    local auth_token="${1:-}"
    shift

    if [ -n "$auth_token" ]; then
        GH_TOKEN="$auth_token" "$@"
    else
        "$@"
    fi
}

# Print why `gh pr merge --auto` must not arm, or nothing. With auto-merge off
# GitHub cannot arm. Otherwise the arm needs every row of `shape`, the rule
# shape under which GitHub holds an armed PR until a review of its current
# head: each row names the gap word printed when no active pull_request rule
# on the base meets it (GitHub applies the most restrictive rule, so any one
# rule meeting a row meets it), the rule parameter, and its kind: a `count`
# of at least 1 or a `flag` set true. Without the approval GitHub merges the
# armed PR the moment its checks pass; without thread resolution, on the
# approval past every open thread; without stale-approval dismissal, on an
# approval of an earlier head after a push no review saw. A failed read, or a
# pull_request rule whose value for any row is not of the row's kind, prints
# `unverified`. Rows are checked in order, so the first gap is printed.
#
# review-gate's validate-standard.sh reads the thread-resolution flag inside
# its own audit of the default branch; it is a sibling skill's report, not a
# predicate this command can call, so the flag is read here too, beside the
# approval count and stale-dismissal flag that audit does not read.
merge_gate_gap() {
    local pr_num="$1" token="$2" allow="" base="" rules="" gap=""
    local -a shape=(
        'required_approval required_approving_review_count count'
        'required_thread_resolution required_review_thread_resolution flag'
        'dismiss_stale_reviews dismiss_stale_reviews_on_push flag'
    )
    allow=$(with_token "$token" gh api 'repos/{owner}/{repo}' --jq '.allow_auto_merge' 2>/dev/null) || allow=""
    case "$allow" in
        true) ;;
        false) echo allow_auto_merge; return 0 ;;
        *) echo unverified; return 0 ;;
    esac
    if ! base=$(with_token "$token" gh pr view "$pr_num" --json baseRefName --jq '.baseRefName' 2>/dev/null) || [ -z "$base" ] \
        || ! base=$(jq -nr --arg v "$base" '$v | @uri') \
        || ! rules=$(with_token "$token" gh api "repos/{owner}/{repo}/rules/branches/$base" --paginate --jq '.[] | select(.type == "pull_request") | .parameters | tojson' 2>/dev/null); then
        echo unverified; return 0
    fi
    # One JSON line per pull_request rule; a base with none yields no line,
    # so every row is unmet.
    if ! gap=$(jq -rn --args '
        def fits($kind): if $kind == "count" then type == "number" and . >= 0 and . == floor else type == "boolean" end;
        def meets($kind): if $kind == "count" then . >= 1 else . == true end;
        [$ARGS.positional[] | split(" ")] as $shape | [inputs] as $rules
        | if any($rules[]; . as $rule | any($shape[]; . as [$gap, $key, $kind] | $rule[$key] | fits($kind) | not)) then "unverified"
          else first($shape[] | . as [$gap, $key, $kind] | select(any($rules[]; .[$key] | meets($kind)) | not) | $gap) // empty end
    ' "${shape[@]}" <<<"$rules" 2>/dev/null); then
        echo unverified; return 0
    fi
    [ -z "$gap" ] || echo "$gap"
}

# The method the merge modes pass to gh pr merge: the first of the accepted
# methods the base branch allows, kendex_github_merge_method's answer. A
# refusal is the one line --help § Merge method names; stdout is the method.
merge_method() { # PR TOKEN ACCEPTED...
    local pr_num="$1" token="$2" base="" answer="" rc=0
    shift 2
    if ! base=$(with_token "$token" gh pr view "$pr_num" --json baseRefName --jq '.baseRefName' 2>/dev/null) || [ -z "$base" ]; then
        echo "pr-merge: merge-method-unreadable cause=base" >&2
        return 1
    fi
    answer=$(with_token "$token" kendex_github_merge_method '{owner}/{repo}' "$base" "$@") || rc=$?
    case "$rc" in
        0) printf '%s\n' "$answer" ;;
        2)
            local IFS=,
            echo "pr-merge: merge-method allowed=$answer accepted=$*" >&2
            return 1
            ;;
        *)
            echo "pr-merge: merge-method-unreadable cause=$answer" >&2
            return 1
            ;;
    esac
}

volatile_note() {
    local pr_num="$1" repo="${GH_REPO:-}" remote resolved reducer
    # pr-watch.sh requires GH_REPO; print the reducer with the repository it
    # will need. Resolved LOCALLY (env, else the origin remote) — no network
    # request may stand between a queued/armed PR and its exit 75. When
    # nothing local names it the placeholder keeps the shape and says so.
    local remote_name="origin"
    if [ -z "$repo" ]; then
        # gh's configured default (`gh repo set-default`) is stored as
        # remote.<name>.gh-resolved: an OWNER/REPO value names the repository
        # gh operates on when the checkout is a fork; "base" means that
        # remote's own repository — resolve that remote's URL, not origin's.
        resolved="$(git config --get-regexp '^remote\..*\.gh-resolved$' 2>/dev/null | awk 'NF == 2 { print $1, $2; exit }' || true)"
        if [ -n "$resolved" ]; then
            if [ "${resolved##* }" = "base" ]; then
                remote_name="${resolved% *}"
                remote_name="${remote_name#remote.}"
                remote_name="${remote_name%.gh-resolved}"
            else
                repo="${resolved##* }"
            fi
        fi
    fi
    if [ -z "$repo" ]; then
        remote="$(git config --get "remote.$remote_name.url" 2>/dev/null || true)"
        case "$remote" in
            *github.com[:/]*/*)
                repo="${remote##*github.com[:/]}"
                repo="${repo%.git}"
                repo="${repo%/}"
                ;;
        esac
    fi
    # Only an OWNER/REPO-shaped value (one slash, plain segments) is printed
    # into a pasteable command.
    case "$repo" in
        */*/* | */ | /* | "" | *[!A-Za-z0-9._/-]*) repo="" ;;
        */*) ;;
        *) repo="" ;;
    esac
    echo "  NOTE: queue/auto-merge state is VOLATILE — an ejection or a failed protection check disarms it silently; follow orch merge-pr.md § 5 for PR #$pr_num" >&2
    local reducer="GH_REPO=$repo .agents/skills/review-gate/scripts/pr-watch.sh (disarmed lines)"
    [ -n "$repo" ] || reducer=".agents/skills/review-gate/scripts/pr-watch.sh with GH_REPO set to the repository (not resolvable locally here)"
    echo "  Block on .agents/skills/orch/scripts/queue-wait $pr_num --json once, with a poll interval and budget sized as orch merge-pr.md § 5 step 1 does; route its verdict by that same step, and never re-arm an unrecognized verdict. The fleet reducer is $reducer; repair what the cause names, then re-arm only through the merge route of orch merge-pr.md § 5 step 1, which picks the direct attempt or an explicit queue arm after readiness and approval checks" >&2
}

post_merge_snapshot() {
    local pr_num="$1"
    local auth_token="$2"
    local snapshot=""

    # A partial GraphQL answer — an `errors` array beside `data`, or a null
    # `isInMergeQueue` where that one field failed — is not an outcome. Reading
    # it would record a merge whose result was never seen as a clean refusal,
    # so a payload that fails this validation falls through to the pr-view
    # fallback exactly as a failed call does.
    if snapshot=$(with_token "$auth_token" gh api graphql \
        -f query='query($owner: String!, $repo: String!, $number: Int!) { repository(owner: $owner, name: $repo) { pullRequest(number: $number) { state headRefOid headRefName isCrossRepository mergeCommit { oid } autoMergeRequest { enabledAt } isInMergeQueue mergeQueueEntry { state } } } }' \
        -F owner='{owner}' -F repo='{repo}' -F number="$pr_num" 2>/dev/null) && \
        jq -e '
            (((.errors // []) | length) == 0)
            and (.data.repository.pullRequest | type == "object")
            and (.data.repository.pullRequest
                 | ((.state | type) == "string")
                   and ((.isInMergeQueue | type) == "boolean")
                   and has("autoMergeRequest") and has("mergeQueueEntry"))
        ' >/dev/null 2>&1 <<<"$snapshot"; then
        jq -c '
            .data.repository.pullRequest
            | {
                state: .state,
                head: (.headRefOid // ""),
                head_branch: (.headRefName // ""),
                cross_repository: (if (.isCrossRepository | type) == "boolean" then .isCrossRepository else null end),
                merge_commit: (.mergeCommit.oid // ""),
                auto_merge: (.autoMergeRequest != null),
                in_merge_queue: .isInMergeQueue,
                merge_queue_entry: (.mergeQueueEntry != null),
                queue_state: (.mergeQueueEntry.state // ""),
                source: "graphql"
            }
        ' <<<"$snapshot"
        return 0
    fi

    if snapshot=$(with_token "$auth_token" gh pr view "$pr_num" \
        --json state,headRefOid,headRefName,isCrossRepository,mergeCommit,autoMergeRequest 2>/dev/null) && \
        jq -e 'type == "object"' >/dev/null 2>&1 <<<"$snapshot"; then
        jq -c '
            {
                state: (.state // "UNKNOWN"),
                head: (.headRefOid // ""),
                head_branch: (.headRefName // ""),
                cross_repository: (if (.isCrossRepository | type) == "boolean" then .isCrossRepository else null end),
                merge_commit: (.mergeCommit.oid // ""),
                auto_merge: (.autoMergeRequest != null),
                in_merge_queue: false,
                merge_queue_entry: false,
                queue_state: "",
                source: "pr-view-fallback"
            }
        ' <<<"$snapshot"
        return 0
    fi

    jq -cn '{state:"UNKNOWN",head:"",head_branch:"",cross_repository:null,merge_commit:"",auto_merge:false,in_merge_queue:false,merge_queue_entry:false,queue_state:"",source:"unavailable"}'
}

# The values of a ruleset's current_user_can_bypass under which this token may
# merge a pull request past it. `never` and any value GitHub adds later keep
# the queue. Values: docs.github.com/en/rest/repos/rules
BYPASS_VALUES=" always pull_requests_only exempt "

# The immediate merge's route past the base branch's merge queue, read under
# the merge's own token and named on stderr: MERGE_ROUTE is admin, queue, or
# plain where no ruleset on the base holds a merge_queue rule. GitHub applies
# --admin to every rule the token may bypass, not to the queue alone, so the
# admin route needs the queue to be all it skips: each merge-queue ruleset
# holds that one rule and answers a bypass, every other ruleset on the base
# answers never, and the base has no classic branch protection. Any read that
# fails is the queue, never the admin route: the queue is the route GitHub
# takes on --auto without --admin, so a failure costs a queue wait, not a merge
# past a gate. A merge past the queue is direct, so GitHub holds it to the
# repository's methods and the pull_request rules, not to the queue's method:
# the route needs one of the accepted methods there, MERGE_ROUTE_METHOD. The
# queue-only class is read last, and only where everything else allows the
# admin route.
MERGE_ROUTE=""
MERGE_ROUTE_METHOD=""
route_queue() { # FIELDS WHY
    echo "merge-route: queue $1" >&2
    echo "  $2 The merge call passes --auto and no --admin." >&2
}
merge_route() { # PR TOKEN HEAD QUEUE ACCEPTED...
    local pr_num="$1" token="$2" head="$3" queue="$4" branch base rules queue_ids ids id bypass bypasses="" rulesets="" mixed enabled direct queue_count rc=0
    shift 4
    MERGE_ROUTE=queue
    MERGE_ROUTE_METHOD=""
    if ! branch=$(with_token "$token" gh pr view "$pr_num" --json baseRefName --jq '.baseRefName' 2>/dev/null) || [ -z "$branch" ] \
        || ! base=$(jq -nr --arg v "$branch" '$v | @uri') \
        || ! rules=$(with_token "$token" gh api "repos/{owner}/{repo}/rules/branches/$base" --paginate \
            --jq '.[] | "\(.ruleset_id) \(.type)"' 2>/dev/null) \
        || ! queue_ids=$(awk '$2 == "merge_queue" && !seen[$1]++ { print $1 }' <<<"$rules") \
        || ! mixed=$(awk '$2 == "merge_queue" { queue[$1] = 1 } { rule[NR] = $0 }
            END { for (i = 1; i <= NR; i++) { split(rule[i], f, " "); if ((f[1] in queue) && f[2] != "merge_queue") { print rule[i]; exit } } }' <<<"$rules") \
        || ! ids=$(awk '!seen[$1]++ { print $1 }' <<<"$rules"); then
        echo "pr-merge: merge-method-unreadable cause=rules" >&2
        return 1
    fi
    if [ -z "$queue_ids" ]; then
        MERGE_ROUTE=plain
        return 0
    fi
    if [ -n "$mixed" ]; then
        route_queue "cause=queue-ruleset-mixed ruleset=${mixed%% *} rule=${mixed#* }" "The merge-queue ruleset holds another rule, which --admin would skip too."
        return 0
    fi
    while IFS= read -r id; do
        if ! bypass=$(with_token "$token" gh api "repos/{owner}/{repo}/rulesets/$id" --jq '.current_user_can_bypass // "absent"' 2>/dev/null) \
            || [ -z "$bypass" ]; then
            route_queue "cause=ruleset-unreadable ruleset=$id" "The ruleset could not be read, so no bypass is proven."
            return 0
        fi
        if grep -qxF -- "$id" <<<"$queue_ids"; then
            case "$BYPASS_VALUES" in
            *" $bypass "*) ;;
            *)
                route_queue "cause=no-bypass ruleset=$id bypass=$bypass" "This token may not bypass the merge-queue ruleset."
                return 0
                ;;
            esac
            rulesets="${rulesets:+$rulesets,}$id"
            bypasses="${bypasses:+$bypasses,}$bypass"
        elif [ "$bypass" != never ]; then
            route_queue "cause=other-bypass ruleset=$id bypass=$bypass" "This token may bypass another ruleset on the base, which --admin would skip too."
            return 0
        fi
    done <<<"$ids"
    # The branch object's protection.enabled is classic protection alone:
    # rulesets set its protected field, never this one.
    if ! enabled=$(with_token "$token" gh api "repos/{owner}/{repo}/branches/$base" --jq '.protection.enabled' 2>/dev/null); then
        enabled=unreadable
    fi
    case "$enabled" in
    false) ;;
    true)
        route_queue "cause=classic-protection" "The base branch has classic branch protection, which --admin would skip too."
        return 0
        ;;
    *)
        route_queue "cause=protection-unreadable" "The base branch's classic protection could not be read, so no bypass is proven."
        return 0
        ;;
    esac
    direct=$(with_token "$token" kendex_github_merge_method --direct '{owner}/{repo}' "$branch" "$@") || rc=$?
    case "$rc" in
    0) ;;
    2)
        local IFS=,
        route_queue "cause=direct-method allowed=$direct accepted=$*" "A merge past the queue takes the repository's methods and the base's pull_request rules, which allow none of the accepted methods."
        return 0
        ;;
    *)
        route_queue "cause=direct-method-unreadable read=$direct" "The methods a merge past the queue may take could not be read."
        return 0
        ;;
    esac
    # A direct merge invalidates every queued merge group and repeats its CI.
    if ! queue_count=$(with_token "$token" gh api graphql \
        -f query='query($owner: String!, $repo: String!, $branch: String!) { repository(owner: $owner, name: $repo) { mergeQueue(branch: $branch) { entries { totalCount } } } }' \
        -F owner='{owner}' -F repo='{repo}' -f branch="$branch" \
        --jq '.data.repository.mergeQueue.entries.totalCount' 2>/dev/null); then
        queue_count=unreadable
    fi
    if ! [[ "$queue_count" =~ ^[0-9]+$ ]]; then
        route_queue "cause=queue-unreadable" "The base queue's entry count could not be read as a whole number."
        return 0
    fi
    if [[ "$queue_count" =~ [1-9] ]]; then
        route_queue "cause=queue-occupied" "The base queue holds entries, so a direct merge would repeat their CI."
        return 0
    fi
    read_queue_only "$pr_num" "$head"
    if [ "$QUEUE_ONLY" = true ]; then
        route_queue "cause=queue-only" "A queue-only change runs in a merge group before it lands."
        echo "  $QUEUE_ONLY_DETAIL" >&2
        [ -z "$QUEUE_ONLY_NOTES" ] || printf '%s\n' "$QUEUE_ONLY_NOTES" >&2
        return 0
    fi
    if [ "$queue" = true ]; then
        route_queue "cause=explicit-queue ruleset=$rulesets bypass=$bypasses" "The caller explicitly requested the queue for a PR eligible for a direct merge."
        echo "  $QUEUE_ONLY_DETAIL" >&2
        return 0
    fi
    MERGE_ROUTE=admin
    MERGE_ROUTE_METHOD="$direct"
    echo "merge-route: admin cause=queue-bypass-safe ruleset=$rulesets bypass=$bypasses" >&2
    echo "  $QUEUE_ONLY_DETAIL" >&2
}

# The merge-route class of one pull request at HEAD, the head the merge is
# pinned to, from harness-ci's change-class beside this scripts tree, else
# change-class on PATH: asked about the pull request's own range, it prints `queue-only: queue_only=true|false cause=...`
# on stderr. This command asks; it never matches a path itself. Sets
# QUEUE_ONLY to true or false, QUEUE_ONLY_DETAIL to the classifier's line or
# the reason it was not read, and QUEUE_ONLY_NOTES to the diagnostics of a
# read that failed: gh's, git's or the classifier's own. Anything short of a
# readable line is queue-only: the queue is the route that runs the change in
# a merge group before it lands.
QUEUE_ONLY=""
QUEUE_ONLY_DETAIL=""
QUEUE_ONLY_NOTES=""
read_queue_only() { # PR HEAD
    local pr_num="$1" pinned="$2" classifier root notes range base_sha head_sha line status=0
    QUEUE_ONLY=true
    QUEUE_ONLY_NOTES=""
    classifier=$(sibling_script harness-ci change-class) || classifier=""
    if [ -z "$classifier" ]; then
        QUEUE_ONLY_DETAIL="cause=classifier-absent"
        return 0
    fi
    if ! root=$(checkout_root); then
        QUEUE_ONLY_DETAIL="cause=checkout-unreadable"
        return 0
    fi
    if ! notes=$(mktemp "${TMPDIR:-/tmp}/pr-merge-class.XXXXXX"); then
        QUEUE_ONLY_DETAIL="cause=scratch-unavailable"
        return 0
    fi
    if ! range=$(pr_range "$pr_num" 2>"$notes"); then
        QUEUE_ONLY_DETAIL="cause=range-unreadable"
    else
        base_sha="${range% *}"
        head_sha="${range#* }"
        # A push between the head read and this range read would classify a
        # head the merge is not pinned to.
        if [ "$head_sha" != "$pinned" ]; then
            QUEUE_ONLY_DETAIL="cause=head-moved classified=$head_sha pinned=$pinned"
        elif ! pr_range_materialize "$root" "$base_sha" "$head_sha" 2>"$notes"; then
            QUEUE_ONLY_DETAIL="cause=range-absent base=$base_sha head=$head_sha"
        else
            run_checkout_child "$notes" "$root" "$classifier" --event pull_request \
                --base "$base_sha" --head "$head_sha" --repo . >/dev/null || status=$?
            line=$(sed -n 's/^queue-only: //p' "$notes" | tail -1) || line=""
            case "$status:$line" in
            "0:queue_only=true "*) QUEUE_ONLY_DETAIL="$line" ;;
            "0:queue_only=false "*) QUEUE_ONLY=false; QUEUE_ONLY_DETAIL="$line" ;;
            0:*) QUEUE_ONLY_DETAIL="cause=classifier-unreadable" ;;
            *) QUEUE_ONLY_DETAIL="cause=classifier-exit-$status" ;;
            esac
        fi
    fi
    case "$QUEUE_ONLY_DETAIL" in
    queue_only=*) ;;
    *) QUEUE_ONLY_NOTES=$(cat -- "$notes") || QUEUE_ONLY_NOTES="" ;;
    esac
    rm -f -- "${notes:?}"
}

main() {
    local pr_num="" delete_branch=false
    local -a accepted=()
    local check_only=false dry_run=false auto=false supplied_head="" queue=false

    while [ $# -gt 0 ]; do
        case "$1" in
        --squash | --merge | --rebase)
            accepted+=("${1#--}")
            shift
            ;;
        --delete-branch)
            delete_branch=true
            shift
            ;;
        --keep-branch)
            delete_branch=false
            shift
            ;;
        --check)
            check_only=true
            shift
            ;;
        --auto)
            auto=true
            shift
            ;;
        --expected-head) supplied_head="${2:-}"; shift 2 ;;
        --queue)
            queue=true
            shift
            ;;
        --dry-run)
            dry_run=true
            shift
            ;;
        --help | -h)
            show_help
            exit 0
            ;;
        [0-9]*)
            pr_num="$1"
            shift
            ;;
        *)
            echo "Error: Unknown option: $1" >&2
            exit 1
            ;;
        esac
    done

    if [ -z "$pr_num" ]; then
        github_error 'PR number required'
        exit 1
    fi
    [ "${#accepted[@]}" -gt 0 ] || accepted=(squash merge rebase)
    if [ -n "$supplied_head" ] && ! [[ "$supplied_head" =~ ^[0-9a-fA-F]{40}$ ]]; then
        echo "Error: --expected-head must be a 40-character commit SHA" >&2; exit 1
    fi
    if [ "$queue" = true ] && [ "$auto" != true ]; then
        echo "Error: --queue gates the --auto arm and needs --auto" >&2; exit 1
    fi

    if [ "$check_only" = true ]; then
        local check_json
        check_json=$(run_checks "$pr_num")
        printf '%s\n' "$check_json"
        check_verdict_lines <<<"$check_json" >&2
        exit 0
    fi

    if load_pr_state_json "$pr_num"; then
        exit_terminal_state \
            "$(jq -r '.state // ""' <<<"$PR_STATE_JSON")" \
            "$pr_num" \
            "$(jq -r '.mergedAt // ""' <<<"$PR_STATE_JSON")"
    fi

    local selection
    selection=$(load_bot_token)
    local token="${selection#*=}" token_source="${selection%%=*}"

    local check_result can_merge checked_state checked_merged_at
    check_result=$(run_checks "$pr_num")

    # The checks re-read a state the up-front lookup could not resolve, so
    # a PR that is terminal by now must be reported here too. Otherwise
    # `--auto`, which defers every blocker, arms a merge on a PR
    # that has already left OPEN.
    checked_state=$(echo "$check_result" | jq -r '.state // ""')
    checked_merged_at=$(echo "$check_result" | jq -r '.merged_at // ""')
    exit_terminal_state "$checked_state" "$pr_num" "$checked_merged_at"

    # run_checks builds its result with jq, so an unreadable one is a broken
    # invariant, never a verdict: it refuses rather than read as either answer.
    if ! can_merge=$(jq -r 'if (.can_merge | type) == "boolean" and (.issues | type) == "array" then .can_merge else error("unreadable") end' <<<"$check_result" 2>/dev/null); then
        echo "pr-merge: readiness-unreadable pr=$pr_num" >&2
        echo "  The readiness result is not JSON with can_merge and issues; nothing was merged or armed." >&2
        exit 1
    fi

    # `--auto` defers every blocker: merge_gate_gap below arms only where
    # GitHub holds the armed PR until its required checks, an approval of its
    # current head and thread resolution pass.
    if [ "$can_merge" != "true" ] && [ "$auto" != true ]; then
        print_blocked "$check_result" "$pr_num"
        exit 1
    fi
    # No GitHub rule reads what a review reply says, so GitHub would merge an
    # armed PR past one: --auto defers every blocker but the reply check's,
    # and refuses a state it could not read as OPEN, whose replies went unread.
    if [ "$auto" = true ] && auto_refused "$check_result"; then
        print_blocked "$check_result" "$pr_num"
        exit 1
    fi

    # Resolve and guard the exact head before mutating merge state. This prevents
    # a review/CI race from queuing or merging a newer, unverified commit.
    # It prints nothing unless it refuses, so it keeps the arm's first line.
    local expected_head="" current_head
    if [ "$dry_run" != true ]; then
        if ! current_head=$(with_token "$token" gh pr view "$pr_num" --json headRefOid --jq '.headRefOid' 2>/dev/null) || [ -z "$current_head" ]; then
            echo "BLOCKED PR #$pr_num — could not resolve exact head SHA for guarded merge" >&2
            exit 1
        fi
        expected_head="${supplied_head:-$current_head}"
        if [ "$current_head" != "$expected_head" ]; then
            echo "BLOCKED PR #$pr_num — prepared head changed before merge attempt (expected=$expected_head, actual=$current_head)" >&2; exit 1
        fi
    fi

    # GitHub enqueues an armed PR the moment its checks pass. Read the route
    # for every arm so a brief cannot silently replace a direct merge with
    # a queue entry. Callers consume the refusal's first line.
    local route=plain
    if [ "$dry_run" != true ]; then
        merge_route "$pr_num" "$token" "$expected_head" "$queue" "${accepted[@]}"
        route="$MERGE_ROUTE"
    fi
    if [ "$auto" = true ] && [ "$route" = admin ]; then
        echo "  Nothing armed: the immediate merge takes this PR past the queue once its gates pass, and an arm now would queue it first." >&2
        exit 1
    fi

    # The route refusal takes priority; a queue arm still needs every review gate.
    local gate_gap slug
    [ "$auto" = false ] || [ "$dry_run" = true ] || gate_gap=$(merge_gate_gap "$pr_num" "$token")
    if [ -n "${gate_gap:-}" ]; then
        slug=$(kendex_github_resolve_gh_repo "${PROJECT_ROOT:-$PWD}" 2>/dev/null) || slug=unresolved
        echo "arm: no-merge-gate=$gate_gap repo=$slug" >&2
        case "$gate_gap" in
            allow_auto_merge) echo "  Nothing mutated. Enable auto-merge on the repository." >&2 ;;
            required_approval) echo "  Nothing mutated. No ruleset on the base branch requires an approval, so GitHub would merge the armed PR before review; require at least 1 approval, thread resolution and stale-approval dismissal in its pull_request rule." >&2 ;;
            required_thread_resolution) echo "  Nothing mutated. No ruleset on the base branch requires thread resolution, so GitHub would merge the armed PR on its first approval past open review threads; require review threads resolved in its pull_request rule." >&2 ;;
            dismiss_stale_reviews) echo "  Nothing mutated. No ruleset on the base branch dismisses stale approvals on push, so GitHub would merge the armed PR on an approval of an earlier head, with no review of the pushed one; dismiss stale approvals on push in its pull_request rule." >&2 ;;
            *) echo "  Nothing mutated. The base branch's rules could not be read, so no merge gate is proven; retry once they read." >&2 ;;
        esac
        exit 1
    fi

    local method
    if [ "$route" = admin ]; then
        method="$MERGE_ROUTE_METHOD"
    else
        method=$(merge_method "$pr_num" "$token" "${accepted[@]}") || exit 1
    fi

    local warnings
    warnings=$(echo "$check_result" | jq -r '.warnings | length')
    if [ "$warnings" -gt 0 ]; then
        echo "Warnings:" >&2
        echo "$check_result" | jq -r '.warnings[]' | sed 's/^/  ⚠ /' >&2
    fi

    if [ "$dry_run" = true ]; then
        local token_status="not configured"
        [ -n "$token" ] && token_status="configured"
        local mode="immediate"
        [ "$auto" = true ] && mode="auto-merge fallback"
        echo "Would merge PR #$pr_num (--$method, mode=$mode, delete_branch=$delete_branch, token=$token_status)"
        exit 0
    fi


    # GitHub enrolls a PR in a merge queue only through --auto: a merge call
    # without it or --admin on a queue base is refused, gh exiting 0 on it.
    local -a cmd=(pr merge "$pr_num" "--$method" --match-head-commit "$expected_head")
    [ "$auto" != true ] && [ "$route" != queue ] || cmd+=(--auto)
    [ "$route" != admin ] || [ "$auto" = true ] || cmd+=(--admin)

    local merge_output merge_exit=0
    if [ -n "$token" ]; then
        local identity
        identity=$(kendex_github_token_identity "$token")
        echo "Using $token_source as $identity" >&2
        merge_output=$(with_token "$token" gh "${cmd[@]}" 2>&1) || merge_exit=$?
    else
        echo "Warning: GH_BOT_TOKEN not configured, using current user" >&2
        merge_output=$(with_token "" gh "${cmd[@]}" 2>&1) || merge_exit=$?
    fi

    # The post-call snapshot decides queue enrollment. gh can exit either way,
    # and its already-queued stderr is version-dependent.
    local post_snapshot post_state post_auto post_head post_in_queue post_queue_entry post_queue_state
    post_snapshot=$(post_merge_snapshot "$pr_num" "$token")
    post_state=$(jq -r '.state' <<<"$post_snapshot")
    post_auto=$(jq -r '.auto_merge' <<<"$post_snapshot")
    post_head=$(jq -r '.head' <<<"$post_snapshot")
    post_in_queue=$(jq -r '.in_merge_queue' <<<"$post_snapshot")
    post_queue_entry=$(jq -r '.merge_queue_entry' <<<"$post_snapshot")
    post_queue_state=$(jq -r '.queue_state' <<<"$post_snapshot")

    # The mutation itself was match-head guarded. Also reject a post-call
    # snapshot that belongs to a different head instead of crediting its queue
    # or auto-merge state to the commit we attempted.
    if [ -n "$post_head" ] && [ "$post_head" != "$expected_head" ]; then
        echo "BLOCKED PR #$pr_num — head changed during merge attempt (expected=$expected_head, actual=$post_head)" >&2
        exit 1
    fi

    # A NONZERO `gh pr merge` exit is only benign when the authoritative
    # snapshot proves a real success state: an already-enrolled merge queue
    # entry, classic auto-merge already enabled, or an already merged PR.
    # Anything else — conflicts, auth failure, CI, no enrollment — leaves no
    # such proof and stays BLOCKED with the raw gh output. When the snapshot
    # does prove success, fall through to the shared classification below so
    # the outcome (MERGED / QUEUED / AUTO-MERGE) is reported once. An
    # exact-head MERGED snapshot remains authoritative even if the CLI returned
    # nonzero after the server completed the merge.
    if [ "$merge_exit" -ne 0 ] \
        && [ "$post_state" != "MERGED" ] \
        && [ "$post_in_queue" != "true" ] \
        && [ "$post_queue_entry" != "true" ] \
        && [ "$post_auto" != "true" ]; then
        echo "BLOCKED PR #$pr_num — gh pr merge failed" >&2
        printf '%s\n' "$merge_output" | sed 's/^/  /' >&2
        exit 1
    fi

    if [ "$post_state" = "MERGED" ]; then
        echo "MERGED PR #$pr_num" >&2
        # Delete remote branch via API (avoids gh's local git checkout, which
        # fails inside worktrees), and only where GitHub does not delete it
        # itself. The DELETE names this repository, so a fork's head, which
        # lives in the fork, is never deleted: the same name here is another
        # branch. Best-effort: the branch may already be gone.
        if [ "$delete_branch" = true ]; then
            local branch cross deletes
            branch=$(jq -r '.head_branch' <<<"$post_snapshot")
            if ! cross=$(jq -r '.cross_repository' <<<"$post_snapshot") || [ "$cross" != false ]; then
                case "$cross" in
                    true) echo "pr-merge: branch-kept branch=$branch cause=cross-repository" >&2
                          echo "  The head branch lives in a fork, not in this repository, so it was not deleted." >&2 ;;
                    *) echo "pr-merge: branch-kept branch=$branch cause=cross-repository-unreadable" >&2
                       echo "  GitHub did not say which repository holds the head branch, so it was not deleted." >&2 ;;
                esac
            elif ! deletes=$(with_token "$token" kendex_github_deletes_merged_branch '{owner}/{repo}'); then
                echo "pr-merge: branch-kept branch=$branch cause=setting-unreadable" >&2
                echo "  The repository's delete_branch_on_merge could not be read, so the head branch was not deleted." >&2
            elif [ "$deletes" = false ] && [ -n "$branch" ]; then
                with_token "$token" gh api -X DELETE "repos/{owner}/{repo}/git/refs/heads/$branch" 2>/dev/null || true
            fi
        fi
        exit 0
    fi

    if [ "$post_in_queue" = "true" ] || [ "$post_queue_entry" = "true" ]; then
        echo "QUEUED IN MERGE QUEUE PR #$pr_num — queueState=${post_queue_state:-active}" >&2
        volatile_note "$pr_num"
        exit 75
    fi

    if [ "$post_auto" = "true" ]; then
        echo "AUTO-MERGE ENABLED PR #$pr_num — will fire when CI + branch protection clear" >&2
        volatile_note "$pr_num"
        exit 75
    fi

    # gh exited 0 but PR isn't merged and isn't queued. Treat as BLOCKED so
    # callers don't assume success based on exit code alone.
    echo "BLOCKED PR #$pr_num — gh reported success but state=$post_state, autoMerge=$post_auto, mergeQueue=false" >&2
    printf '%s\n' "$merge_output" | sed 's/^/  /' >&2
    exit 1
}

main "$@"
