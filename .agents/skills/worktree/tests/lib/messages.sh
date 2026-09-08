#!/usr/bin/env bash
# Observe message records and command data. Explanation is not an assertion.
message_records() {
  awk '
    /^worktree-help:/ { print; help = 1; next }
    help { next }
    /^[[:space:]]*worktree-[a-z][a-z-]*:/ { sub(/^[[:space:]]*/, ""); print; next }
    /^rebase-map: / || /^\// || /^(true|false)$/ || /^\{/ { print }
  '
}
