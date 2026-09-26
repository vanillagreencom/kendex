#!/bin/bash
# The one writer of a command's `{"error": MESSAGE}` refusal on stderr.
# Callers read that stderr as JSON, and a message routinely carries a caller's
# argument, a path or API text holding quotes and backslashes, so jq builds
# the object; text interpolated into a JSON literal stops parsing on the
# first such character.

# github_error MESSAGE — print {"error": MESSAGE} as one compact line on stderr.
github_error() {
    jq -nc --arg msg "$1" '{error: $msg}' >&2
}
