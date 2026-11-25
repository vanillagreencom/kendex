#!/usr/bin/env bash
# The fake linear CLI for the watch_reads rows. It answers each read from
# the JSON map at $LINEAR_FAKE_REPLIES, keyed by the verb words joined by a
# space ("statuses list", "issues list", "issues list --assignee", "issues
# update", "issues bulk-get", "comments bulk-list"), a `graphql --query DOC`
# read by `graphql` and the document's operation name ("graphql OwnerItem"):
# {exit?, body?, text?, stderr?}. `body` is printed as JSON,
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
# between fork and exec (ETXTBSY). Every `comments create` also appends
# {issue, parent, body, args} as one JSON line to $LINEAR_FAKE_COMMENTS,
# `linear-comments.jsonl` beside the log by default, its body whole from
# --body or from the file --body-file names, which the runtime removes
# with its run directory once the call returns.
set -u
here="$(dirname "${BASH_SOURCE[0]}")"
if [ "${0##*/}" = curl ]; then
  config=$(cat) || exit 65
  payload=$(sed -n 's/^data = //p' <<<"$config" | jq -r) || exit 65
  cursor=$(jq -r '.variables.after // ""' <<<"$payload") || exit 65
  case "$cursor" in
    '') page=first ;;
    child-next) page=second ;;
    *) exit 65 ;;
  esac
  printf '%s\n' "$page" >>"$LINEAR_PAGE_LOG"
  jq -cj --arg page "$page" '{data: {issue: .[$page]}}' -- "$LINEAR_PAGE_REPLIES" || exit 65
  printf '___HTTP_CODE___200'
  exit 0
fi
: "${LINEAR_FAKE_REPLIES:=$here/linear.json}"
: "${LINEAR_FAKE_LOG:=$here/linear.log}"
printf '%s\n' "$*" >> "$LINEAR_FAKE_LOG"
: "${LINEAR_FAKE_COMMENTS:=$(dirname "$LINEAR_FAKE_LOG")/linear-comments.jsonl}"
fake_comment() {
  local issue="$3" parent="" body="" file=""
  local args=("$@")
  shift 3
  while [ $# -gt 0 ]; do
    case "$1" in
      --parent) parent="${2:-}"; shift ;;
      --body) body="${2:-}"; shift ;;
      --body-file) file="${2:-}"; shift ;;
    esac
    shift
  done
  if [ -n "$file" ]; then
    jq -cn --arg issue "$issue" --arg parent "$parent" --rawfile body "$file" --args \
      '{issue: $issue, parent: $parent, body: $body, args: $ARGS.positional}' -- "${args[@]}"
  else
    jq -cn --arg issue "$issue" --arg parent "$parent" --arg body "$body" --args \
      '{issue: $issue, parent: $parent, body: $body, args: $ARGS.positional}' -- "${args[@]}"
  fi >> "$LINEAR_FAKE_COMMENTS"
}
if [ "${1:-} ${2:-}" = 'comments create' ] && [ $# -ge 3 ]; then
  fake_comment "$@" || { echo "linear-fake: comment-unrecorded" >&2; exit 65; }
fi
if [ -n "${LINEAR_PAGE_REPLIES:-}" ] &&
   { [ "${1:-}" = graphql ] || [ "${1:-} ${2:-}" = 'issues get' ]; }; then
  {
    curl_path=$(command -v curl) || exit 65
    if [ "$curl_path" != "$here/bin/curl" ]; then
      printf 'linear-fake: curl outside fixture: %s\n' "$curl_path" >&2
      exit 65
    fi
    source_path=$(readlink -f "${BASH_SOURCE[0]}") || exit 65
    source_dir=$(dirname -- "$source_path") || exit 65
    cd -- "$here/checkout" || exit 65
    exec "$source_dir/../../../../../linear/scripts/linear.sh" "$@"
  } 2>"$here/pages.err"
fi
if [ "${1:-}" = done-when ]; then
  real="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../../../../linear/scripts" && pwd)/linear.sh"
  exec "$real" "$@"
fi
key="${1:-} ${2:-}"
if [ "${1:-}" = graphql ]; then
  [ "${2:-}" = --query ] && [[ "${3:-}" =~ ^query\ ([_A-Za-z][_A-Za-z0-9]*) ]] || { echo "linear-fake: unnamed graphql read" >&2; exit 64; }
  key="graphql ${BASH_REMATCH[1]}"
  # The repaired description the last `issues update` wrote, read back.
  if [ "$key" = 'graphql OwnerItem' ] && [ -f "$here/owner-repair.json" ]; then
    jq -c . "$here/owner-repair.json"
    exit 0
  fi
fi
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
