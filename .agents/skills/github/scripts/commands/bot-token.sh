#!/bin/bash
# Check bot token configuration
# Usage: bot-token [--format=safe|text]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared library for load_bot_token (also sets PROJECT_ROOT)
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/github-api.sh"

show_help() {
    cat << 'EOF'
Check bot token configuration

Usage: bot-token [options]

Options:
  --format=safe   JSON output (default): {"configured": true, "valid": true, "source": "GH_TOKEN"}
  --format=text   Human-readable text: "configured (GH_TOKEN)" or "not configured"

Checks whether the bot token ladder selects a valid token from the environment
or project config/secrets, and names the variable it selected as the source.
Supports direct tokens (ghp_*, gho_*, etc.) and 1Password references (op://...).

Examples:
  github.sh bot-token               # JSON: {"configured": true, "valid": true, "source": "GH_BOT_TOKEN"}
  github.sh bot-token --format=text # Text: "configured (GH_BOT_TOKEN)"
EOF
}

main() {
    local format="safe"

    while [ $# -gt 0 ]; do
        case "$1" in
            --format=*) format="${1#--format=}"; shift ;;
            --help|-h) show_help; exit 0 ;;
            *) echo "Unknown option: $1" >&2; exit 1 ;;
        esac
    done

    # Use shared check_bot_token function
    check_bot_token "$format"
}

main "$@"
