#!/bin/bash
# Linear GraphQL API - User Operations
# Usage: users.sh <action> [options]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

show_help() {
    cat << 'EOF'
User Operations

Usage: users.sh <action> [options]

Actions:
  list    List users
  get     Get a single user by ID, name, or "me"
  me      Get current user (shorthand for "get me")

List Options:
  --limit <n>           Max results (default: 50)

Get:
  users.sh get <id-or-name>
  users.sh get me

Examples:
  users.sh list
  users.sh get me
  users.sh me
  users.sh get "Brad M"
EOF
}

list_users() {
    local first=75
    FORMAT="${DEFAULT_FORMAT}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --limit)
                first="$2"
                shift 2
                ;;
            --format) FORMAT="$2"; shift 2 ;;
            --format=*) FORMAT="${1#--format=}"; shift ;;
            --) shift; break ;;
            -*) echo "{\"error\": \"Unknown option: $1. Run --help for valid options.\"}" >&2; return 1 ;;
            *) break ;;
        esac
    done

    local query='
    query ListUsers($first: Int) {
        users(first: $first) {
            nodes {
                id
                name
                email
                displayName
                active
                admin
                createdAt
            }
        }
    }'

    local variables="{\"first\": $first}"
    local result
    result=$(graphql_query "$query" "$variables")

    # Apply output format
    case "$FORMAT" in
        raw)
            echo "$result"
            ;;
        safe|*)
            format_users_list "$result"
            ;;
    esac
}

get_user() {
    local user_ref=""
    FORMAT="${DEFAULT_FORMAT}"

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --format) FORMAT="$2"; shift 2 ;;
            --format=*) FORMAT="${1#--format=}"; shift ;;
            *) user_ref="$1"; shift ;;
        esac
    done

    if [ -z "$user_ref" ]; then
        echo '{"error": "User ID or \"me\" required"}' >&2
        return 1
    fi

    local result
    if [ "$user_ref" = "me" ]; then
        local query='
        query GetViewer {
            viewer {
                id
                name
                email
                displayName
                active
                admin
                teams { nodes { name } }
                createdAt
            }
        }'
        result=$(graphql_query "$query" "{}")
    else
        local query='
        query GetUser($id: String!) {
            user(id: $id) {
                id
                name
                email
                displayName
                active
                admin
                teams { nodes { name } }
                createdAt
            }
        }'
        local variables="{\"id\": \"$user_ref\"}"
        result=$(graphql_query "$query" "$variables")
    fi

    # Apply output format
    case "$FORMAT" in
        raw)
            echo "$result"
            ;;
        safe|*)
            format_user_single "$result"
            ;;
    esac
}

# Main routing
action="${1:-help}"
shift || true

case "$action" in
    list)
        list_users "$@"
        ;;
    get)
        if [ -z "${1:-}" ]; then
            echo '{"error": "Usage: users.sh get <id-or-name|me>"}' >&2
            exit 1
        fi
        get_user "$@"
        ;;
    me)
        get_user "me" "${@}"
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        echo "Error: Unknown action '$action'" >&2
        echo "Run 'users.sh --help' for usage." >&2
        exit 1
        ;;
esac
