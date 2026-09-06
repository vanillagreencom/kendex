#!/usr/bin/env bash
# This repository's committed taxonomy must declare `surface` REQUIRED and
# EXCLUSIVE over its seven names. That declaration is the whole mechanism:
# the label preflight in skills/project-management/references/labels.md
# § Validation refuses a create whose final label set carries no surface only
# while the project says surface is required, and it is the surface label that
# sorts app work from package work. Soften the category to optional and
# nothing else in the repo notices — every bare create passes preflight again
# and the unsorted rust-core issues KEN-1057 backfilled start regrowing.
#
# TWO documents are read, because the declaration lives in two places and
# nothing else binds them. kendex-local.toml is what `kendex apply`/`refresh`
# installs from; .agents/skills/project-management/SKILL.md is the render a
# session actually loads. tools/guard's render rule has case arms for
# skills/*, agents/*.md and hooks/* only, so a manifest-only edit owes no
# render, and no CI step re-renders or runs `kendex verify`. Judging one
# alone fails open in that direction: a softened manifest with a stale render
# would pass on the render, and a strengthened render with an untouched
# manifest would be reverted by the next refresh. So the predicate is asked
# of the manifest, and the render is asked to carry the identical text.
#
# Lives under tools/tests/, not skills/project-management/tests/: that suite
# ships with the skill to other projects, and each declares its own taxonomy;
# this policy is kendex's alone. tools/tests is also what keeps the check
# merge-blocking — the rest shard globs tools/tests/*.test.sh into the
# required "Skill suites (shell + node)" context.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
MANIFEST="$REPO_ROOT/kendex-local.toml"
RENDER="$REPO_ROOT/.agents/skills/project-management/SKILL.md"

SURFACES='["app","cli","skills","harness","ci-infra","docs","releases"]'

PASS=0
FAIL=0
ok() {
  PASS=$((PASS + 1))
  printf '  ok    %s\n' "$1"
}
bad() {
  FAIL=$((FAIL + 1))
  printf '  FAIL  %s\n' "$1"
  [ $# -lt 2 ] || printf '        %s\n' "$2"
}

# The json the taxonomy is declared in, taken out of either document the way
# a reader takes it: the first fenced json block under the heading. The
# manifest carries the same text verbatim inside its TOML literal string, so
# one extractor serves both and no TOML parser is needed. The closing fence is
# matched at the start of the line, not whole: in the manifest the TOML
# string's own closing delimiter follows it on the same line.
taxonomy_json() {
  awk '
    /^### Project taxonomy$/ { seen = 1; next }
    seen && /^```json$/      { inside = 1; next }
    inside && /^```/         { exit }
    inside                   { print }
  ' "$1"
}

# The one predicate, asked of a taxonomy document on stdin: surface is a
# required category, and it admits exactly one of exactly these names. Both
# the control and its must-fail go through this filter, so a green control
# cannot mean a filter that says yes to anything.
predicate='
  (.required_categories_for_new_issues // []) as $req
  | (.categories.surface // {}) as $surface
  | (($req | index("surface")) != null)
    and $surface.required == true
    and $surface.exclusive == true
    and (($surface.labels // []) | sort) == ($surfaces | sort)
'

declared="$(taxonomy_json "$MANIFEST")"
rendered="$(taxonomy_json "$RENDER")"
if [ -z "$declared" ]; then
  bad "kendex-local.toml declares a § Project taxonomy json block" "none found in $MANIFEST"
  printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
  exit 1
fi

if printf '%s' "$declared" | jq -e --argjson surfaces "$SURFACES" "$predicate" >/dev/null; then
  ok "declared taxonomy requires exactly one surface from $SURFACES"
else
  bad "declared taxonomy requires exactly one surface from $SURFACES" \
    "$(printf '%s' "$declared" | jq -c '.categories.surface // "no surface category"')"
fi

if [ "$declared" = "$rendered" ]; then
  ok "the rendered skill carries the declared taxonomy verbatim"
else
  bad "the rendered skill carries the declared taxonomy verbatim" \
    "$(diff <(printf '%s\n' "$declared") <(printf '%s\n' "$rendered") | head -20 | tr '\n' ' ')"
fi

# Must-fail: the same document without the surface category — this
# repository's state before KEN-1057, and the exact regression the control
# exists to catch. The predicate must reject it.
without_surface="$(printf '%s' "$declared" |
  jq 'del(.categories.surface) | .required_categories_for_new_issues -= ["surface"]')"
if printf '%s' "$without_surface" | jq -e --argjson surfaces "$SURFACES" "$predicate" >/dev/null; then
  bad "a taxonomy with no surface category is rejected" "the predicate accepted it"
else
  ok "a taxonomy with no surface category is rejected"
fi

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
