#!/bin/bash
# List PRs with CI failures
# Usage: pr-list-failing [--all] [--json]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/github-api.sh"

show_help() {
    cat << 'EOF'
List PRs with CI failures

Usage: pr-list-failing [options]

Options:
  --all             Show all failing PRs (not just repo-local/user branches)
  --format=safe     JSON output (default)
  --format=table    Human-readable table
  --json            Alias for --format=safe (deprecated)

Shows PRs filtered by:
  - Local branches in this repo/worktree set (e.g. proj-117)
  - Current user's namespaced branches (e.g. user/proj-117)
  unless --all
  - Any CI check with FAILURE or STARTUP_FAILURE conclusion

Output includes failed check names and summary.

Examples:
  github.sh pr-list-failing                 # JSON output
  github.sh pr-list-failing --all           # All failing PRs (JSON)
  github.sh pr-list-failing --format=table  # Human-readable table
EOF
}

main() {
    local all_prs=false format="safe"

    while [ $# -gt 0 ]; do
        case "$1" in
            --all) all_prs=true; shift ;;
            --format=*) format="${1#--format=}"; shift ;;
            --json) format="safe"; shift ;;  # Deprecated alias
            --help|-h) show_help; exit 0 ;;
            *) echo "Error: Unknown option: $1" >&2; exit 1 ;;
        esac
    done

    local gh_user prs local_branches
    gh_user=$(gh api user --jq '.login' 2>/dev/null || echo "")

    # Get PRs with status info
    prs=$(gh pr list --json number,title,headRefName,statusCheckRollup)

    # An unresolvable login narrows the scope to local branches only; it must
    # not silently widen the default listing to every open PR in the repo.
    if [ "$all_prs" != true ]; then
        local_branches=$(get_local_branch_names_json)
        prs=$(filter_prs_to_default_scope "$prs" "$gh_user" "$local_branches")
    fi

    # Filter for failing PRs and enrich with failure details.
    # statusCheckRollup mixes two node shapes: CheckRun nodes report through
    # .conclusion, while StatusContext nodes (classic commit statuses) have no
    # conclusion at all and report through .state. A conclusion-only predicate
    # therefore never sees a failing classic status. Judge each node by its own
    # shape, and name StatusContext nodes by .context, which is where they
    # carry their name.
    local enriched
    enriched=$(echo "$prs" | jq '
        def is_status_context: .__typename == "StatusContext" or (has("state") and .state != null);
        def node_failing:
            if is_status_context then .state == "ERROR" or .state == "FAILURE"
            else .conclusion == "FAILURE" or .conclusion == "STARTUP_FAILURE"
            end;
        def node_name: .name // .context // "";
        map(
            select((.statusCheckRollup // []) | any(node_failing))
        ) | map({
            number,
            title,
            branch: .headRefName,
            failed_checks: [(.statusCheckRollup // [])[] | select(node_failing) | node_name],
            check_summary: (
                ([(.statusCheckRollup // [])[] | select(node_failing)] | length | tostring) +
                "/" +
                ((.statusCheckRollup // []) | length | tostring) +
                " failed"
            )
        })
    ')

    case "$format" in
        safe|json)
            echo "$enriched"
            ;;
        table)
            local total_count
            total_count=$(echo "$enriched" | jq 'length')

            if [ "$total_count" = "0" ]; then
                echo "No failing PRs found."
                exit 0
            fi

            echo "Failing PRs ($total_count):"
            echo ""
            echo "$enriched" | jq -r '.[] |
                "  ✗ #\(.number) \(.title)" +
                "\n      \(.branch)" +
                "\n      Failed: \(.failed_checks | join(", "))" +
                "\n      Summary: \(.check_summary)"
            '
            ;;
        *)
            echo "Error: Unknown format: $format. Use: safe, table" >&2
            exit 1
            ;;
    esac
}

main "$@"
