# shellcheck shell=bash
# The fleet App login used by refresh review and reading-worker results.
# Orch reads this literal assignment as data.
FLEET_APP_LOGIN='vanillagreen-fleet-lanes[bot]'

# The watcher validates its GitHub response before evaluating this rule.
REFRESH_IDENTITY_JQ='.head.ref == "kendex/refresh"
  and .user.login == "'"$FLEET_APP_LOGIN"'" and .user.type == "Bot"'
