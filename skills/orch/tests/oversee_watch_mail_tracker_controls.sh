#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
exec "$BASH" "$(dirname "${BASH_SOURCE[0]}")/oversee_watch_mail.sh" tracker_controls
