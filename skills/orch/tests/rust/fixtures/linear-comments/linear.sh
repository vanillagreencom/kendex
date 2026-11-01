#!/bin/bash
# The linear package's CLI as the acceptance rows see it (U6c, U6j): every
# call is appended to $LINEAR_LOG. `comments list ITEM` answers
# $LINEAR_COMMENTS, a list in the CLI's safe shape (`[]` unset), and exits
# $LINEAR_LIST_STATUS, 0 when unset, answering nothing then. `comments
# create ITEM --body-file F` and `comments update ID --body-file F` are each
# followed in the log by a `body` line with the file's first line, and
# answered in the CLI's own shape (`commands/comments.sh`,
# `normalize_mutation_response`): the comment's id is $LINEAR_COMMENT_ID,
# `cmt-1` unset, on a create and the given id on an update. With
# $LINEAR_SNAPSHOT set, the state file $LINEAR_STATE names is copied there at
# the first post and never a later one: what the record held when the
# comment first went out. Exits with $LINEAR_STATUS, 0 when unset, answering
# nothing then. Any other verb is refused.
verb="${1:-}" action="${2:-}" target="${3:-}"
[ -z "${LINEAR_LOG:-}" ] || printf '%s\n' "$*" >> "$LINEAR_LOG"
case "$verb $action" in
  'comments list')
    if [ "${LINEAR_LIST_STATUS:-0}" -ne 0 ]; then
      echo '{"error": "linear-comments: list refused"}' >&2
      exit "$LINEAR_LIST_STATUS"
    fi
    printf '%s\n' "${LINEAR_COMMENTS:-[]}"
    exit 0 ;;
  'comments create' | 'comments update') ;;
  *) echo "linear-comments: verb=$verb $action" >&2; exit 2 ;;
esac
[ $# -lt 3 ] || shift 3
file=""
while [ $# -gt 0 ]; do
  case "$1" in --body-file) file="${2:-}"; shift ;; esac
  shift
done
[ -z "${LINEAR_LOG:-}" ] || [ -z "$file" ] || { printf 'body '; sed -n 1p -- "$file"; } >> "$LINEAR_LOG"
[ -z "${LINEAR_SNAPSHOT:-}" ] || [ -e "$LINEAR_SNAPSHOT" ] || cp -- "${LINEAR_STATE:?}" "$LINEAR_SNAPSHOT"
if [ "${LINEAR_STATUS:-0}" -ne 0 ]; then
  echo '{"error": "linear-comments: refused"}' >&2
  exit "$LINEAR_STATUS"
fi
id="$target"
[ "$action" != create ] || id="${LINEAR_COMMENT_ID:-cmt-1}"
printf '{"success": true, "identifier": null, "url": null, "data": {"success": true, "comment": {"id": "%s", "body": ""}}}\n' "$id"
