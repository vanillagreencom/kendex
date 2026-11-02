#!/bin/bash
# The linear package's CLI as the acceptance rows see it (U6c, U6j, U7e):
# every call is appended to $LINEAR_LOG. `comments list ITEM` answers
# $LINEAR_COMMENTS, a list in the CLI's safe shape (`[]` unset), with
# $LINEAR_COMMENTS_MORE, a second page, appended to it where set, as the CLI
# merges every page before it renders; it exits $LINEAR_LIST_STATUS, 0 when
# unset, answering nothing then. `comments create ITEM --body-file F
# [--attach P]...` and `comments update ID --body-file F` are each followed
# in the log by a `body` line with the file's first line and one `link` line
# per whole-line markdown link in the file, and answered in the CLI's own
# shape (`commands/comments.sh`, `normalize_mutation_response`): the
# comment's id is $LINEAR_COMMENT_ID, `cmt-1` unset, on a create and the
# given id on an update; the body is the file's, with one
# `![NAME](https://uploads.linear.app/fixture/NAME)` paragraph appended per
# `--attach` on a create, as the CLI appends each upload's link. With
# $LINEAR_SNAPSHOT set, the state file $LINEAR_STATE names is copied there at
# the first post and never a later one: what the record held when the
# comment first went out. With $LINEAR_KILL naming the action (`create`),
# the fixture ends its caller, the runtime, with KILL after logging and
# before answering: the tracker took the post and the runtime never read
# the answer. Exits with $LINEAR_STATUS, 0 when unset, answering nothing
# then. Any other verb is refused.
verb="${1:-}" action="${2:-}" target="${3:-}"
[ -z "${LINEAR_LOG:-}" ] || printf '%s\n' "$*" >> "$LINEAR_LOG"
case "$verb $action" in
  'comments list')
    if [ "${LINEAR_LIST_STATUS:-0}" -ne 0 ]; then
      echo '{"error": "linear-comments: list refused"}' >&2
      exit "$LINEAR_LIST_STATUS"
    fi
    if [ -n "${LINEAR_COMMENTS_MORE:-}" ]; then
      printf '%s\n%s\n' "${LINEAR_COMMENTS:-[]}" "$LINEAR_COMMENTS_MORE" | jq -cs '.[0] + .[1]'
    else
      printf '%s\n' "${LINEAR_COMMENTS:-[]}"
    fi
    exit 0 ;;
  'comments create' | 'comments update') ;;
  *) echo "linear-comments: verb=$verb $action" >&2; exit 2 ;;
esac
[ $# -lt 3 ] || shift 3
file="" links=""
while [ $# -gt 0 ]; do
  case "$1" in
    --body-file) file="${2:-}"; shift ;;
    --attach)
      name="$(basename -- "${2:-}")"
      links="$links

![$name](https://uploads.linear.app/fixture/$name)"
      shift ;;
  esac
  shift
done
if [ -n "${LINEAR_LOG:-}" ] && [ -n "$file" ]; then
  { printf 'body '; sed -n 1p -- "$file"; } >> "$LINEAR_LOG"
  grep -E '^!?\[[^]]*\]\([^)]*\)$' -- "$file" | sed 's/^/link /' >> "$LINEAR_LOG"
fi
[ -z "${LINEAR_SNAPSHOT:-}" ] || [ -e "$LINEAR_SNAPSHOT" ] || cp -- "${LINEAR_STATE:?}" "$LINEAR_SNAPSHOT"
if [ "${LINEAR_KILL:-}" = "$action" ]; then
  kill -KILL "$PPID"
  exit 1
fi
if [ "${LINEAR_STATUS:-0}" -ne 0 ]; then
  echo '{"error": "linear-comments: refused"}' >&2
  exit "$LINEAR_STATUS"
fi
id="$target"
[ "$action" != create ] || id="${LINEAR_COMMENT_ID:-cmt-1}"
body=""
[ -z "$file" ] || body="$(cat -- "$file")"
[ "$action" != create ] || body="$body$links"
printf '{"success": true, "identifier": null, "url": null, "data": {"success": true, "comment": {"id": "%s", "body": %s}}}\n' \
  "$id" "$(printf '%s' "$body" | jq -Rs .)"
