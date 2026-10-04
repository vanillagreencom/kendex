#!/usr/bin/env bash
# Mint application token JSON for a host that publishes LINEAR_APP_TOKEN.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
case "${1:-}" in
    --help|-h|help)
        cat <<'EOF'
Usage: auth-mint

Requires LINEAR_CLIENT_ID and LINEAR_CLIENT_SECRET (op:// supported).
Prints {"access_token": ..., "expires_at": ...} with expiry in epoch seconds.
Uses the fixed scope read,write,issues:create,comments:create,
timeSchedule:write,initiative:read,initiative:write,customer:read,
customer:write. Writes no files and ignores other credentials.
EOF
        exit 0 ;;
    '') ;;
    *) echo '{"error":"linear-auth: mint=unknown-option. Run auth-mint --help."}' >&2; exit 1 ;;
esac
# Minting resolves only the pair, even when an unused token cannot resolve.
export LINEAR_SKIP_API_KEY_RESOLUTION=1
source "$SCRIPT_DIR/../lib/common.sh"
linear_mint_token