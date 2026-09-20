#!/usr/bin/env bash
# Docs-only accepts the explicit documentation set and rejects every other
# path. Pull-request and merge-group events use the shared endpoint rules.
set -euo pipefail
# shellcheck source=lib/sandbox.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/sandbox.sh"

repo="$(new_repo docs-only)"
commit_paths "$repo" baseline seed.txt
base="$(git -C "$repo" rev-parse HEAD)"

case_verdict() { # LABEL EXPECTED PATH...
  local label="$1" expected="$2"
  shift 2
  git -C "$repo" checkout -q -B case "$base"
  git -C "$repo" clean -qfd
  commit_paths "$repo" "$label" "$@"
  assert_docs_verdict "$label" "$expected" \
    --repo "$repo" --event push --base "$base" --head HEAD
}

# label | verdict | changed paths
path_row_count=0
while IFS='|' read -r label expected paths; do
  path_row_count=$((path_row_count + 1))
  # The table paths have no spaces. Word splitting makes each one an argument.
  # shellcheck disable=SC2086
  case_verdict "$label" "$expected" $paths
done <<'CASES'
docs-tree|true|docs/guide.md docs/architecture/topic.html
changelog-tree|true|changelog.d/added/ci.md
root-markdown|true|README.md CONTRIBUTING.markdown
all-doc-families|true|docs/guide.md changelog.d/fixed/ci.md AGENTS.md
mixed-product|false|docs/guide.md crates/core/src/lib.rs
skills-source|false|skills/review-gate/SKILL.md
agents-source|false|agents/generalist.md
hooks-source|false|hooks/pre-commit-check.sh
settings|false|kendex.settings.toml
nested-markdown|false|.github/README.md
docs-near-miss|false|documentation/guide.md
changelog-near-miss|false|changelog.draft/entry.md
root-text|false|README.txt
CASES
require_rows docs-only-paths "$path_row_count"

git -C "$repo" checkout -q -B case "$base"
git -C "$repo" clean -qfd
commit_paths "$repo" "event endpoints" docs/events.md
head="$(git -C "$repo" rev-parse HEAD)"
assert_docs_verdict pull-request true \
  --repo "$repo" --event pull_request --base "$base" --head "$head"
assert_docs_verdict merge-group true \
  --repo "$repo" --event merge_group --base "$base" --head "$head"

output_file="$SANDBOX/docs-output"
out="$("$HARNESS_ONLY" --mode docs --repo "$repo" --event merge_group \
  --base "$base" --head "$head" --output "$output_file" 2>/dev/null)"
assert_eq "docs mode writes the GitHub output" \
  "docs_only=true stdout=docs_only=true" \
  "$(cat "$output_file") stdout=$out"

# One changed production pattern is the must-fail control. Removing the slash
# rejection admits skills/*.md through the root-Markdown branch, and this suite
# must turn red on that mutant.
if [ -z "${DOCS_ONLY_CONTROL:-}" ]; then
  [ ! -L "$HARNESS_ONLY" ] || { echo "the classifier control refuses a symlink" >&2; exit 1; }
  mutant="$SANDBOX/harness-only-mutant"
  if ! awk '
    BEGIN { changed = 0 }
    /^      \*\/\*\) verdict false \\$/ {
      print "      never/*) verdict false \\"
      changed += 1
      next
    }
    { print }
    END { if (changed != 1) exit 2 }
  ' "$HARNESS_ONLY" >"$mutant"; then
    echo "could not build the docs-only must-fail control" >&2
    exit 1
  fi
  cmp -s "$HARNESS_ONLY" "$mutant" && {
    echo "the docs-only must-fail control changed no source" >&2
    exit 1
  }
  chmod +x "$mutant"
  control_status=0
  if DOCS_ONLY_CONTROL=1 HARNESS_ONLY_UNDER_TEST="$mutant" \
    bash "$TEST_DIR/docs-only.test.sh" >"$SANDBOX/control.stdout" \
    2>"$SANDBOX/control.stderr"; then
    control_status=0
  else
    control_status=$?
  fi
  assert_eq "the path-set mutant turns the docs-only suite red" 1 "$control_status"
fi

report docs-only
