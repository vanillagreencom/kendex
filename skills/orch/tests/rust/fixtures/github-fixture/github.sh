#!/usr/bin/env bash
# The fake `github.sh` for the watch_report rows: `pr-timeline N --repo R`
# answers from `github.json` beside the path this was invoked as (the rows
# symlink the fixture into their world as `github.sh`), keyed `pr-timeline
# N R`: `{exit?, body?, text?}`, `body` printed as JSON, `text` as raw
# bytes, `exit` the status, 0 when absent; a key with no entry is a failed
# call (exit 1 with a keyed line, as the real program refuses a pull
# request it cannot read). Every call appends its argv to `github.log`
# there.
set -u
here="$(dirname "${BASH_SOURCE[0]}")"
printf '%s\n' "$*" >> "$here/github.log"
verb="${1:-}" number="${2:-}" repo=""
shift 2 2>/dev/null || true
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) repo="$2"; shift ;;
  esac
  shift
done
key="$verb $number $repo"
reply=$(jq -c --arg k "$key" '.[$k] // empty' -- "$here/github.json" 2>/dev/null) || reply=""
if [ -z "$reply" ]; then
  printf 'github: pr-timeline-unreadable key=[%s]\n' "$key" >&2
  exit 1
fi
if jq -e 'has("text")' <<<"$reply" >/dev/null; then
  jq -rj '.text' <<<"$reply"
elif jq -e 'has("body")' <<<"$reply" >/dev/null; then
  jq -c '.body' <<<"$reply"
fi
exit "$(jq -r '.exit // 0' <<<"$reply")"
