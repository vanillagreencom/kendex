#!/bin/bash
# GitHub API - Get PR with threads, comments, and files
# Usage: pr-data.sh [PR-number|branch] [--format=safe|raw]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/github-api.sh"

show_help() {
    cat << 'EOF'
Get PR Data

Usage: pr-data.sh [PR-number|branch] [options]

Arguments:
  PR-number|branch    PR number or branch name (default: current branch's PR)

Options:
  --format=safe       Normalized flat structure (DEFAULT)
  --format=raw        Original GitHub API structure
  --actionable        Only unresolved non-outdated threads, exclude bot comments

Output (safe format):
{
  "number": 23,
  "title": "PR title",
  "branch": "feature-branch",
  "files": ["path/to/file.rs"],
  "threads": [{
    "id": "PRRT_...",
    "is_resolved": false,
    "is_outdated": false,
    "path": "src/file.rs",
    "line": 42,
    "comments": [{
      "author": "reviewer",
      "body": "Comment text",
      "url": "https://..."
    }]
  }],
  "comments": [{
    "id": "IC_...",
    "author": "reviewer",
    "body": "PR-level comment",
    "url": "https://...",
    "created_at": "2025-01-01T00:00:00Z"
  }]
}

Examples:
  pr-data.sh 23
  pr-data.sh feature-branch
  pr-data.sh --format=raw
EOF
}

get_pr_data() {
    local pr_ref=""
    local pr_ref_set=false
    local actionable="false"
    FORMAT="${DEFAULT_FORMAT}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)
                show_help
                exit 0
                ;;
            --actionable)
                actionable="true"
                shift
                ;;
            --format=*)
                FORMAT="${1#--format=}"
                shift
                ;;
            --format)
                if [ -z "${2:-}" ]; then
                    echo '{"error": "--format requires an argument (safe or raw)"}' >&2
                    exit 1
                fi
                FORMAT="$2"
                shift 2
                ;;
            -*)
                echo "{\"error\": \"Unknown option: $1\"}" >&2
                exit 1
                ;;
            *)
                if [ "$pr_ref_set" = false ]; then
                    pr_ref="$1"; pr_ref_set=true
                else
                    echo "{\"error\": \"Unexpected argument: $1\"}" >&2
                    exit 1
                fi
                shift
                ;;
        esac
    done

    case "$FORMAT" in
        safe|raw) ;;
        *)
            echo "{\"error\": \"Invalid format: $FORMAT. Use: safe, raw\"}" >&2
            exit 1
            ;;
    esac

    # Resolve PR number
    local pr_num
    pr_num=$(resolve_pr_number "$pr_ref") || exit 1

    # Get repo info
    local repo_info
    repo_info=$(get_repo_info) || exit 1
    local owner repo
    owner=$(get_owner "$repo_info")
    repo=$(get_repo "$repo_info")

    # GraphQL query for PR data.
    # `reactions` on the PR itself and on each PR-level comment let downstream
    # consumers interpret bots that signal review state via reactions
    # (e.g. Codex: 👀 = reviewing, 👍 = approved).
    local query='
query($owner: String!, $repo: String!, $pr: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $pr) {
      number
      title
      headRefName
      files(first: 100) {
        nodes { path }
      }
      reactions(first: 100) {
        nodes { content user { login } }
      }
      reviewThreads(first: 100) {
        nodes {
          id
          isResolved
          isOutdated
          path
          line
          comments(first: 10) {
            nodes {
              author { login }
              body
              url
            }
          }
        }
      }
      comments(first: 50) {
        nodes {
          id
          author { login }
          body
          url
          createdAt
          reactions(first: 100) {
            nodes { content user { login } }
          }
        }
      }
    }
  }
}'

    local result
    result=$(gh_graphql "$query" -F owner="$owner" -F repo="$repo" -F pr="$pr_num") || exit 1

    # Apply format
    local output
    case "$FORMAT" in
        raw)
            output="$result"
            ;;
        safe)
            output=$(echo "$result" | jq '
                def reaction_norm(c):
                    if   c == "THUMBS_UP"   then "+1"
                    elif c == "THUMBS_DOWN" then "-1"
                    elif c == "EYES"        then "eyes"
                    elif c == "LAUGH"       then "laugh"
                    elif c == "HOORAY"      then "hooray"
                    elif c == "CONFUSED"    then "confused"
                    elif c == "HEART"       then "heart"
                    elif c == "ROCKET"      then "rocket"
                    else (c // "") | ascii_downcase end;
                {
                number: .repository.pullRequest.number,
                title: (.repository.pullRequest.title // ""),
                branch: (.repository.pullRequest.headRefName // ""),
                files: [.repository.pullRequest.files.nodes[].path],
                reactions: [.repository.pullRequest.reactions.nodes[]? | {
                    content: reaction_norm(.content),
                    user: (.user.login // "")
                }],
                threads: [.repository.pullRequest.reviewThreads.nodes[] | {
                    id: .id,
                    is_resolved: .isResolved,
                    is_outdated: .isOutdated,
                    path: (.path // ""),
                    line: (.line // null),
                    source: "inline",
                    comments: [.comments.nodes[] | {
                        author: (.author.login // ""),
                        body: (.body // ""),
                        url: (.url // ""),
                        # Extract numeric ID from URL for post-reply
                        reply_id: ((.url // "") | capture("r(?<id>[0-9]+)$") | .id // null)
                    }]
                }],
                comments: [.repository.pullRequest.comments.nodes[] | {
                    id: .id,
                    author: (.author.login // ""),
                    body: (.body // ""),
                    url: (.url // ""),
                    created_at: (.createdAt // ""),
                    source: "pr-level",
                    reactions: [(.reactions.nodes[]? // empty) | {
                        content: reaction_norm(.content),
                        user: (.user.login // "")
                    }]
                }]
            }')
            ;;
    esac

    # Apply actionable filter (unresolved non-outdated threads, no bot comments).
    # `reactions` is preserved on the top-level PR so callers can interpret
    # reaction-based reviewers (e.g. Codex 👀/👍) downstream.
    if [ "$actionable" = "true" ] && [ "$FORMAT" != "raw" ]; then
        output=$(echo "$output" | jq --arg bot_user "${GH_BOT_USERNAME:-review-bot[bot]}" '{
            number,
            title,
            branch,
            files,
            reactions: (.reactions // []),
            threads: [.threads[] | select(.is_resolved == false and .is_outdated == false) | {
                id, path, line, source,
                comments: [.comments[] | select(.author | IN("github-actions", "github-actions[bot]", "dependabot", "dependabot[bot]", "codecov", "codecov[bot]", $bot_user) | not)]
            } | select(.comments | length > 0)],
            comments: [.comments[] | select(.author | IN("github-actions", "github-actions[bot]", "dependabot", "dependabot[bot]", "codecov", "codecov[bot]", $bot_user) | not)]
        }')
    fi

    echo "$output"
}

# Main
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    show_help
    exit 0
fi

get_pr_data "$@"
