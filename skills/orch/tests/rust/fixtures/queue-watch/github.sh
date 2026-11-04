#!/usr/bin/env bash
# The fake github.sh for the queue-watch rows: `pr-threads N --unresolved`
# answers from `github.json` beside the path this was invoked as, keyed
# `pr-threads N`: `{exit?, body?, text?}`, `body` printed as JSON, `text` as
# raw bytes, `exit` the status, 0 when absent; a key with no entry is a
# failed call (exit 1 with a keyed line, as the real command refuses a pull
# request it cannot read). `merge-queue-mutation` runs the github package's
# own command with the fake `gh` beside this path first on PATH. Every call
# appends its argv and the GH_REPO it carried to `github.log` there.
set -u
here="$(dirname "${BASH_SOURCE[0]}")"
printf 'GH_REPO=%s %s\n' "${GH_REPO-unset}" "$*" >> "$here/github.log"
if [ "${1:-}" = merge-queue-mutation ]; then
  shift
  real="$(readlink -f "${BASH_SOURCE[0]}")"
  PATH="$(cd "$here" && pwd):$PATH" exec bash \
    "$(dirname "$real")/../../../../../github/scripts/commands/merge-queue-mutation.sh" "$@"
fi
key="${1:-} ${2:-}"
reply=$(jq -c --arg k "$key" '.[$k] // empty' -- "$here/github.json" 2>/dev/null) || reply=""
if [ -z "$reply" ]; then
  printf 'github: pr-threads-unreadable key=[%s]\n' "$key" >&2
  exit 1
fi
if jq -e 'has("text")' <<<"$reply" >/dev/null; then
  jq -rj '.text' <<<"$reply"
elif jq -e 'has("body")' <<<"$reply" >/dev/null; then
  jq -c '.body' <<<"$reply"
fi
exit "$(jq -r '.exit // 0' <<<"$reply")"
