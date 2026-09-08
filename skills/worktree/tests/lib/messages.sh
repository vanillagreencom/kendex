#!/usr/bin/env bash
# Observe message records and command data. Explanation is not an assertion.
message_records() {
  awk '
    /^worktree-help:/ {
      if (before_record && !record_seen) exit 2
      print
      record_seen = 1
      help = 1
      next
    }
    help { next }
    /^[[:space:]]+worktree-[a-z][a-z-]*:/ { exit 2 }
    /^worktree-[a-z][a-z-]*:/ {
      if (before_record && !record_seen) exit 2
      print
      record_seen = 1
      next
    }
    /^rebase-map: / || /^\// || /^(true|false)$/ || /^\{/ { print; next }
    NF && !record_seen { before_record = 1 }
  '
}
