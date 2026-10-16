# shellcheck shell=bash
# The watcher uses this refresh identity for its review route. It validates
# its GitHub response before evaluating the identity.
REFRESH_IDENTITY_JQ='.head.ref == "kendex/refresh"
  and .user.login == "vanillagreen-fleet-lanes[bot]" and .user.type == "Bot"'
