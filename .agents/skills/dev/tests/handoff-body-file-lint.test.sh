#!/usr/bin/env bash
# Regression lint: reject multiline inline --body in dev workflow docs.
#
# A `linear.sh comments create ... --body "` whose opening quote does NOT close
# on the same physical line spills the message body across lines. When such a
# body contains a backticked CLI command, Bash evaluates the backticks before
# the comment is posted, producing a malformed comment (and running arbitrary
# commands). Multiline bodies must use the tmp-file + `--body-file` pattern.
#
# Rule (deterministic, per physical line): a line that contains both
# `comments create` and an inline `--body "` is flagged when the line has an
# odd number of `"` characters (unterminated quote => multiline body).
# Single-line `--body "short text"` (even quote count) and `--body-file` are
# allowed. Hermetic: scans files on disk only, no network.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOWS_DIR="$(cd "$SCRIPT_DIR/../workflows" && pwd)"

offenders=0

while IFS= read -r -d '' file; do
  lineno=0
  while IFS= read -r line; do
    lineno=$((lineno + 1))
    # Candidate: a `comments create` invocation with an inline `--body "…`.
    # `--body-file` has no `"` after it, so it never matches this pattern.
    case "$line" in
      *"comments create"*'--body "'*) ;;
      *) continue ;;
    esac
    # Strip every non-quote character; an odd count means the quote is
    # unterminated on this line => the body continues onto later lines.
    quotes="${line//[!\"]/}"
    if (( ${#quotes} % 2 == 1 )); then
      printf '%s:%d: multiline inline --body (use tmp file + --body-file)\n' "$file" "$lineno"
      offenders=$((offenders + 1))
    fi
  done < "$file"
done < <(find "$WORKFLOWS_DIR" -type f -name '*.md' -print0)

if (( offenders > 0 )); then
  echo "FAIL: $offenders multiline inline --body occurrence(s) found"
  exit 1
fi

echo "all pass"
