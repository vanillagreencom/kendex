#!/usr/bin/env bash
# The fake reducer for the watch_reads rows: it answers one `pr-watch.sh`
# run from the JSON map at $PR_WATCH_FAKE_REPLIES, keyed by the repository
# the caller named in GH_REPO ({REPO: {exit?, stdout?, stderr?}}; `unset`
# where GH_REPO is not in its environment), and appends `GH_REPO=<value>
# argv=[<args>]` to $PR_WATCH_FAKE_LOG on every call, so a row proves the
# variable reached the child and the reducer took no flag. A repository
# with no entry is the reducer's global failure (exit 2, stderr alone). With
# the two names unset, the map and the log are `pr-watch.json` and
# `pr-watch.log` beside the path this was invoked as (the rows symlink the
# fixture into their world as `pr-watch`).
set -u
here="$(dirname "${BASH_SOURCE[0]}")"
: "${PR_WATCH_FAKE_REPLIES:=$here/pr-watch.json}"
: "${PR_WATCH_FAKE_LOG:=$here/pr-watch.log}"
repo="${GH_REPO-unset}"
printf 'GH_REPO=%s argv=[%s]\n' "$repo" "$*" >> "$PR_WATCH_FAKE_LOG"
reply=$(jq -c --arg k "$repo" '.[$k] // empty' -- "$PR_WATCH_FAKE_REPLIES") || { echo "pr-watch-fake: replies-unreadable" >&2; exit 65; }
if [ -z "$reply" ]; then
  printf 'review-gate-error=E_REDUCER_AUTH value=%s\nNo reply for this repository.\n' "$repo" >&2
  exit 2
fi
jq -rj '.stdout // empty' <<<"$reply"
jq -rj '.stderr // empty' <<<"$reply" >&2
exit "$(jq -r '.exit // 0' <<<"$reply")"
