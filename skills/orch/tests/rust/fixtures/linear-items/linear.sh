#!/usr/bin/env bash
# The fake linear CLI for the admission rows: it answers
# `issues get ID --with-bundle --format=safe`, the one read the admission
# makes, with the JSON at $LINEAR_ITEMS_DIR/ID.json, the shape the real
# CLI's `format_issue_with_bundle` prints (description, labels, children,
# in_pr_bundle among its fields). An item with no file is a failed read
# (exit 1 with a keyed line on stderr), as the CLI exits on a refused
# request; any other verb is refused the same way. Every call appends its
# arguments to $LINEAR_FAKE_LOG, one line each, so a row can assert what
# was read and what was not.
set -u
printf '%s\n' "$*" >> "${LINEAR_FAKE_LOG:?}"
if [ "${1:-} ${2:-} ${4:-} ${5:-}" != "issues get --with-bundle --format=safe" ]; then
  echo "linear-items: unexpected-call args=[$*]" >&2
  exit 1
fi
file="${LINEAR_ITEMS_DIR:?}/$3.json"
if [ ! -r "$file" ]; then
  echo "linear-items: issue-unknown id=$3" >&2
  exit 1
fi
cat -- "$file"
