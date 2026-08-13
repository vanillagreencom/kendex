#!/bin/bash
# List PRs ready for merge
# Usage: pr-list-ready [--all] [--json]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/github-api.sh"

show_help() {
    cat <<'EOF'
List PRs ready for merge

Usage: pr-list-ready [options]

Options:
  --all             Show all open PRs (not just repo-local/user branches)
  --format=safe     JSON output (default)
  --format=table    Human-readable table
  --json            Alias for --format=safe (deprecated)

Shows PRs filtered by:
  - Local branches in this repo/worktree set (e.g. proj-117)
  - Current user's namespaced branches (e.g. user/proj-117)
  unless --all
  - Review approved
  - CI passing

Output includes merge readiness check for each PR.

Examples:
  github.sh pr-list-ready                 # JSON output
  github.sh pr-list-ready --all           # All ready PRs (JSON)
  github.sh pr-list-ready --format=table  # Human-readable table
EOF
}

main() {
    local all_prs=false format="safe"

    while [ $# -gt 0 ]; do
        case "$1" in
        --all)
            all_prs=true
            shift
            ;;
        --format=*)
            format="${1#--format=}"
            shift
            ;;
        --json)
            format="safe"
            shift
            ;; # Deprecated alias
        --help | -h)
            show_help
            exit 0
            ;;
        *)
            echo "Error: Unknown option: $1" >&2
            exit 1
            ;;
        esac
    done

    local gh_user prs local_branches
    gh_user=$(gh api user --jq '.login' 2>/dev/null || echo "")

    # Get PRs with status info
    # Include latestReviews as fallback when reviewDecision is empty (no branch protection).
    prs=$(gh pr list --json number,title,headRefName,reviewDecision,latestReviews,statusCheckRollup,mergeable)

    # An unresolvable login narrows the scope to local branches only; it must
    # not silently widen the default listing to every open PR in the repo.
    if [ "$all_prs" != true ]; then
        local_branches=$(get_local_branch_names_json)
        prs=$(filter_prs_to_default_scope "$prs" "$gh_user" "$local_branches")
    fi

    # Retry logic for UNKNOWN mergeable state (GitHub computes async)
    local max_retries=3 retry_delay=2
    local unknown_prs retry_count=0
    unknown_prs=$(echo "$prs" | jq '[.[] | select(.mergeable == "UNKNOWN")] | length')

    while [ "$unknown_prs" -gt 0 ] && [ "$retry_count" -lt "$max_retries" ]; do
        retry_count=$((retry_count + 1))
        sleep "$retry_delay"

        # Re-fetch only PRs with UNKNOWN state
        local pr_numbers updated_prs
        pr_numbers=$(echo "$prs" | jq -r '[.[] | select(.mergeable == "UNKNOWN") | .number] | join(",")')

        # Fetch each PR individually to get fresh mergeable state
        updated_prs="[]"
        for pr_num in $(echo "$pr_numbers" | tr ',' ' '); do
            local pr_data
            if ! pr_data=$(json_or_default '{}' object gh pr view "$pr_num" --json number,title,headRefName,reviewDecision,latestReviews,statusCheckRollup,mergeable); then
                continue
            fi
            if [ "$pr_data" != "{}" ]; then
                updated_prs=$(echo "$updated_prs" | jq --argjson pr "$pr_data" '. + [$pr]')
            fi
        done

        # Merge updated PRs back into prs array
        prs=$(echo "$prs" | jq --argjson updates "$updated_prs" '
            . as $orig |
            ($updates | map({(.number | tostring): .}) | add // {}) as $update_map |
            $orig | map(
                if $update_map[.number | tostring] then
                    $update_map[.number | tostring]
                else . end
            )
        ')

        unknown_prs=$(echo "$prs" | jq '[.[] | select(.mergeable == "UNKNOWN")] | length')
    done

    # Enrich with ready status.
    # statusCheckRollup mixes two node shapes: CheckRun nodes carry
    # .conclusion (empty/null while running), while StatusContext nodes
    # (classic commit statuses) have NO conclusion at all — their result is
    # .state (SUCCESS/PENDING/ERROR/FAILURE/EXPECTED). jq reads a missing
    # field as null, so a conclusion-only predicate counts every
    # StatusContext — including pending and failing ones — as passing.
    # Judge each node by its own shape; anything neither passing nor failing
    # (in-progress runs, PENDING/EXPECTED statuses) classifies as pending.
    local enriched
    enriched=$(echo "$prs" | jq '
        def is_status_context: .__typename == "StatusContext" or (has("state") and .state != null);
        def node_passing:
            if is_status_context then .state == "SUCCESS"
            else .conclusion == "SUCCESS" or .conclusion == "SKIPPED" or .conclusion == "CANCELLED"
            end;
        def node_failing:
            if is_status_context then .state == "ERROR" or .state == "FAILURE"
            else .conclusion == "FAILURE"
            end;
        map({
            number,
            title,
            branch: .headRefName,
            review: .reviewDecision,
            has_approved_review: ([.latestReviews[] | select(.state == "APPROVED")] | length > 0),
            has_changes_requested: ([.latestReviews[] | select(.state == "CHANGES_REQUESTED")] | length > 0),
            ci: (if (.statusCheckRollup | length) == 0 then "no_checks"
                 elif (.statusCheckRollup | all(node_passing)) then "passing"
                 elif (.statusCheckRollup | any(node_failing)) then "failing"
                 else "pending" end),
            mergeable: .mergeable,
            ready: (
                (.reviewDecision != "CHANGES_REQUESTED") and
                ([.latestReviews[] | select(.state == "CHANGES_REQUESTED")] | length == 0) and
                (.reviewDecision == "APPROVED" or ([.latestReviews[] | select(.state == "APPROVED")] | length > 0)) and
                .mergeable == "MERGEABLE" and
                ((.statusCheckRollup | length) == 0 or (.statusCheckRollup | all(node_passing)))
            )
        })
    ')

    case "$format" in
    safe | json)
        echo "$enriched"
        ;;
    table)
        local ready_count total_count
        ready_count=$(echo "$enriched" | jq '[.[] | select(.ready)] | length')
        total_count=$(echo "$enriched" | jq 'length')

        if [ "$total_count" = "0" ]; then
            echo "No open PRs found."
            exit 0
        fi

        echo "PRs ($ready_count/$total_count ready):"
        echo ""
        echo "$enriched" | jq -r '.[] |
                (if .ready then "  ✓" else "  ✗" end) +
                " #\(.number) \(.title)" +
                "\n      " + .branch +
                " | Review: \(.review // "none")" +
                " | CI: \(.ci)" +
                " | Mergeable: \(.mergeable)"
            '
        ;;
    *)
        echo "Error: Unknown format: $format. Use: safe, table" >&2
        exit 1
        ;;
    esac
}

main "$@"
