#!/usr/bin/env bash
# `graphql_query` refuses a write when no team target resolves, and it decides
# what a write is with `linear_query_is_mutation`, which reads the document's
# leading token. That classifier is only as good as the shape of the documents
# in this skill: one that buried its operation behind a leading fragment or a
# comment would be posted as a read and skip the guard entirely.
#
# This lint holds that precondition. Every GraphQL document literal in scripts/
# must start with its operation keyword, and must classify the way its operation
# says it should.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPTS="$SKILL_DIR/scripts"

# Load the classifier without running any command script.
eval "$(sed -n '/^linear_query_is_mutation()/,/^}/p' "$SCRIPTS/lib/common.sh")"

if ! declare -F linear_query_is_mutation >/dev/null 2>&1; then
  assert_stop "linear_query_is_mutation loads from lib/common.sh"
fi

checked=0

classify_expect() {
  # Reference classification, independent of the implementation: the first
  # non-space, non-comment token of the document.
  awk '
    { sub(/\r$/, "") }
    /^[[:space:]]*$/ { next }
    /^[[:space:]]*#/ { next }
    { sub(/^[[:space:]]+/, ""); print $1; exit }
  '
}

check_document() {
  local origin="$1"
  local doc="$2"

  # Only GraphQL documents; skip shell strings that merely mention the words.
  case "$doc" in
  *"{"*) ;;
  *) return 0 ;;
  esac

  # Does the document carry a mutation operation anywhere, leading or not?
  local has_mutation=0
  if printf '%s' "$doc" | grep -Eq '(^|[^A-Za-z0-9_])mutation[[:space:]({]'; then
    has_mutation=1
  fi

  local first
  first="$(printf '%s\n' "$doc" | classify_expect)"
  case "$first" in
  query* | mutation* | fragment* | "{"*) ;;
  *)
    # Not a GraphQL document unless it hides an operation inside.
    [ "$has_mutation" -eq 1 ] || return 0
    ;;
  esac

  checked=$((checked + 1))

  local got="read"
  if linear_query_is_mutation "$doc"; then
    got="write"
  fi

  # The property: the classifier is true iff the document performs a write.
  # A mutation the classifier calls a read is posted with no team guard at all.
  local want="read"
  [ "$has_mutation" -eq 1 ] && want="write"

  # A mutation the classifier calls a read is posted with no team guard at all;
  # put the mutation keyword first.
  # The origin rides the compared values rather than the description, so the
  # description a control names is one exact line and not a prefix of one that
  # moves with labels.sh.
  assert_eq "every document classifies as its operation" "$origin: $got" "$origin: $want"
}

# Extract every single-quoted document literal. Command scripts assign GraphQL
# to `query='...'` / `mutation='...'` / `local query='...'` and to *_query vars;
# the double-quoted ones are built by interpolation and are covered by the
# runtime assertions in team-target-fail-closed.test.sh.
while IFS= read -r script; do
  rel="${script#"$SKILL_DIR/"}"
  # shellcheck disable=SC2016
  docs="$(awk -v origin="$rel" '
    # Start of a single-quoted assignment whose value looks like GraphQL.
    !collecting && $0 ~ /^[[:space:]]*(local[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=\x27/ {
      line = $0
      sub(/^[[:space:]]*(local[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=\x27/, "", line)
      if (line ~ /\x27/) {
        sub(/\x27.*$/, "", line)
        printf "%s\t%s\n", NR, line
        next
      }
      collecting = 1
      start = NR
      buf = line
      next
    }
    collecting {
      if ($0 ~ /\x27/) {
        line = $0
        sub(/\x27.*$/, "", line)
        buf = buf " " line
        printf "%s\t%s\n", start, buf
        collecting = 0
        buf = ""
        next
      }
      buf = buf " " $0
    }
  ' "$script")"

  while IFS=$'\t' read -r lineno doc; do
    [ -n "${doc:-}" ] || continue
    check_document "$rel:$lineno" "$doc"
  done <<<"$docs"
done < <(find "$SCRIPTS" -name '*.sh' -type f | sort)

# The classifier itself must hold for the shapes the lint is protecting against.
assert_class() {
  local expect="$1" doc="$2" label="$3"
  local got="read"
  if linear_query_is_mutation "$doc"; then
    got="write"
  fi
  assert_eq "the classifier reads $label as a $expect" "$got" "$expect"
}

assert_class write '
    mutation CreateIssue($input: IssueCreateInput!) { issueCreate(input: $input) { success } }' "leading-newline mutation"
assert_class write 'mutation{ x }' "brace-attached mutation"
assert_class write '   mutation	Tabbed { x }' "tab-separated mutation"
assert_class read 'query GetTeam($name: String!) { teams { nodes { id } } }' "query"
assert_class read '{ viewer { id } }' "shorthand query"
assert_class read 'mutationLike { x }' "identifier starting with mutation"

assert_ne "the extractor still finds GraphQL documents to check" "$checked" 0
