#!/usr/bin/env bash
# The wiring shapes are the deliverable a consumer copies, so they are checked
# rather than trusted: every workflow expression stays on one line, and the
# script path they name is the path this package ships.
set -euo pipefail
# shellcheck source=lib/sandbox.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/sandbox.sh"

WIRING="$TEST_DIR/../references/wiring.md"
[ -f "$WIRING" ] || { echo "missing $WIRING" >&2; exit 1; }

# Only the fenced yaml blocks, with the fences dropped.
yaml_lines() {
  awk '/^```yaml$/ { inblock = 1; next } /^```$/ { inblock = 0; next } inblock' "$WIRING"
}

blocks="$(yaml_lines)"
[ -n "$blocks" ] || { echo "no yaml blocks found in $WIRING" >&2; exit 1; }

# A folded scalar whose continuations are indented past its first line keeps
# the newlines instead of folding them, turning a wrapped expression into a
# multi-line one. One line per expression removes the trap outright.
unclosed="$(printf '%s\n' "$blocks" | grep -F '${{' | grep -vF '}}' || true)"
assert_eq "every workflow expression closes on its own line" "" "$unclosed"

# The path the shapes tell a consumer to run is the path this package ships.
# EVERY citation, not only the ones already ending in the script's name: a
# rename that reached one call site and not the rest has to fail here.
cited="$(printf '%s\n' "$blocks" | grep -oE '\.agents/skills/[A-Za-z0-9_/.-]+' | sort -u)"
assert_eq "the shapes name one script path" ".agents/skills/harness-ci/scripts/harness-only" "$cited"
assert_eq "that path is the one this package ships" "yes" \
  "$([ -x "$TEST_DIR/../scripts/harness-only" ] && echo yes || echo no)"

# Every flag the shapes pass is one the script accepts.
unknown_flags=""
for flag in $(printf '%s\n' "$blocks" | grep -oE '(^|[[:space:]])--[a-z-]+' | tr -d ' ' | sort -u); do
  case "$flag" in
    --event | --base | --head | --repo | --output) ;;
    *) unknown_flags="$unknown_flags $flag" ;;
  esac
done
assert_eq "the shapes pass only flags the script accepts" "" "$unknown_flags"

# The push endpoints come from the event payload, with `github.sha` LAST. On a
# branch-deletion push `github.event.after` is the all-zero sha and
# `github.sha` is the default branch tip, so a HEAD expression reaching
# `github.sha` before `after` would hand the classifier two real commits.
heads="$(printf '%s\n' "$blocks" | grep -F 'HEAD:' || true)"
assert_eq "the shapes carry a HEAD expression" "3" "$(printf '%s\n' "$heads" | grep -c 'HEAD:')"
misordered="$(printf '%s\n' "$heads" | grep -vE 'github\.event\.after[^|]*\|\|[^|]*github\.sha' || true)"
assert_eq "every HEAD expression tries github.event.after before github.sha" "" "$misordered"

# Indentation is checked structurally rather than by parsing: every block here
# steps by two spaces, so an odd indent or a tab is hand-edit damage. This
# needs no YAML library, which the shell shard does not install and this suite
# must not depend on being there — a check that cannot run must not be the
# difference between a green suite and a red one. What it does NOT prove is
# that a block is valid YAML; a malformed one fails at the copier's first
# workflow run, loudly, which is not the fail-closed concern this file guards.
TAB="$(printf '\t')"
odd="$(printf '%s\n' "$blocks" | grep -nE '^( {2})* [^ ]' || true)"
assert_eq "every block line steps by two spaces" "" "$odd"
tabbed="$(printf '%s\n' "$blocks" | grep -nE "^ *$TAB" || true)"
assert_eq "no block line indents with a tab" "" "$tabbed"

report wiring-shapes
