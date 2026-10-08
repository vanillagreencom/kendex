# shellcheck shell=bash
# Both the watcher and review requester route the refresh branch by this
# identity. Each caller validates its GitHub response before evaluating it.
REFRESH_IDENTITY_JQ='.head.ref == "kendex/refresh"
  and .user.login == "vanillagreen-fleet-lanes[bot]" and .user.type == "Bot"'
