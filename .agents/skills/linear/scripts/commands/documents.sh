#!/bin/bash
# Linear GraphQL API - Document Operations
# Usage: documents.sh <action> [options]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

show_help() {
    cat << 'EOF'
Document Operations

Usage: documents.sh <action> [options]

Actions:
  list    List documents
  get     Get a single document by ID

Common Options:
  --format=safe    Flat, normalized JSON (default)
  --format=raw     Original GraphQL structure

List Options:
  --project <name>      Filter by project name
  --limit <n>           Max results (default: 50)

Get:
  documents.sh get <id>

Examples:
  documents.sh list
  documents.sh list --project "Market Data Pipeline"
  documents.sh list --format=raw
  documents.sh get <document-id>
EOF
}

list_documents() {
    local filter_parts=()
    local first=75
    local format="${DEFAULT_FORMAT}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --format=*) format="${1#--format=}"; shift ;;
            --format) format="$2"; shift 2 ;;
            --project)
                filter_parts+=("\"project\": {\"name\": {\"eq\": \"$2\"}}")
                shift 2
                ;;
            --limit)
                first="$2"
                shift 2
                ;;
            --) shift; break ;;
            -*) echo "{\"error\": \"Unknown option: $1. Run --help for valid options.\"}" >&2; return 1 ;;
            *) break ;;
        esac
    done

    local filter_json
    if [ ${#filter_parts[@]} -gt 0 ]; then
        filter_json=$(IFS=,; echo "{${filter_parts[*]}}")
    else
        filter_json="{}"
    fi

    local query='
    query ListDocuments($filter: DocumentFilter, $first: Int) {
        documents(filter: $filter, first: $first) {
            nodes {
                id
                title
                content
                project { name }
                creator { name }
                createdAt
                updatedAt
            }
        }
    }'

    local variables="{\"filter\": $filter_json, \"first\": $first}"
    local result
    result=$(graphql_query "$query" "$variables")

    case "$format" in
        raw) echo "$result" ;;
        safe|*) format_documents_list "$result" ;;
    esac
}

get_document() {
    local doc_id=""
    local format="${DEFAULT_FORMAT}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --format=*) format="${1#--format=}"; shift ;;
            --format) format="$2"; shift 2 ;;
            -*) echo "{\"error\": \"Unknown option: $1. Run --help for valid options.\"}" >&2; return 1 ;;
            *) doc_id="$1"; shift ;;
        esac
    done

    if [ -z "$doc_id" ]; then
        echo '{"error": "Document ID required"}' >&2
        return 1
    fi

    local query='
    query GetDocument($id: String!) {
        document(id: $id) {
            id
            title
            content
            project { name }
            creator { name email }
            createdAt
            updatedAt
        }
    }'

    local variables="{\"id\": \"$doc_id\"}"
    local result
    result=$(graphql_query "$query" "$variables")

    case "$format" in
        raw) echo "$result" ;;
        safe|*) format_document_single "$result" ;;
    esac
}

# Main routing
action="${1:-help}"
shift || true

case "$action" in
    list)
        list_documents "$@"
        ;;
    get)
        get_document "$@"
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        echo "Error: Unknown action '$action'" >&2
        echo "Run 'documents.sh --help' for usage." >&2
        exit 1
        ;;
esac
