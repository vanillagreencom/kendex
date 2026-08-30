#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/github-api.sh"
# Issue prefixes that resolve on their own once GitHub finishes computing or
# CI completes. Callers should `await-mergeable` and retry rather than fix.
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
  --squash         Squash and merge (default)
  --merge          Create merge commit
  --rebase         Rebase and merge
  --delete-branch  Delete branch after merge (default: true)
  --keep-branch    Keep branch after merge
  --check          Run checks only, don't merge. JSON on stdout; a one-word
                   verdict (mergeable|blocked|merged|closed) plus the run
                   scope ("head-run: <ids>" — the runs the CI classification
                   was scoped to) on stderr. On a refusal,
                   ci-classify-refusal names the cause.
  --force          Skip checks and merge (requires explicit user decision;
                   cannot be combined with --auto)
  --auto           If immediate merge is blocked, enable GitHub auto-merge
                   (will fire when CI + branch protection clear). Exits 75.
                   Never bypasses actionable unresolved review threads.
  --expected-head SHA
                   Bind GitHub's match-head merge guard to prepared SHA.
  --dry-run        Show what would happen without merging

Modes:
  (default)        Run checks, block if critical issues, merge if pass
  --check          Run checks, output JSON for workflow to parse
  --force          Deliberately skip all checks, including review threads
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
  1    CLOSED (not merged) PR #N
       The PR is closed unmerged. Nothing was attempted.

--check exit:
  --check exits 0 after any valid readiness JSON, including can_merge=false for
  blocked or CLOSED. Argument or dispatch failures before JSON remain nonzero.

Exit 75 is volatile:
  A queue ejection can disarm merge state. Launch the prepared .agents/skills/orch/scripts/merge-queue-watch before returning; it binds repository, PR, expected head, and watch generation.
  Its one-shot worker writes a durable verdict and claims one recovery action. Route verdicts through README.md "Exit 75 recovery"; the review-gate reducer still reports fleet attention.
  Re-arm only through github.sh pr-merge <N> --auto after that route.
  await-mergeable is not the lifecycle watcher; it stops when GitHub computes state.

Terminal and mutation rules:
  After github.sh router setup, MERGED or CLOSED short-circuits pr-merge safety
  checks, bot-token load, and merge-state mutation; UNKNOWN continues. --check reports state.

  Every gh pr merge invocation is exact-head guarded by --match-head-commit; a changed head is BLOCKED.
  Queue membership comes from GraphQL isInMergeQueue and mergeQueueEntry. An
  OPEN PR with an active queue entry exits 75 even when autoMergeRequest is
  absent. An OPEN PR with no queue or auto-merge proof fails closed. The
  --delete-branch cleanup after MERGED is best-effort, not merge-state mutation.

Review-thread gate:
  Unresolved, non-outdated review threads make can_merge false and block both
  immediate merge and --auto. A failed or malformed thread lookup also blocks.
  This is narrower than required_conversation_resolution, which requires every
  conversation resolved and does not exclude outdated threads.

  The gate is policy, not mechanism. It applies only through pr-merge. A raw
  gh pr merge call or the GitHub UI Merge button bypasses it.

Force rules:
  --force is the only deliberate override. It skips every check, including the
  thread gate. It is immediate-only and cannot be combined with --auto. A
  failed force mutation remains BLOCKED unless the exact-head post-state is
  MERGED; a pre-existing queue entry or auto-merge request is not success.

--check JSON:
  stdout is one object with these fields:
    can_merge   boolean readiness result
    issues      blocking issue strings
    warnings    non-blocking issue strings
    mergeable   MERGEABLE, CONFLICTING, or UNKNOWN
    review      GitHub review decision
    transient   true only when every blocker can clear by waiting
    state       OPEN, MERGED, CLOSED, or UNKNOWN
    merged_at   merge timestamp, or an empty string
    head_runs   run IDs used for CI classification
    checks      raw check rollup read by the classification

  stderr carries mergeable, blocked, merged, or closed, followed by
  head-run: <ids> when CI runs were classified. can_merge=false with an empty
  issues array means the PR is terminal; inspect state instead of treating it
  as a blocker to repair.

  transient=true requires every issue prefix to be unknown:, ci_pending:,
  ci_unconfigured:, or ci_fetch_failed:. A ci_failed: issue is permanent, as
  are conflicts and changes_requested. Running checks use ci_pending: while
  failed or cancelled checks use ci_failed:.

  head_runs contains the authoritative workflow run plus runs referenced by
  custom commit statuses. checks is the same snapshot consumed by
  ci-classify-refusal <N>, so cause:, fail:, and superseded: lines cannot race
  a second fetch.

Examples:
  github.sh pr-merge 42 --check          # Check only, JSON output
  github.sh pr-merge 42                  # Check + merge if pass
  github.sh pr-merge 42 --auto           # Merge now or queue auto-merge
  github.sh pr-merge 42 --force          # Skip checks, merge (DANGEROUS)
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

run_checks() {
    local pr_num="$1"
    local can_merge=true
    local issues=()
    local warnings=()
    local head_runs_json='[]' checks_json='[]'

    local pr_state pr_merged_at
    if ! load_pr_state_json "$pr_num"; then
        jq -n --arg issue "$PR_STATE_ERROR" '{can_merge: false, issues: [$issue], warnings: [], mergeable: "UNKNOWN", review: "", transient: false, state: "UNKNOWN", merged_at: "", head_runs: [], checks: []}'
        return 0 # Return 0 so JSON is output, caller checks can_merge
    fi
    pr_state=$(jq -r '.state // "UNKNOWN"' <<<"$PR_STATE_JSON")
    pr_merged_at=$(jq -r '.mergedAt // ""' <<<"$PR_STATE_JSON")

    # A terminal PR is unmergeable for a reason no caller can act on, and its
    # check data is meaningless: `mergeable` is permanently UNKNOWN, post-merge
    # CI runs and bot comments are not blockers. Report the state, no issues.
    if [ "$pr_state" = "MERGED" ] || [ "$pr_state" = "CLOSED" ]; then
        jq -n --arg state "$pr_state" --arg merged_at "$pr_merged_at" '{can_merge: false, issues: [], warnings: [], mergeable: "UNKNOWN", review: "", transient: false, state: $state, merged_at: $merged_at, head_runs: [], checks: []}'
        return 0
    fi

    local mergeable
    mergeable=$(gh pr view "$pr_num" --json mergeable --jq '.mergeable' 2>/dev/null || echo "UNKNOWN")
    if [ "$mergeable" = "MERGEABLE" ]; then
        : # ok
    elif [ "$mergeable" = "CONFLICTING" ]; then
        can_merge=false
        issues+=("conflicts: PR has merge conflicts. Resolve by rebasing onto your default branch and force-pushing")
    else
        can_merge=false
        issues+=("unknown: GitHub still computing mergeable status, await-mergeable then retry")
    fi

    # 2. Check CI status. The fetch tolerance (gh exit 8 with usable JSON)
    # lives with the shared fetch_checks_rollup.
    local ci_json
    if ! ci_json=$(fetch_checks_rollup "$pr_num"); then
        can_merge=false
        issues+=("ci_fetch_failed: Failed to fetch CI checks from GitHub")
    elif [ "$(echo "$ci_json" | jq 'length')" -eq 0 ]; then
        warnings+=("ci_unconfigured: No status checks configured")
    else
        # Drop checks belonging to superseded workflow runs before classifying,
        # so a prior canceled run can't be reported as a current merge blocker.
        # Mirrors orch ci-wait's pre-classification scoping; the shared
        # classify_checks_rollup carries the scoping and name-sanitization
        # contract.
        local rollup pending failed
        rollup=$(echo "$ci_json" | classify_checks_rollup)
        checks_json=$(jq -c '.checks' <<<"$rollup")
        head_runs_json=$(jq -c '.head_runs' <<<"$rollup")
        pending=$(jq -r '.pending' <<<"$rollup")
        failed=$(jq -r '.failed' <<<"$rollup")
        if [ -n "$pending" ]; then
            can_merge=false
            issues+=("ci_pending: $pending")
        fi
        if [ -n "$failed" ]; then
            can_merge=false
            issues+=("ci_failed: $failed")
        fi
    fi

    # 3. Check actionable review threads. GitHub does not protect merges on
    # unresolved conversations by default, so this is a local hard gate rather
    # than a warning. Outdated threads no longer refer to the current diff and
    # are not actionable. A failed or malformed lookup also blocks: treating an
    # unknown review state as clean would recreate the unsafe merge path.
    local threads_json unresolved
    # Fetch the complete unfiltered list. Filtering unresolved threads inside
    # pr-threads would discard nodes whose isResolved value is missing, null,
    # or malformed before this trust-boundary validation can reject them.
    if ! threads_json=$("$SCRIPT_DIR/pr-threads.sh" "$pr_num" 2>/dev/null); then
        can_merge=false
        issues+=("review_threads_fetch_failed: Failed to fetch actionable review threads from GitHub")
    elif ! jq -e '
        (.threads | type == "array") and
        all(.threads[];
            (.is_resolved | type == "boolean") and
            (.is_outdated | type == "boolean"))
    ' >/dev/null 2>&1 <<<"$threads_json"; then
        can_merge=false
        issues+=("review_threads_fetch_failed: GitHub returned malformed review thread data")
    else
        unresolved=$(jq '[.threads[] | select(.is_resolved == false and .is_outdated == false)] | length' <<<"$threads_json")
        if [ "$unresolved" -gt 0 ]; then
            can_merge=false
            issues+=("unresolved_threads: $unresolved actionable thread(s) need attention")
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

    local issues_json warnings_json
    issues_json=$(printf '%s\n' "${issues[@]:-}" | jq -R -s -c 'split("\n") | map(select(. != ""))')
    warnings_json=$(printf '%s\n' "${warnings[@]:-}" | jq -R -s -c 'split("\n") | map(select(. != ""))')

    # Classify whether the blocking issues are entirely transient. A transient
    # block can be retried after `await-mergeable`; a permanent block needs
    # human action (fix conflicts, push CI fix, dismiss review).
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
        '{can_merge: $can_merge, issues: $issues, warnings: $warnings, mergeable: $mergeable, review: $review, transient: $transient, state: $state, merged_at: $merged_at, head_runs: $head_runs, checks: $checks}'
}

print_blocked() {
    local check_result="$1"
    local pr_num="$2"
    local transient
    transient=$(echo "$check_result" | jq -r '.transient')

    echo "BLOCKED PR #$pr_num — no merge attempted, none queued" >&2
    if [ "$transient" = "true" ]; then
        echo "  (transient — GitHub still computing or CI pending)" >&2
    else
        echo "  (permanent — needs fix or review action)" >&2
    fi
    echo "$check_result" | jq -r '.issues[]' | sed 's/^/  ✗ /' >&2
    echo "$check_result" | jq -r '.warnings[]' | sed 's/^/  ⚠ /' >&2
    echo "" >&2
    if [ "$transient" = "true" ]; then
        echo "Hint: github.sh await-mergeable $pr_num && retry" >&2
    fi
    if echo "$check_result" | jq -e '[.issues[] | select(test("^(unresolved_threads|review_threads_fetch_failed):"))] | length > 0' >/dev/null 2>&1; then
        echo "Resolve the review-thread gate and retry. Use --force only after an explicit decision to override it." >&2
    else
        echo "Use --auto to queue for auto-merge, or --force after an explicit decision to override safety checks." >&2
    fi
}

# Run gh with the same effective identity used for the merge mutation. Keep the
# token scoped to the subprocess so the caller's environment is never changed.
gh_with_token() {
    local auth_token="${1:-}"
    shift

    if [ -n "$auth_token" ]; then
        GH_TOKEN="$auth_token" gh "$@"
    else
        gh "$@"
    fi
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
    echo "  Launch the prepared .agents/skills/orch/scripts/merge-queue-watch once; route its claimed action by orch merge-pr.md § 5 step 1, and never re-arm an unrecognized verdict. The fleet reducer is $reducer; repair what the cause names before re-arming with .agents/skills/github/scripts/github.sh pr-merge $pr_num --auto" >&2
}

post_merge_snapshot() {
    local pr_num="$1"
    local auth_token="$2"
    local snapshot=""

    if snapshot=$(gh_with_token "$auth_token" api graphql \
        -f query='query($owner: String!, $repo: String!, $number: Int!) { repository(owner: $owner, name: $repo) { pullRequest(number: $number) { state headRefOid headRefName mergeCommit { oid } autoMergeRequest { enabledAt } isInMergeQueue mergeQueueEntry { state } } } }' \
        -F owner='{owner}' -F repo='{repo}' -F number="$pr_num" 2>/dev/null) && \
        jq -e '.data.repository.pullRequest != null' >/dev/null 2>&1 <<<"$snapshot"; then
        jq -c '
            .data.repository.pullRequest
            | {
                state: (.state // "UNKNOWN"),
                head: (.headRefOid // ""),
                head_branch: (.headRefName // ""),
                merge_commit: (.mergeCommit.oid // ""),
                auto_merge: (.autoMergeRequest != null),
                in_merge_queue: (.isInMergeQueue == true),
                merge_queue_entry: (.mergeQueueEntry != null),
                queue_state: (.mergeQueueEntry.state // ""),
                source: "graphql"
            }
        ' <<<"$snapshot"
        return 0
    fi

    if snapshot=$(gh_with_token "$auth_token" pr view "$pr_num" \
        --json state,headRefOid,headRefName,mergeCommit,autoMergeRequest 2>/dev/null) && \
        jq -e 'type == "object"' >/dev/null 2>&1 <<<"$snapshot"; then
        jq -c '
            {
                state: (.state // "UNKNOWN"),
                head: (.headRefOid // ""),
                head_branch: (.headRefName // ""),
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

    jq -cn '{state:"UNKNOWN",head:"",head_branch:"",merge_commit:"",auto_merge:false,in_merge_queue:false,merge_queue_entry:false,queue_state:"",source:"unavailable"}'
}

main() {
    local pr_num="" method="--squash" delete_branch=true
    local check_only=false force=false dry_run=false auto=false supplied_head=""

    while [ $# -gt 0 ]; do
        case "$1" in
        --squash)
            method="--squash"
            shift
            ;;
        --merge)
            method="--merge"
            shift
            ;;
        --rebase)
            method="--rebase"
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
        --force)
            force=true
            shift
            ;;
        --auto)
            auto=true
            shift
            ;;
        --expected-head) supplied_head="${2:-}"; shift 2 ;;
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

    if [ "$force" = true ] && [ "$auto" = true ]; then
        echo "Error: --force and --auto cannot be combined; --force is immediate-only" >&2
        exit 1
    fi

    if [ -z "$pr_num" ]; then
        echo '{"error": "PR number required"}' >&2
        exit 1
    fi
    if [ -n "$supplied_head" ] && ! [[ "$supplied_head" =~ ^[0-9a-fA-F]{40}$ ]]; then
        echo "Error: --expected-head must be a 40-character commit SHA" >&2; exit 1
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

    local token
    token=$(load_bot_token)

    local check_result=""
    if [ "$force" = false ]; then
        local can_merge checked_state checked_merged_at
        check_result=$(run_checks "$pr_num")

        # The checks re-read a state the up-front lookup could not resolve, so
        # a PR that is terminal by now must be reported here too. Otherwise
        # `--auto`, which defers every non-thread blocker, arms a merge on a PR
        # that has already left OPEN.
        checked_state=$(echo "$check_result" | jq -r '.state // ""')
        checked_merged_at=$(echo "$check_result" | jq -r '.merged_at // ""')
        exit_terminal_state "$checked_state" "$pr_num" "$checked_merged_at"

        can_merge=$(echo "$check_result" | jq -r '.can_merge')

        if [ "$can_merge" != "true" ]; then
            # `--auto` may defer GitHub-enforced blockers, but it must never
            # bypass local review-thread safety. GitHub can otherwise accept
            # and immediately merge a PR whose conversations remain open.
            local has_review_thread_gate
            has_review_thread_gate=$(echo "$check_result" | jq '[.issues[] | select(test("^(unresolved_threads|review_threads_fetch_failed):"))] | length > 0')

            if [ "$auto" != true ] || [ "$has_review_thread_gate" = "true" ]; then
                print_blocked "$check_result" "$pr_num"
                exit 1
            fi
        fi

        local warnings
        warnings=$(echo "$check_result" | jq -r '.warnings | length')
        if [ "$warnings" -gt 0 ]; then
            echo "Warnings:" >&2
            echo "$check_result" | jq -r '.warnings[]' | sed 's/^/  ⚠ /' >&2
        fi
    else
        echo "⚠ --force: Skipping safety checks" >&2
    fi

    if [ "$dry_run" = true ]; then
        local token_status="not configured"
        [ -n "$token" ] && token_status="configured"
        local mode="immediate"
        [ "$auto" = true ] && mode="auto-merge fallback"
        echo "Would merge PR #$pr_num ($method, mode=$mode, delete_branch=$delete_branch, token=$token_status)"
        exit 0
    fi

    # Resolve and guard the exact head before mutating merge state. This prevents
    # a review/CI race from queuing or merging a newer, unverified commit.
    local expected_head current_head
    if ! current_head=$(gh_with_token "$token" pr view "$pr_num" --json headRefOid --jq '.headRefOid' 2>/dev/null) || [ -z "$current_head" ]; then
        echo "BLOCKED PR #$pr_num — could not resolve exact head SHA for guarded merge" >&2
        exit 1
    fi
    expected_head="${supplied_head:-$current_head}"
    if [ "$current_head" != "$expected_head" ]; then
        echo "BLOCKED PR #$pr_num — prepared head changed before merge attempt (expected=$expected_head, actual=$current_head)" >&2; exit 1
    fi

    local -a cmd=(pr merge "$pr_num" "$method" --match-head-commit "$expected_head")
    [ "$auto" = true ] && cmd+=(--auto)

    local merge_output merge_exit=0
    if [ -n "$token" ]; then
        merge_output=$(gh_with_token "$token" "${cmd[@]}" 2>&1) || merge_exit=$?
    else
        echo "Warning: GH_BOT_TOKEN not configured, using current user" >&2
        merge_output=$(gh_with_token "" "${cmd[@]}" 2>&1) || merge_exit=$?
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

    # A NONZERO `gh pr merge` exit is only benign outside `--force` when the
    # authoritative snapshot proves a real success state: an already-enrolled
    # merge queue entry, classic auto-merge already enabled, or an
    # already merged PR. Anything else — conflicts, auth failure, CI, no
    # enrollment — leaves no such proof and stays BLOCKED with the raw gh
    # output. When the snapshot does prove success, fall through to the shared
    # classification below so the outcome (MERGED / QUEUED / AUTO-MERGE) is
    # reported once.
    # `--force` promises an immediate mutation, so pre-existing pending state
    # must never convert its failed mutation into success. An
    # exact-head MERGED snapshot remains authoritative even if the CLI returned
    # nonzero after the server completed the merge.
    if [ "$merge_exit" -ne 0 ] \
        && [ "$post_state" != "MERGED" ] \
        && { [ "$force" = true ] \
            || { [ "$post_in_queue" != "true" ] \
                && [ "$post_queue_entry" != "true" ] \
                && [ "$post_auto" != "true" ]; }; }; then
        echo "BLOCKED PR #$pr_num — gh pr merge failed" >&2
        printf '%s\n' "$merge_output" | sed 's/^/  /' >&2
        exit 1
    fi

    if [ "$post_state" = "MERGED" ]; then
        echo "MERGED PR #$pr_num" >&2
        # Delete remote branch via API (avoids gh's local git checkout, which
        # fails inside worktrees). Best-effort — branch may already be gone.
        if [ "$delete_branch" = true ]; then
            local branch
            branch=$(jq -r '.head_branch' <<<"$post_snapshot")
            if [ -n "$branch" ]; then
                gh_with_token "$token" api -X DELETE "repos/{owner}/{repo}/git/refs/heads/$branch" 2>/dev/null || true
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
