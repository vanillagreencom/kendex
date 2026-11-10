#!/usr/bin/env bash
# The fake linear CLI for the watch_reads rows. It answers each read from
# the JSON map at $LINEAR_FAKE_REPLIES, keyed by the verb words joined by a
# space ("statuses list", "issues list", "issues list --assignee", "issues
# update", "issues bulk-get", "comments bulk-list"): {exit?, body?, text?,
# stderr?}. `body` is printed as JSON,
# `text` as raw bytes, `stderr` to stderr, `exit` is the status, 0 when
# absent; a key with no entry is a failed call (exit 1, as the CLI exits on
# a refused request). A `done-when` read is the real linear CLI's own,
# which parses a description and reads nothing, so the row
# proves the runtime through the parser it ships with. Every call appends
# its arguments to $LINEAR_FAKE_LOG, one line each, so a row can assert
# what was read, in what batches, and what was not. With the two names
# unset, the map and the log are `linear.json` and `linear.log` beside the
# path this was invoked as: a row symlinks the fixture into its own world
# under that name, so no wrapper is written while another row's child is
# between fork and exec (ETXTBSY).
set -u
here="$(dirname "${BASH_SOURCE[0]}")"
: "${LINEAR_FAKE_REPLIES:=$here/linear.json}"
: "${LINEAR_FAKE_LOG:=$here/linear.log}"
printf '%s\n' "$*" >> "$LINEAR_FAKE_LOG"
if [ "${1:-} ${2:-}" = 'issues get' ] && [ -f "$here/owner-repair.json" ]; then
  real="$(python3 -B -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).resolve().parents[5] / "linear/scripts")' "${BASH_SOURCE[0]}")"
  source "$real/lib/formatters.sh"
  format_issue_single "$(cat "$here/owner-repair.json")"
  exit 0
fi
if [ "${1:-}" = done-when ]; then
  real="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../../../../linear/scripts" && pwd)/linear.sh"
  exec "$real" "$@"
fi
key="${1:-} ${2:-}"
# The owner-tracker read's `issues list --assignee …` is keyed apart from
# the team's open-items list, which shares its first two words.
[ "${3:-}" != --assignee ] || key="issues list --assignee"
reply=$(jq -c --arg k "$key" '.[$k] // empty' -- "$LINEAR_FAKE_REPLIES") || { echo "linear-fake: replies-unreadable" >&2; exit 65; }
if [ -z "$reply" ]; then
  echo "linear-fake: no reply for [$key]" >&2
  exit 1
fi
jq -r '.stderr // empty' <<<"$reply" >&2
if [ "$key" = 'issues update' ] && [ "${4:-}" = --description ] && [ "$(jq -r '.exit // 0' <<<"$reply")" = 0 ]; then
  jq -cn --arg id "$3" --arg d "$5" '{issue:{identifier:$id,description:$d}}' >"$here/owner-repair.json"
fi
if jq -e 'has("text")' <<<"$reply" >/dev/null; then
  jq -rj '.text' <<<"$reply"
elif jq -e 'has("body")' <<<"$reply" >/dev/null; then
  jq -c '.body' <<<"$reply"
fi
exit "$(jq -r '.exit // 0' <<<"$reply")"
