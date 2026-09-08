#!/usr/bin/env bash
# Observe message records and command data. Explanation is not an assertion.
message_records() {
  awk '
    function reject_unkeyed() {
      print unkeyed
      rejected = 1
      exit 2
    }
    /^worktree-help:/ {
      if (before_record && !record_seen) reject_unkeyed()
      print
      record_seen = 1
      help = 1
      next
    }
    help { next }
    /^[[:space:]]+worktree-[a-z][a-z-]*:/ {
      unkeyed = $0
      reject_unkeyed()
    }
    /^worktree-[a-z][a-z-]*:/ {
      if (before_record && !record_seen) reject_unkeyed()
      print
      record_seen = 1
      next
    }
    /^rebase-map: / || /^\// || /^(true|false)$/ || /^\{/ { print; next }
    NF && !record_seen {
      unkeyed = unkeyed (unkeyed ? ORS : "") $0
      before_record = 1
    }
    END {
      if (!rejected && before_record && !record_seen) reject_unkeyed()
    }
  '
}
