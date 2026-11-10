# shellcheck shell=bash
# The native probe's reading of an agent-runtime `process live` or `process
# identity` reply: the reply's `result` is the whole tagged
# reading, `{"reading":"live",...}`, `{"reading":"gone"}` or
# `{"reading":"unreadable","cause":...}`. Sourced by thin-path.sh and by the
# integration row that feeds the binary's own replies through it.

# The one jq expression over a reply: the reading word and the cause an
# unreadable reading carries. A reply with no reading (a refusal, an empty
# answer) reads `unread`.
PROCESS_READING_JQ='{reading: (.result.reading // "unread"), cause: (.result.cause // null)}'

# process_reading: stdin the reply (or nothing); stdout one JSON object
# `{"reading": <word>, "cause": <text or null>}`.
process_reading() {
  jq -c --slurp "(.[0] // {}) | $PROCESS_READING_JQ"
}

# identity_start: stdin a `process identity` reply; stdout the start of a
# live identity, nothing for any other reading.
identity_start() {
  jq -r --slurp '(.[0] // {}) | select(.result.reading == "live") | .result.start'
}
