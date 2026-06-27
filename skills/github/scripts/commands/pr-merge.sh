#!/bin/bash
# Merge PR as bot account with safety checks
# Usage: pr-merge <PR_NUMBER> [--check] [--force] [--auto] [--dry-run]
#
# Outcomes (distinct exit codes + messages):
#   0   MERGED                 — merge completed immediately
#   75  QUEUED FOR AUTO-MERGE  — --auto enabled, merge fires when CI/branch-protection clears
#   1   BLOCKED                — checks failed; no merge attempted, none queued
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
  --force          Skip checks and merge (requires explicit user decision)
  --auto           If immediate merge is blocked, enable GitHub auto-merge
                   (will fire when CI + branch protection clear). Exits 75.
  --dry-run        Show what would happen without merging

Modes:
  (default)        Run checks, block if critical issues, merge if pass
  --check          Run checks, output JSON for workflow to parse
  --force          Skip all checks, merge immediately
  --auto           Enable auto-merge when immediate merge is blocked

Exit codes:
  0    MERGED                 — merge completed immediately
  75   QUEUED FOR AUTO-MERGE  — --auto enabled, will fire when CI clears
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
    ci_json=$(gh pr checks "$pr_num" --json name,state,bucket 2>&1)
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
        local ci_classification pending failed
        ci_classification=$(echo "$ci_json" | jq -c '
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

    # 3. Check unresolved threads
    local unresolved
    unresolved=$("$SCRIPT_DIR/pr-threads.sh" "$pr_num" --unresolved 2>/dev/null | jq -r '.unresolved_count // 0')
    if [ "$unresolved" != "0" ]; then
        warnings+=("unresolved_threads: $unresolved thread(s) need attention")
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
    echo "Use --auto to queue for auto-merge, or --force to merge anyway." >&2
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
            # If --auto, fall through to enable auto-merge below.
            # Otherwise, exit BLOCKED with breakdown.
            if [ "$auto" != true ]; then
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

    # Build merge command. --auto enables GitHub's auto-merge — it queues the
    # merge to fire when CI + branch protection clear, returning success now.
    # Without --auto, gh attempts an immediate merge and fails if blocked.
    local -a cmd=(gh pr merge "$pr_num" "$method")
    [ "$auto" = true ] && cmd+=(--auto)

    local merge_output merge_exit=0
    if [ -n "$token" ]; then
        merge_output=$(GH_TOKEN="$token" "${cmd[@]}" 2>&1) || merge_exit=$?
    else
        echo "Warning: GH_BOT_TOKEN not configured, using current user" >&2
        merge_output=$("${cmd[@]}" 2>&1) || merge_exit=$?
    fi

    if [ "$merge_exit" -ne 0 ]; then
        # Merge command itself failed. Surface as BLOCKED with raw output.
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

    # Determine outcome by re-reading PR state. With --auto, gh exits 0 in
    # both the merged-immediately case (CI was already green) and the queued
    # case — only the post-call state distinguishes them.
    local post_state post_auto
    post_state=$(gh pr view "$pr_num" --json state --jq '.state' 2>/dev/null || echo "UNKNOWN")
    post_auto=$(gh pr view "$pr_num" --json autoMergeRequest --jq '.autoMergeRequest != null' 2>/dev/null || echo "false")

    if [ "$post_state" = "MERGED" ]; then
        echo "MERGED PR #$pr_num" >&2
        local merge_commit
        merge_commit=$(gh pr view "$pr_num" --json mergeCommit --jq '.mergeCommit.oid // ""' 2>/dev/null || true)
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
            branch=$(gh pr view "$pr_num" --json headRefName --jq '.headRefName' 2>/dev/null || true)
            if [ -n "$branch" ]; then
                gh api -X DELETE "repos/{owner}/{repo}/git/refs/heads/$branch" 2>/dev/null || true
            fi
        fi
        exit 0
    fi

    if [ "$auto" = true ] && [ "$post_auto" = "true" ]; then
        local queued_args=(
            --severity info
            --importance normal
            --summary "PR #$pr_num queued for auto-merge"
            --pr-number "$pr_num"
        )
        [ -n "$pr_branch" ] && queued_args+=(--branch "$pr_branch")
        bash "$SCRIPT_DIR/../_activity-emit.sh" pr.merge_queued "${queued_args[@]}" || true
        echo "QUEUED FOR AUTO-MERGE PR #$pr_num — will fire when CI + branch protection clear" >&2
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
    echo "BLOCKED PR #$pr_num — gh reported success but state=$post_state, autoMerge=$post_auto" >&2
    printf '%s\n' "$merge_output" | sed 's/^/  /' >&2
    exit 1
}

main "$@"
