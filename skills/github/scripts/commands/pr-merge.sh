#!/bin/bash
# Merge PR as bot account with safety checks
# Usage: pr-merge <PR_NUMBER> [--check] [--force] [--auto] [--dry-run]
#
# Outcomes (distinct exit codes + messages):
#   0   MERGED                 — merge completed immediately
#   75  QUEUED / AUTO-MERGE     — merge queue entry or classic auto-merge is active
#   1   BLOCKED                — checks failed; no merge attempted, none queued
#
# Actionable unresolved review threads are a local hard gate: neither an
# immediate merge nor `--auto` may mutate merge state while they remain. Only
# the deliberately dangerous `--force` override skips this gate.
#
# `--auto` is idempotent for merge-queue repositories: a re-invocation on a PR
# that is already enrolled reports QUEUED (75) from the authoritative post-call
# snapshot, not BLOCKED, even though `gh pr merge --auto` exits nonzero when the
# PR is already queued (vstack#616).
# `--force` is deliberately different: it promises an immediate attempt, so a
# nonzero merge mutation stays BLOCKED unless the exact head is now MERGED.
# Auto-merge or a queue entry already active before the call is not success
# proof for this mode (vstack#782).
#
# When BLOCKED, stderr distinguishes TRANSIENT issues (mergeable UNKNOWN,
# ci pending — caller should `await-mergeable` and retry) from PERMANENT
# issues (conflicts, ci_failed, changes_requested — caller must fix and re-push).
# Still-running checks are emitted as ci_pending, not ci_failed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared library for load_bot_token (also sets PROJECT_ROOT)
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/github-api.sh"
# shellcheck source=../lib/pr-branch.sh
source "$SCRIPT_DIR/../lib/pr-branch.sh"

# Issue prefixes that resolve on their own once GitHub finishes computing or
# CI completes. Callers should `await-mergeable` and retry rather than fix.
TRANSIENT_PREFIXES='unknown:|ci_pending:|ci_unconfigured:|ci_fetch_failed:'

# Scope a `gh pr checks` array to the current authoritative run per workflow so
# stale checks from a SUPERSEDED workflow run don't leak into the current
# PR/head status (vstack#492). A single canceled prior run left Lint/Integration/
# etc. as CANCELLED; with no newer instance of those jobs yet created, they were
# the only copies and were wrongly counted as current failures.
#
# Approach: parse each check's owning workflow RUN_ID from its `link`
# (`.../actions/runs/<RUN_ID>/job/<JOB_ID>`), group run-bearing checks by their
# `workflow`, and within each workflow keep ONLY the checks belonging to that
# workflow's LATEST run (max RUN_ID). This (a) drops an old run's checks when a
# newer run of the same workflow exists, and (b) — the reported case — drops the
# old canceled job even when the newer run hasn't recreated it yet, leaving it
# correctly absent (reported as not-yet-created/pending, not failed). Distinct
# workflows are never collapsed (e.g. a separate "License Key Guard" workflow is
# preserved). Checks with no parseable run in `link` (external/required contexts,
# default-setup `.../runs/<CHECK_RUN_ID>` links, or older gh output with no link)
# are always kept, deduped by name keeping the latest `startedAt`. An all-empty
# link/startedAt array (older gh) passes through unchanged.
#
# This must stay aligned with orch ci-wait's scope_current_run (byte-for-byte).
scope_current_run() {
  jq -c '
    def runid:
      (.link // "")
      | ((capture("/actions/runs/(?<r>[0-9]+)")? | .r) // null)
      | (if . == null then null else tonumber end);
    map(. + {"_runid": runid})
    | ([.[] | select(._runid == null)]) as $norun
    | ([.[] | select(._runid != null)]) as $withrun
    | ($withrun
        | group_by(.workflow)
        | map((map(._runid) | max) as $mx | map(select(._runid == $mx)))
        | add // []) as $scoped
    | ($norun | group_by(.name) | map(sort_by(.startedAt // "") | last)) as $norun_deduped
    | ($scoped + $norun_deduped)
    | map(del(._runid))
  '
}

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
  --check          Run checks only, output JSON, don't merge
  --force          Skip checks and merge (requires explicit user decision;
                   cannot be combined with --auto)
  --auto           If immediate merge is blocked, enable GitHub auto-merge
                   (will fire when CI + branch protection clear). Exits 75.
                   Never bypasses actionable unresolved review threads.
  --dry-run        Show what would happen without merging

Modes:
  (default)        Run checks, block if critical issues, merge if pass
  --check          Run checks, output JSON for workflow to parse
  --force          Deliberately skip all checks, including review threads
  --auto           Enable auto-merge when immediate merge is blocked

Exit codes:
  0    MERGED                 — merge completed immediately
  75   QUEUED / AUTO-MERGE     — merge queue entry or classic auto-merge is active
  1    BLOCKED                — checks failed; nothing queued

Examples:
  github.sh pr-merge 42 --check          # Check only, JSON output
  github.sh pr-merge 42                  # Check + merge if pass
  github.sh pr-merge 42 --auto           # Merge now or queue auto-merge
  github.sh pr-merge 42 --force          # Skip checks, merge (DANGEROUS)
EOF
}

# Run safety checks, output JSON
# JSON shape:
#   {can_merge, issues, warnings, mergeable, review,
#    transient: bool}     # true when only TRANSIENT issues are blocking
run_checks() {
    local pr_num="$1"
    local can_merge=true
    local issues=()
    local warnings=()

    # Check PR exists first (use title - number alone doesn't validate)
    if ! gh pr view "$pr_num" --json title >/dev/null 2>&1; then
        jq -n '{can_merge: false, issues: ["not_found: PR #'"$pr_num"' not found"], warnings: [], mergeable: "UNKNOWN", review: "", transient: false}'
        return 0 # Return 0 so JSON is output, caller checks can_merge
    fi

    # 1. Check mergeable status
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

    # 2. Check CI status
    local ci_json
    set +e
    ci_json=$(gh pr checks "$pr_num" --json name,state,bucket,link,startedAt,workflow 2>&1)
    set -e

    # `gh pr checks` exits 8 while checks are pending, but still prints usable
    # JSON. Treat any valid array response as authoritative regardless of the
    # command's exit status.
    if ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"$ci_json"; then
        can_merge=false
        issues+=("ci_fetch_failed: Failed to fetch CI checks from GitHub")
    elif [ "$(echo "$ci_json" | jq 'length')" -eq 0 ]; then
        warnings+=("ci_unconfigured: No status checks configured")
    else
        # Drop checks belonging to superseded workflow runs before classifying,
        # so a prior canceled run can't be reported as a current merge blocker
        # (vstack#492). Mirrors orch ci-wait's pre-classification scoping.
        local scoped_ci_json ci_classification pending failed
        scoped_ci_json=$(echo "$ci_json" | scope_current_run)
        ci_classification=$(echo "$scoped_ci_json" | jq -c '
            def bucket:
                (.bucket // (
                    if (.state == "SUCCESS") then "pass"
                    elif (.state == "SKIPPED") then "skipping"
                    elif ((.state // "") | IN("PENDING", "QUEUED", "IN_PROGRESS", "WAITING", "REQUESTED", "EXPECTED")) then "pending"
                    elif (.state == "CANCELLED") then "cancel"
                    else "fail"
                    end
                ));
            {
                pending: [.[] | select(bucket == "pending") | .name + " (" + .state + ")"],
                failed: [.[] | select((bucket != "pass") and (bucket != "skipping") and (bucket != "pending")) | .name + " (" + .state + ")"]
            }
        ')
        pending=$(echo "$ci_classification" | jq -r '.pending | join(", ")')
        failed=$(echo "$ci_classification" | jq -r '.failed | join(", ")')
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

    # 4. Check review status
    # reviewDecision is only populated with branch protection rules requiring approvals.
    # Fall back to checking latestReviews for both APPROVED and CHANGES_REQUESTED states.
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

    # Output JSON
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
        '{can_merge: $can_merge, issues: $issues, warnings: $warnings, mergeable: $mergeable, review: $review, transient: $transient}'
}

# Print BLOCKED breakdown to stderr, distinguishing transient vs permanent.
merge_blocked_severity() {
    local check_result="$1"
    local transient
    transient=$(echo "$check_result" | jq -r '.transient // false' 2>/dev/null || echo false)
    if [ "$transient" = "true" ]; then
        echo warning
    else
        echo error
    fi
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

# Read one authoritative post-mutation snapshot. `gh pr view --json` does not
# expose merge-queue membership, so required-queue repositories need GraphQL.
# Fall back to the classic `gh pr view` fields when the queue query itself is
# unavailable; queue membership remains false in that fail-closed fallback.
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
    local check_only=false force=false dry_run=false auto=false

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

    # Check-only mode: output JSON and exit
    if [ "$check_only" = true ]; then
        run_checks "$pr_num"
        exit 0
    fi

    # vstack#101: resolve PR head branch once. Empty when gh fails;
    # `--branch` is conditionally appended below so empty silently omits
    # refs.branch from the activity row.
    local pr_branch
    pr_branch=$(pr_branch_name "$pr_num")

    local token
    token=$(load_bot_token)

    # Unless --force, run checks
    local check_result=""
    if [ "$force" = false ]; then
        local can_merge
        check_result=$(run_checks "$pr_num")
        can_merge=$(echo "$check_result" | jq -r '.can_merge')

        if [ "$can_merge" != "true" ]; then
            # `--auto` may defer GitHub-enforced blockers, but it must never
            # bypass local review-thread safety. GitHub can otherwise accept
            # and immediately merge a PR whose conversations remain open.
            local has_review_thread_gate
            has_review_thread_gate=$(echo "$check_result" | jq '[.issues[] | select(test("^(unresolved_threads|review_threads_fetch_failed):"))] | length > 0')

            # If --auto, fall through to enable auto-merge below.
            # Otherwise, exit BLOCKED with breakdown.
            if [ "$auto" != true ] || [ "$has_review_thread_gate" = "true" ]; then
                local blocked_severity
                blocked_severity=$(merge_blocked_severity "$check_result")
                local block_args=(
                    --severity "$blocked_severity"
                    --importance important
                    --summary "PR #$pr_num merge blocked"
                    --pr-number "$pr_num"
                    --details-json "$check_result"
                )
                [ -n "$pr_branch" ] && block_args+=(--branch "$pr_branch")
                bash "$SCRIPT_DIR/../_activity-emit.sh" pr.merge_blocked "${block_args[@]}" || true
                print_blocked "$check_result" "$pr_num"
                exit 1
            fi
        fi

        # Show warnings even on success
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
    local expected_head
    if ! expected_head=$(gh_with_token "$token" pr view "$pr_num" --json headRefOid --jq '.headRefOid' 2>/dev/null) || [ -z "$expected_head" ]; then
        echo "BLOCKED PR #$pr_num — could not resolve exact head SHA for guarded merge" >&2
        exit 1
    fi

    # Build merge command. --auto enables GitHub's auto-merge — it queues the
    # merge to fire when CI + branch protection clear, returning success now.
    # Without --auto, gh attempts an immediate merge and fails if blocked.
    local -a cmd=(pr merge "$pr_num" "$method" --match-head-commit "$expected_head")
    [ "$auto" = true ] && cmd+=(--auto)

    local merge_output merge_exit=0
    if [ -n "$token" ]; then
        merge_output=$(gh_with_token "$token" "${cmd[@]}" 2>&1) || merge_exit=$?
    else
        echo "Warning: GH_BOT_TOKEN not configured, using current user" >&2
        merge_output=$(gh_with_token "" "${cmd[@]}" 2>&1) || merge_exit=$?
    fi

    # Determine outcome from one authenticated post-call snapshot, taken
    # REGARDLESS of gh's exit code. gh's exit status is not authoritative for
    # merge-queue repositories:
    #   - a required queue can return SUCCESS while the PR stays OPEN with a
    #     null autoMergeRequest (vstack#608), and
    #   - a re-invocation of `--auto` on an ALREADY-QUEUED PR returns NONZERO
    #     even though GitHub still reports it queued, isInMergeQueue: true
    #     (vstack#616).
    # Only the GraphQL snapshot (state + mergeQueueEntry) is authoritative, so
    # take it first and classify from it. This deliberately does not gate on
    # gh's "already queued" stderr wording — that text is a version- and
    # API-dependent GraphQL error and cannot be pinned reliably. The snapshot
    # decides, and it is fail-closed: a genuine failure leaves no active queue
    # entry.
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
    # merge queue entry (vstack#616), classic auto-merge already enabled, or an
    # already merged PR. Anything else — conflicts, auth failure, CI, no
    # enrollment — leaves no such proof and stays BLOCKED with the raw gh
    # output. When the snapshot does prove success, fall through to the shared
    # classification below so the outcome (MERGED / QUEUED / AUTO-MERGE) is
    # reported once.
    # `--force` promises an immediate mutation, so pre-existing pending state
    # must never convert its failed mutation into success (vstack#782). An
    # exact-head MERGED snapshot remains authoritative even if the CLI returned
    # nonzero after the server completed the merge.
    if [ "$merge_exit" -ne 0 ] \
        && [ "$post_state" != "MERGED" ] \
        && { [ "$force" = true ] \
            || { [ "$post_in_queue" != "true" ] \
                && [ "$post_queue_entry" != "true" ] \
                && [ "$post_auto" != "true" ]; }; }; then
        local fail_args=(
            --severity error
            --importance important
            --summary "PR #$pr_num merge blocked"
            --pr-number "$pr_num"
            --details-json "$(jq -cn --arg output "$merge_output" '{merge_output: $output, transient: false}')"
        )
        [ -n "$pr_branch" ] && fail_args+=(--branch "$pr_branch")
        bash "$SCRIPT_DIR/../_activity-emit.sh" pr.merge_blocked "${fail_args[@]}" || true
        echo "BLOCKED PR #$pr_num — gh pr merge failed" >&2
        printf '%s\n' "$merge_output" | sed 's/^/  /' >&2
        exit 1
    fi

    if [ "$post_state" = "MERGED" ]; then
        echo "MERGED PR #$pr_num" >&2
        local merge_commit
        merge_commit=$(jq -r '.merge_commit' <<<"$post_snapshot")
        local merged_args=(
            --severity success
            --importance important
            --summary "PR #$pr_num merged"
            --pr-number "$pr_num"
            --commit "$merge_commit"
        )
        [ -n "$pr_branch" ] && merged_args+=(--branch "$pr_branch")
        bash "$SCRIPT_DIR/../_activity-emit.sh" pr.merged "${merged_args[@]}" || true
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
        local queued_args=(
            --severity info
            --importance normal
            --summary "PR #$pr_num queued in merge queue"
            --pr-number "$pr_num"
        )
        [ -n "$pr_branch" ] && queued_args+=(--branch "$pr_branch")
        bash "$SCRIPT_DIR/../_activity-emit.sh" pr.merge_queued "${queued_args[@]}" || true
        echo "QUEUED IN MERGE QUEUE PR #$pr_num — queueState=${post_queue_state:-active}" >&2
        echo "  Track with: github.sh await-mergeable $pr_num" >&2
        exit 75
    fi

    if [ "$post_auto" = "true" ]; then
        local auto_args=(
            --severity info
            --importance normal
            --summary "PR #$pr_num auto-merge enabled"
            --pr-number "$pr_num"
        )
        [ -n "$pr_branch" ] && auto_args+=(--branch "$pr_branch")
        bash "$SCRIPT_DIR/../_activity-emit.sh" pr.merge_queued "${auto_args[@]}" || true
        echo "AUTO-MERGE ENABLED PR #$pr_num — will fire when CI + branch protection clear" >&2
        echo "  Track with: github.sh await-mergeable $pr_num" >&2
        exit 75
    fi

    # gh exited 0 but PR isn't merged and isn't queued. Treat as BLOCKED so
    # callers don't assume success based on exit code alone.
    local blocked_args=(
        --severity error
        --importance important
        --summary "PR #$pr_num merge blocked"
        --pr-number "$pr_num"
        --details-json "$(jq -cn --arg state "$post_state" --arg auto "$post_auto" --arg output "$merge_output" '{state: $state, auto_merge: $auto, merge_output: $output, transient: false}')"
    )
    [ -n "$pr_branch" ] && blocked_args+=(--branch "$pr_branch")
    bash "$SCRIPT_DIR/../_activity-emit.sh" pr.merge_blocked "${blocked_args[@]}" || true
    echo "BLOCKED PR #$pr_num — gh reported success but state=$post_state, autoMerge=$post_auto, mergeQueue=false" >&2
    printf '%s\n' "$merge_output" | sed 's/^/  /' >&2
    exit 1
}

main "$@"
