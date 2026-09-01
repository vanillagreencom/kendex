#!/bin/bash
# Cross-PR validation for batch merge safety
# Usage: pr-cross-check [--quick|--verify] [PR_NUM...] [--json]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/github-api.sh"

show_help() {
    cat <<'EOF'
Cross-PR validation for batch merge safety

Usage: pr-cross-check [options] [PR_NUM...]

Modes:
  --quick   Heuristic checks only (~5 seconds) [DEFAULT]
  --verify  Full merge simulation + build + test (~5-10 minutes)

Options:
  --json    Output as JSON (default when no args, table otherwise)
  --help    Show this help

Arguments:
  PR_NUM    Specific PR numbers to analyze (default: all ready-to-merge PRs)

Quick mode analyzes:
  - File overlaps (same file modified by multiple PRs)
  - Merge conflicts (GitHub mergeable status)
  - Sequential dependencies (branch relationships)

Verify mode additionally:
  - Creates temp worktree and merges PRs
  - Builds Rust (cargo build --release)
  - Runs Rust tests (cargo test --release)

Examples:
  github.sh pr-cross-check              # Quick analysis of ready PRs
  github.sh pr-cross-check 70 71        # Quick analysis of specific PRs
  github.sh pr-cross-check --verify     # Full verification (build + test)
  github.sh pr-cross-check 70 71 --verify --json  # Verify with JSON output
EOF
}

# Fetch PR data with files
fetch_pr_data() {
    local pr_num="$1"
    local output
    if ! output=$(gh pr view "$pr_num" --json number,headRefName,files,mergeable,baseRefName 2>&1); then
        local reason
        reason=$(printf '%s' "$output" | tr '\n' ' ' | head -c 200)
        jq -n --arg pr "$pr_num" --arg reason "${reason:-GitHub API request failed}" \
            '{error: "fetch_failed", number: ($pr | tonumber? // $pr), reason: $reason}'
        return 1
    fi
    printf '%s\n' "$output"
}

# Build file overlap map
analyze_overlaps() {
    local prs_json="$1"

    # Build file -> PR list map, then find overlaps
    echo "$prs_json" | jq '
        # Build map of file -> [pr_numbers]
        reduce .[] as $pr ({};
            reduce ($pr.files // [])[] as $file (.;
                .[$file.path] = (.[$file.path] // []) + [$pr.number]
            )
        )
        # Filter to only files with multiple PRs
        | to_entries
        | map(select(.value | length > 1))
        | map({
            file: .key,
            prs: .value
        })
    '
}

# Order PRs by how few other PRs they collide with, then by number.
compute_merge_order() {
    local prs_json="$1"
    local overlaps_json="$2"

    echo "$prs_json" | jq --argjson overlaps "$overlaps_json" '
        # Count overlaps per PR
        map(. as $pr | . + {
            overlap_count: (
                [$overlaps[] | select(.prs | contains([$pr.number]))] | length
            )
        })
        # Sort by overlap count (ascending), then by PR number (ascending)
        | sort_by(.overlap_count, .number)
        | map(.number)
    '
}

emit_ready_pr_fetch_failure() {
    local mode="$1"
    local description="Failed to fetch ready-to-merge PRs from GitHub"

    jq -n --arg mode "$mode" --arg description "$description" '{
        mode: $mode,
        prs: [],
        issues: [{
            severity: "high",
            type: "ready_pr_fetch_failed",
            description: $description,
            prs: [],
            files: [],
            recommendation: "retry_after_fixing_github_access"
        }],
        merge_order: [],
        can_batch_merge: false,
        summary: {
            total_prs: 0,
            issues_count: 1,
            high_severity: 1,
            medium_severity: 0,
            low_severity: 0
        },
        error: "ready_pr_fetch_failed"
    }'
}

main() {
    local json_output=false
    local mode="quick"
    local pr_nums=()

    while [ $# -gt 0 ]; do
        case "$1" in
        --quick)
            mode="quick"
            shift
            ;;
        --verify)
            mode="verify"
            shift
            ;;
        --json)
            json_output=true
            shift
            ;;
        --help | -h)
            show_help
            exit 0
            ;;
        [0-9]*)
            pr_nums+=("$1")
            shift
            ;;
        *)
            echo "Error: Unknown option: $1" >&2
            exit 1
            ;;
        esac
    done

    # Handle verify mode - delegate to verify-lib.sh
    if [ "$mode" = "verify" ]; then
        # If no PR numbers, get ready PRs
        if [ ${#pr_nums[@]} -eq 0 ]; then
            local ready_prs
            if ! ready_prs=$(json_or_default '[]' array "$SCRIPT_DIR/pr-list-ready.sh" --format=safe); then
                emit_ready_pr_fetch_failure "verify"
                exit 0
            fi
            # Use while-read instead of the Bash 4 array-read builtin
            while IFS= read -r num; do
                [ -n "$num" ] && pr_nums+=("$num")
            done < <(echo "$ready_prs" | jq -r '.[] | select(.ready) | .number')
        fi

        if [ ${#pr_nums[@]} -lt 2 ]; then
            jq -n '{
                mode: "verify",
                error: "Need at least 2 PRs for verification",
                can_batch_merge: true,
                issues: []
            }'
            exit 0
        fi

        local verify_script="$SCRIPT_DIR/../lib/verify-lib.sh"
        if [ -f "$verify_script" ]; then
            exec "$verify_script" verify_prs "${pr_nums[@]}"
        else
            echo '{"error": "verify-lib.sh not found. --verify mode requires a project-specific verification script at lib/verify-lib.sh"}' >&2
            exit 1
        fi
    fi

    # Quick mode continues below...

    # If no PR numbers provided, get all ready PRs
    if [ ${#pr_nums[@]} -eq 0 ]; then
        json_output=true # Default to JSON when auto-detecting
        local ready_prs
        if ! ready_prs=$(json_or_default '[]' array "$SCRIPT_DIR/pr-list-ready.sh" --format=safe); then
            emit_ready_pr_fetch_failure "quick"
            exit 0
        fi
        # Use while-read instead of the Bash 4 array-read builtin
        while IFS= read -r num; do
            [ -n "$num" ] && pr_nums+=("$num")
        done < <(echo "$ready_prs" | jq -r '.[] | select(.ready) | .number')
    fi

    # Need at least 2 PRs for cross-check
    if [ ${#pr_nums[@]} -lt 2 ]; then
        jq -n '{
            prs: [],
            issues: [],
            merge_order: [],
            can_batch_merge: true,
            summary: { total_prs: 0, issues_count: 0, high_severity: 0, medium_severity: 0, low_severity: 0 }
        }'
        exit 0
    fi

    # Fetch data for each PR
    local prs_data="[]"
    local fetch_failures="[]"
    for pr_num in "${pr_nums[@]}"; do
        local pr_data
        if ! pr_data=$(fetch_pr_data "$pr_num"); then
            fetch_failures=$(echo "$fetch_failures" | jq --argjson failure "$pr_data" '. + [$failure]')
            continue
        fi

        prs_data=$(echo "$prs_data" | jq --argjson pr "$pr_data" '. + [{
            number: $pr.number,
            branch: $pr.headRefName,
            base: $pr.baseRefName,
            files: $pr.files,
            mergeable: $pr.mergeable
        }]')
    done

    # Analyze file overlaps
    local overlaps
    overlaps=$(analyze_overlaps "$prs_data")

    # Build issues list
    local issues
    issues=$(echo "$fetch_failures" | jq '
        map({
            severity: "high",
            type: "pr_fetch_failed",
            description: "Failed to fetch PR #\(.number) from GitHub: \(.reason)",
            prs: [.number],
            files: [],
            recommendation: "retry_after_fixing_github_access"
        })
    ')

    # Add file overlap issues
    issues=$(echo "$issues" | jq --argjson overlaps "$overlaps" '. + (
        $overlaps | map({
            severity: "medium",
            type: "file_overlap",
            description: "File \(.file) modified by PRs \(.prs | map("#\(.)") | join(", "))",
            prs: .prs,
            files: [.file],
            recommendation: "merge_sequentially"
        })
    )')

    # Check for merge conflicts
    local conflicts
    conflicts=$(echo "$prs_data" | jq '[.[] | select(.mergeable == "CONFLICTING") | .number]')
    if [ "$(echo "$conflicts" | jq 'length')" -gt 0 ]; then
        issues=$(echo "$issues" | jq --argjson conflicts "$conflicts" '. + [{
            severity: "high",
            type: "merge_conflict",
            description: "PRs \($conflicts | map("#\(.)") | join(", ")) have merge conflicts with base branch",
            prs: $conflicts,
            files: [],
            recommendation: "resolve_conflicts_first"
        }]')
    fi

    # Compute merge order
    local merge_order
    merge_order=$(compute_merge_order "$prs_data" "$overlaps")

    # Determine if batch merge is safe
    local can_batch_merge
    can_batch_merge=$(echo "$issues" | jq 'all(.severity != "high") and length == 0')

    # Build summary
    local summary
    summary=$(echo "$issues" | jq '{
        total_prs: '"${#pr_nums[@]}"',
        issues_count: length,
        high_severity: [.[] | select(.severity == "high")] | length,
        medium_severity: [.[] | select(.severity == "medium")] | length,
        low_severity: [.[] | select(.severity == "low")] | length
    }')

    # Build final output
    local result
    result=$(jq -n \
        --argjson prs "$(echo "$prs_data" | jq 'map({number, branch, files: [.files[].path], mergeable})')" \
        --argjson issues "$issues" \
        --argjson merge_order "$merge_order" \
        --argjson can_batch_merge "$can_batch_merge" \
        --argjson summary "$summary" \
        '{
            mode: "quick",
            prs: $prs,
            issues: $issues,
            merge_order: $merge_order,
            can_batch_merge: $can_batch_merge,
            summary: $summary
        }')

    if [ "$json_output" = true ]; then
        echo "$result"
    else
        # Table output
        echo "Cross-PR Analysis"
        echo "================="
        echo ""
        echo "PRs analyzed: ${#pr_nums[@]}"
        echo ""

        local issues_count
        issues_count=$(echo "$result" | jq '.summary.issues_count')

        if [ "$issues_count" -eq 0 ]; then
            echo "✓ No issues detected - safe to batch merge"
        else
            echo "Issues found:"
            echo "$result" | jq -r '.issues[] |
                "  \(if .severity == "high" then "🔴" elif .severity == "medium" then "🟡" else "⚪" end) [\(.type)] \(.description)"'
        fi

        echo ""
        echo "Recommended merge order: $(echo "$result" | jq -r '.merge_order | map("#\(.)") | join(" → ")')"
        echo ""

        if [ "$(echo "$result" | jq '.can_batch_merge')" = "true" ]; then
            echo "✓ Can batch merge: yes"
        else
            echo "✗ Can batch merge: no (resolve issues first)"
        fi
    fi
}

main "$@"
