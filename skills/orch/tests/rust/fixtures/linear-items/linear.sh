#!/usr/bin/env bash
# The linear CLI's stand-in for the admission rows: it answers
# `issues get ID --format=safe`, the item read the admission
# makes, by running the package's real bundle formatter
# (`format_issue_with_bundle` of the `lib/formatters.sh` that
# $LINEAR_FORMATTERS names) over the GraphQL-shaped answer planted at
# $LINEAR_ITEMS_DIR/ID.json, so every reply is what the CLI prints over that
# answer; and `teams get TEAM --format=safe`, the team read, by running
# `format_team_single` over the answer planted at
# $LINEAR_ITEMS_DIR/team-TEAM.json. An item or team with no file is a
# failed read (exit 1 with a keyed line on stderr), as the CLI exits on a
# reference the API does not answer; any other verb is refused the same
# way. A file ID.released.json is served as it stands: the reply a linear
# package whose bundle formatter names no launch blockers printed, planted
# as such by the row that needs it. Every call appends its arguments to
# $LINEAR_FAKE_LOG, one line each, so a row can assert what was read and
# what was not.
set -u
printf '%s\n' "$*" >> "${LINEAR_FAKE_LOG:?}"
if [ "${1:-} ${2:-} ${4:-}" = "teams get --format=safe" ]; then
  file="${LINEAR_ITEMS_DIR:?}/team-$3.json"
  if [ ! -r "$file" ]; then
    echo "linear-items: team-unknown team=$3" >&2
    exit 1
  fi
  # shellcheck source=/dev/null
  . "${LINEAR_FORMATTERS:?}"
  format_team_single "$(cat -- "$file")"
  exit
fi
if [ "${1:-} ${2:-} ${4:-} ${5:-}" != "issues get --format=safe " ]; then
  echo "linear-items: unexpected-call args=[$*]" >&2
  exit 1
fi
released="${LINEAR_ITEMS_DIR:?}/$3.released.json"
if [ -r "$released" ]; then
  cat -- "$released"
  exit 0
fi
file="${LINEAR_ITEMS_DIR:?}/$3.json"
if [ ! -r "$file" ]; then
  echo "linear-items: issue-unknown id=$3" >&2
  exit 1
fi
# shellcheck source=/dev/null
. "${LINEAR_FORMATTERS:?}"
format_issue_with_bundle "$(cat -- "$file")"
