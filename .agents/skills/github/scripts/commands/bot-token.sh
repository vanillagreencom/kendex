#!/bin/bash
# Check bot token configuration
# Usage: bot-token [--json]

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
  --format=safe   JSON output (default): {"configured": true, "valid": true}
  --format=text   Human-readable text: "configured" or "not configured"
  --json          Alias for --format=safe (deprecated)

Checks if GH_BOT_TOKEN is configured and valid in project config/secrets.
Supports direct tokens (ghp_*, gho_*, etc.) and 1Password references (op://...).

Examples:
  github.sh bot-token               # JSON: {"configured": true, "valid": true}
  github.sh bot-token --format=text # Text: "configured"
EOF
}

main() {
    local format="safe"

    while [ $# -gt 0 ]; do
        case "$1" in
            --format=*) format="${1#--format=}"; shift ;;
            --json) format="safe"; shift ;;  # Deprecated alias
            --help|-h) show_help; exit 0 ;;
            *) echo "Unknown option: $1" >&2; exit 1 ;;
        esac
    done

    # Use shared check_bot_token function
    check_bot_token "$format"
}

main "$@"
